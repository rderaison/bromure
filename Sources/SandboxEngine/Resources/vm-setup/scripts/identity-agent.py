#!/usr/bin/python3 -u
"""Bromure identity agent — makes the browser's whole identity match its
User-Agent. Runs inside the guest as the chrome user, started by xinitrc
only when config-agent wrote CHROME_IDENTITY (a non-Linux identity such as
macOS or Windows).

Why: Chromium applies --user-agent to the User-Agent header and
navigator.userAgent only. User-Agent Client Hints (Sec-CH-UA-Platform and
friends, navigator.userAgentData) and navigator.platform keep reporting the
Linux guest, so a site comparing them sees through the identity — and the
mismatch itself makes the browser stand out.

How: one DevTools connection to the browser (127.0.0.1:9222). Before
touching anything it reads the browser's own brand list from a page (the
GREASE brand and full versions Chromium computes for its version). It then
auto-attaches to every target with waitForDebuggerOnStart, so each new
page, frame and worker is paused before it runs or loads anything, applies
the identity, and only then lets it run:

  page / iframe  Emulation.setUserAgentOverride (headers, userAgentData,
                 navigator.platform) + a new-document script for
                 navigator.platform, which Chromium resets on navigation
  worker kinds   Network.setUserAgentOverride
  tab            just auto-attach to what it contains

Start-up: targets that exist before the agent connects (the first tab) were
not paused. xinitrc therefore starts Chromium on about:blank and leaves the
real start page to this agent, which navigates there once the identity is
in place. Restored sessions (--restore-last-session) can't be deferred, so
their tabs are reloaded once the identity is applied.

Overrides last as long as this connection: resilient-launch restarts the
agent if it dies, and it re-applies everything on reconnect.
"""

import base64
import json
import os
import re
import select
import shlex
import socket
import struct
import sys
import time
import urllib.request
from pathlib import Path

# Overridable so a second, throwaway browser can be tested side by side.
STATE_DIR = Path(os.environ.get("BROMURE_IDENTITY_STATE_DIR", "/tmp/bromure"))
ENV_FILE = STATE_DIR / "chrome-env"
READY_FILE = STATE_DIR / "identity-ready"
STARTED_FILE = STATE_DIR / "identity-start-page-done"
CDP_PORT = int(os.environ.get("BROMURE_IDENTITY_CDP_PORT", "9222"))

PAGE_TYPES = ("page", "iframe")
WORKER_TYPES = ("worker", "shared_worker", "service_worker")
BRAND_NAMES = ("Chromium", "Google Chrome")


def log(msg):
    print(f"identity-agent: {msg}", file=sys.stderr, flush=True)


def read_environment(path):
    """chrome-env assignments, parsed — never executed."""
    values = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return values
    for line in lines:
        try:
            fields = shlex.split(line, comments=True)
        except ValueError:
            continue
        if fields and fields[0] == "export":
            fields = fields[1:]
        if len(fields) == 1 and "=" in fields[0]:
            key, value = fields[0].split("=", 1)
            values[key] = value
    return values


# ---------------------------------------------------------------------------
# Identity → DevTools parameters (pure, unit-tested)
# ---------------------------------------------------------------------------

def grease_brands(major, brand_names):
    """Chromium's brand list for `major` (GenerateBrandVersionList in
    components/embedder_support/user_agent_utils.cc): a GREASE brand plus
    the real brands, placed by a permutation seeded with the major version.
    `order[i]` is the position of the i-th of [GREASE, *brand_names]."""
    chars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"]
    versions = ["8", "99", "24"]
    grease = {"brand": f"Not{chars[major % len(chars)]}A{chars[(major + 1) % len(chars)]}Brand",
              "version": versions[major % len(versions)]}
    entries = [grease] + [{"brand": name, "version": str(major)} for name in brand_names]
    orders = {2: [[0, 1], [1, 0]],
              3: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]}
    if len(entries) not in orders:
        return entries
    order = orders[len(entries)][major % len(orders[len(entries)])]
    placed = [None] * len(entries)
    for entry, position in zip(entries, order):
        placed[position] = entry
    return placed


def user_agent_metadata(identity, native):
    """userAgentMetadata for `identity`, built on the browser's own brand
    lists (`native`: {"brands": [...], "fullVersionList": [...]}). Real
    brands are re-versioned only when the identity claims another major
    version than the engine (a custom user agent)."""
    major = identity.get("majorVersion")
    brands = [dict(b) for b in native.get("brands") or []]
    full = [dict(b) for b in native.get("fullVersionList") or []]
    # The real brands this browser carries ("Chromium", plus "Google Chrome"
    # for Chrome). A list missing one — unreadable, or headless — is rebuilt
    # the way Chromium builds it.
    wanted = identity.get("brands") or ["Chromium"]
    have = sorted(b.get("brand") for b in brands if b.get("brand") in BRAND_NAMES)
    if major and have != sorted(wanted):
        brands = grease_brands(major, wanted)
        full = []
    if major:
        for b in brands:
            if b.get("brand") in BRAND_NAMES and b.get("version") != str(major):
                b["version"] = str(major)
        for b in full:
            if b.get("brand") in BRAND_NAMES and not str(b.get("version", "")).startswith(f"{major}."):
                b["version"] = f"{major}.0.0.0"
    if not full:
        # Chromium leaves fullVersionList empty once --user-agent is set;
        # Chrome reports the engine's real full version for its own brands.
        engine = native.get("fullVersion") or ""
        full = [{"brand": b["brand"],
                 "version": engine if b["brand"] in BRAND_NAMES and engine.startswith(b["version"] + ".")
                 else b["version"] + ".0.0.0"}
                for b in brands]
    return {
        "brands": brands,
        "fullVersionList": full,
        "platform": identity["platform"],
        "platformVersion": identity["platformVersion"],
        "architecture": identity["architecture"],
        "model": "",
        "mobile": False,
        "bitness": identity["bitness"],
        "wow64": False,
    }


def platform_script(navigator_platform):
    """navigator.platform, for documents and workers. Chromium honours the
    override's `platform` only until the next navigation, and not at all
    in workers."""
    value = json.dumps(navigator_platform)
    return ("(() => { const N = self.Navigator || self.WorkerNavigator; if (!N) return;"
            " const d = Object.getOwnPropertyDescriptor(N.prototype, 'platform'); if (!d) return;"
            f" const get = Object.getOwnPropertyDescriptor({{ get platform() {{ return {value}; }} }}, 'platform').get;"
            " Object.defineProperty(N.prototype, 'platform',"
            " { get, set: undefined, enumerable: d.enumerable, configurable: d.configurable }); })();")


class IdentityAgent:
    """Decides what to send for each DevTools event. `send(method, params,
    session)` is the transport; commands on one session run in order, so a
    target is released only after its overrides are in place.

    Pages are reached through their tab target. A new tab is reported
    paused before its first navigation, but its page's navigation request
    is issued by the browser as soon as the tab is released — before a
    page-level override could land. So a paused tab is held until its page
    has been attached and given the identity, and only then released
    (or after TAB_HOLD seconds, so no tab can stay frozen).
    """

    TAB_HOLD = 1.0
    AUTO_ATTACH = {"autoAttach": True, "waitForDebuggerOnStart": True, "flatten": True}

    def __init__(self, send, user_agent, identity, metadata, start_url=None, reload_existing=False,
                 clock=time.monotonic):
        self.send = send
        self.identity = identity
        self.start_url = start_url
        self.reload_existing = reload_existing
        self.clock = clock
        self.override = {"userAgent": user_agent,
                         "platform": identity["navigatorPlatform"],
                         "userAgentMetadata": metadata}
        self.script = platform_script(identity["navigatorPlatform"])
        self.held_tabs = {}  # tab session -> release deadline

    def start(self):
        # Tabs (and through them their pages, frames and workers) plus the
        # workers that belong to no tab.
        self.send("Target.setAutoAttach", dict(self.AUTO_ATTACH, filter=[
            {"type": "tab"}, {"type": "shared_worker"}, {"type": "service_worker"},
            {"exclude": True}]), None)

    def attached(self, params, parent=None):
        """Target.attachedToTarget; `parent` is the session it arrived on."""
        session = params["sessionId"]
        info = params.get("targetInfo", {})
        kind = info.get("type")
        waiting = params.get("waitingForDebugger")
        if kind == "tab":
            self.send("Target.setAutoAttach", self.AUTO_ATTACH, session)
            if waiting:
                self.held_tabs[session] = self.clock() + self.TAB_HOLD
            return
        if kind in PAGE_TYPES:
            self.send("Emulation.setUserAgentOverride", self.override, session)
            # New-document scripts only run while the Page domain is on.
            self.send("Page.enable", {}, session)
            self.send("Page.addScriptToEvaluateOnNewDocument",
                      {"source": self.script, "runImmediately": True}, session)
        elif kind in WORKER_TYPES:
            self.send("Network.setUserAgentOverride", self.override, session)
            # Paused before its first line: patched before any of it runs.
            self.send("Runtime.evaluate", {"expression": self.script}, session)
        if kind in PAGE_TYPES + WORKER_TYPES:
            # Frames in other processes and the workers these spawn.
            self.send("Target.setAutoAttach", self.AUTO_ATTACH, session)
        if waiting:
            self.send("Runtime.runIfWaitingForDebugger", {}, session)
        if parent in self.held_tabs:
            self.release_tab(parent)
        if kind == "page" and not info.get("parentId"):
            self.top_level_page(session, info.get("url", ""), existing=not waiting)

    def release_tab(self, session):
        del self.held_tabs[session]
        self.send("Runtime.runIfWaitingForDebugger", {}, session)

    def tick(self):
        """Release tabs whose page never showed up."""
        now = self.clock()
        for session, deadline in list(self.held_tabs.items()):
            if now >= deadline:
                self.release_tab(session)

    def top_level_page(self, session, url, existing):
        """The deferred start page goes to the first blank tab, whether it
        existed before the agent attached or arrives now. Tabs that were
        already loading when the agent attached (a restored session) sent
        their first request without the identity; reload them once."""
        if self.start_url and url in ("", "about:blank"):
            self.send("Page.navigate", {"url": self.start_url}, session)
            self.start_url = None
        elif existing and self.reload_existing and url.startswith(("http:", "https:")):
            self.send("Page.reload", {}, session)


# ---------------------------------------------------------------------------
# Transport: a minimal RFC 6455 client (stdlib only)
# ---------------------------------------------------------------------------

class DevTools:
    def __init__(self, port):
        version = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=5))
        path = "/" + version["webSocketDebuggerUrl"].split("/", 3)[3]
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("handshake closed")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError("upgrade refused")
        self.sock.settimeout(None)
        self.next_id = 0

    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self._frame(0x1, json.dumps(msg).encode())
        return self.next_id

    def _frame(self, opcode, data):
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            head = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", n)
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def receive(self, timeout=None):
        """Next JSON message, or None on timeout or after a control frame
        (so the caller's timers still run)."""
        message = b""
        while True:
            if not self.buf and timeout is not None and not message:
                ready, _, _ = select.select([self.sock], [], [], timeout)
                if not ready:
                    return None
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(n)
            opcode = b0 & 0x0F
            if opcode == 0x8:
                raise ConnectionError("closed by browser")
            if opcode == 0x9:  # ping
                self._frame(0xA, payload)
                if not message:
                    return None
                continue
            if opcode in (0x0, 0x1, 0x2):  # continuation / text / binary
                message += payload
                if b0 & 0x80:  # FIN
                    return json.loads(message)

    def call(self, method, params=None, session=None, timeout=5.0, backlog=None):
        """Send and wait for the reply; other messages go to `backlog`."""
        wanted = self.send(method, params, session)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.receive(timeout=max(0.0, deadline - time.monotonic()))
            if msg is None:
                break
            if msg.get("id") == wanted:
                return msg
            if backlog is not None:
                backlog.append(msg)
        return None


NATIVE_PROBE = ("navigator.userAgentData ? navigator.userAgentData.getHighEntropyValues(['fullVersionList'])"
                ".then(v => JSON.stringify({brands: navigator.userAgentData.brands,"
                " fullVersionList: v.fullVersionList})) : '{}'")


def engine_full_version(devtools, backlog):
    """"156.0.8078.73" from Browser.getVersion's product ("Chrome/…")."""
    reply = devtools.call("Browser.getVersion", {}, backlog=backlog)
    product = (reply or {}).get("result", {}).get("product", "")
    m = re.search(r"/(\d+\.\d+\.\d+\.\d+)", product)
    return m.group(1) if m else None


def native_brands(devtools, backlog, wait=5.0):
    """The browser's own brand lists, read from an existing page before any
    override is applied (waiting briefly for the first tab while Chromium
    starts). Empty dict when no page answers."""
    deadline = time.monotonic() + wait
    targets = []
    while True:
        reply = devtools.call("Target.getTargets", {}, backlog=backlog)
        targets = (reply or {}).get("result", {}).get("targetInfos", [])
        if any(t.get("type") == "page" for t in targets) or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    # navigator.userAgentData only exists in secure contexts: an about:blank
    # start tab has none, Chromium's own WebUI (chrome://…) always does.
    candidates = sorted((t for t in targets if t.get("type") in ("page", "browser_ui")),
                        key=lambda t: not t.get("url", "").startswith(("https:", "chrome:")))
    for target in candidates:
        attach = devtools.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True},
                               backlog=backlog)
        session = (attach or {}).get("result", {}).get("sessionId")
        if not session:
            continue
        result = devtools.call("Runtime.evaluate", {"expression": NATIVE_PROBE, "awaitPromise": True,
                                                    "returnByValue": True}, session, backlog=backlog)
        devtools.send("Target.detachFromTarget", {"sessionId": session})
        try:
            native = json.loads(result["result"]["result"]["value"])
            if native.get("brands"):
                return native
        except (KeyError, TypeError, ValueError):
            pass
    return {}


def run_once(env):
    identity = json.loads(env["CHROME_IDENTITY"])
    user_agent = env["CHROME_UA"]
    devtools = DevTools(CDP_PORT)
    backlog = []
    native = native_brands(devtools, backlog)
    native["fullVersion"] = engine_full_version(devtools, backlog)
    # Only the probe's own attach/detach events can be pending here; the
    # auto-attach below reports every target afresh.
    backlog.clear()
    if not native:
        log("could not read the browser's brands; using Chromium's GREASE rules")
    metadata = user_agent_metadata(identity, native)
    first_run = not STARTED_FILE.exists()
    start_url = env.get("CHROME_URL") if first_run and env.get("CHROME_URL") else None
    agent = IdentityAgent(devtools.send, user_agent, identity, metadata,
                          start_url=start_url, reload_existing=first_run and not env.get("CHROME_URL"))
    agent.start()
    log(f"applying {identity['platform']} identity ({user_agent})")
    ready_written = False
    while True:
        agent.tick()
        msg = backlog.pop(0) if backlog else devtools.receive(timeout=0.1 if agent.held_tabs else 1.0)
        if msg is None:
            if agent.held_tabs:
                continue
            if not ready_written:
                # The browser has reported every existing target by now.
                STATE_DIR.mkdir(parents=True, exist_ok=True)
                READY_FILE.touch()
                if first_run:
                    STARTED_FILE.touch()
                ready_written = True
            continue
        if msg.get("method") == "Target.attachedToTarget":
            agent.attached(msg["params"], parent=msg.get("sessionId"))
        elif "error" in msg:
            log(f"command {msg.get('id')} failed: {msg['error'].get('message')}")


def main():
    env = read_environment(ENV_FILE)
    if not env.get("CHROME_IDENTITY") or not env.get("CHROME_UA"):
        log("no CHROME_IDENTITY; nothing to do")
        while True:  # stay up: resilient-launch would restart an exit
            time.sleep(3600)
    while True:
        try:
            run_once(env)
        except (OSError, ConnectionError, ValueError) as e:
            log(f"browser connection: {e}; retrying")
        time.sleep(0.2)


if __name__ == "__main__":
    main()
