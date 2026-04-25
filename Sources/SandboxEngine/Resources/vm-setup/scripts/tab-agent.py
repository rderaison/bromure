#!/usr/bin/python3 -u
"""Bromure native-chrome tab agent — runs inside the guest VM.

When the profile opts into "native chrome" mode, Chromium is launched with
--app=URL so it has no tab strip and no omnibox. The host renders both as
native macOS titlebar accessories. This agent is the guest-side plumbing.

Talks to Chromium over CDP (localhost:9222) and to the host over vsock
port 5810 (newline-delimited JSON).

Trust model
-----------
This agent runs as the chrome user inside the guest. The threat actor is
a malicious page running inside Chromium. That actor can:

  - Set arbitrary text in `document.title` and `document.URL`. Both flow
    through /json -> upsert -> host. Host code displays as SwiftUI Text;
    no shell or path interpretation.
  - Override the favicon URL via <link rel=icon>. We fetch in-guest with
    a 128 KB cap and an http(s) scheme allow-list; bytes go to host as
    base64 and render via NSImage.
  - Override `navigator.mediaDevices.getUserMedia` and our
    `__bromureMediaPatched` flag, spoofing or hiding the per-tab red dot.
    Cosmetic only.

That actor CANNOT:

  - Send vsock commands. AF_VSOCK requires kernel access; sandboxed
    Chromium processes have no syscall path to it.
  - Trigger any host->guest command (`activate`, `close`, `new`,
    `navigate`, `print`, `get_certificate`, `mouse_park`). Those only
    arrive on the existing host connection.

In addition, this agent enforces:

  - `ALLOW_PRINTING` env var must be `"1"` for `cmd: "print"` to do
    anything. Set in chrome-env by config-agent only when the active
    profile has Allow Printing on. Host already gates the same call;
    this is defense in depth.
  - Target ids interpolated into HTTP paths or used as DevTools session
    keys must match `_SAFE_ID_RE` (alphanumeric + dashes). CDP target
    ids fit this format; refusing anything else prevents path traversal
    or HTTP header injection from a future bug that lets unvalidated
    strings reach those code paths.

Guest → host:
  {"event":"upsert","id":"T","title":"...","url":"...","active":true}
  {"event":"favicon","id":"T","mime":"image/png","data":"BASE64"}
  {"event":"remove","id":"T"}

Host → guest:
  {"cmd":"activate","id":"T"}
  {"cmd":"close","id":"T"}
  {"cmd":"close_active"}  # ⌘W — guest resolves active id locally
  {"cmd":"new","url":"https://..."}
  {"cmd":"navigate","id":"T","url":"..."}
  {"cmd":"reload","id":"T"}
  {"cmd":"back","id":"T"}
  {"cmd":"forward","id":"T"}
  {"cmd":"mouse_park"}    # cursor left the visible area; clear hover state

Started from xinitrc when NATIVE_CHROME=1.
"""

import base64
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse, urljoin

# Hard gate on whether printing is honoured. Set from chrome-env at agent
# launch (xinitrc sources chrome-env into its env, which propagates through
# resilient-launch into our process). Read once; a session's profile is
# immutable for the session's lifetime.
_ALLOW_PRINTING = os.environ.get("ALLOW_PRINTING") == "1"

# Target ids that we'll accept in HTTP paths and as DevTools session keys.
# CDP target ids are alphanumeric + occasional dashes; rejecting anything
# else stops a malformed id from sliding into header injection or path
# traversal if a future bug ever lets one through unvalidated.
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9-]+$")


def _is_safe_id(s):
    return bool(s) and isinstance(s, str) and _SAFE_ID_RE.match(s) is not None

VSOCK_PORT = 5810
HOST_CID = 2
CDP_HOST = "127.0.0.1"
CDP_PORT = 9222
POLL_INTERVAL = 0.4           # seconds between /json polls
FAVICON_MAX_BYTES = 128 * 1024  # 128 KB cap; larger icons are sites' problem

_log_lock = threading.Lock()


def log(msg):
    with _log_lock:
        print(f"tab-agent: {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Minimal WebSocket client (identical shape to cjk-input-agent.py)
# ---------------------------------------------------------------------------

def _ws_connect(url):
    assert url.startswith("ws://")
    rest = url[5:]
    host_port, path = rest.split("/", 1)
    path = "/" + path
    if ":" in host_port:
        host, port = host_port.split(":")
        port = int(port)
    else:
        host, port = host_port, 80
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((host, port))
    key = "dGhlIHNhbXBsZSBub25jZQ=="
    s.sendall((
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("ws handshake: short read")
        resp += chunk
    if b"101" not in resp.split(b"\r\n")[0]:
        raise ConnectionError(f"ws upgrade rejected: {resp[:120]!r}")
    s.settimeout(None)
    return s


def _ws_send(sock, text):
    payload = text.encode("utf-8")
    frame = bytearray([0x81])
    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(0x80 | 127)
        frame.extend(struct.pack(">Q", length))
    frame.extend(b"\x00\x00\x00\x00")
    frame.extend(payload)
    sock.sendall(frame)


def _ws_recv(sock):
    def read_exact(n):
        buf = b""
        while len(buf) < n:
            c = sock.recv(n - len(buf))
            if not c:
                raise ConnectionError("ws closed")
            buf += c
        return buf
    header = read_exact(2)
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(8))[0]
    if masked:
        mask = read_exact(4)
        data = bytearray(read_exact(length))
        for i in range(length):
            data[i] ^= mask[i % 4]
    else:
        data = read_exact(length)
    if opcode == 0x08:
        raise ConnectionError("ws closed by peer")
    if opcode == 0x09:
        sock.sendall(bytearray([0x8A, 0x80, 0, 0, 0, 0]))
        return _ws_recv(sock)
    return data.decode("utf-8") if isinstance(data, (bytes, bytearray)) else data


# ---------------------------------------------------------------------------
# CDP helpers
# ---------------------------------------------------------------------------

def cdp_list_targets():
    """GET /json and return only `page` targets. Raises on transport error.

    Chromium's /json lists targets in roughly MRU order — newest / most-
    recently-focused first. For brand-new sessions with one tab that's
    invisible. For `--restore-last-session` it inverts the visible tab-
    strip order, so the host UI gets the tabs back-to-front. Reverse the
    list so order matches the (left-to-right) tab strip both at startup
    and as new tabs are added.
    """
    conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=3)
    try:
        conn.request("GET", "/json")
        resp = conn.getresponse()
        body = resp.read()
    finally:
        conn.close()
    pages = [t for t in json.loads(body) if t.get("type") == "page"]
    return list(reversed(pages))


# JS wrapper for getUserMedia tracking. Injected lazily on each poll via
# Runtime.evaluate; the `__bromureMediaPatched` guard makes it idempotent
# across navigations within the same JS context. Reports current camera
# and microphone usage by counting active getUserMedia tracks and writing
# the state to `document.documentElement.dataset.bromureMedia`.
_MEDIA_TRACKER_JS = r"""
(() => {
  if (!window.__bromureMediaPatched && navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
    window.__bromureMediaPatched = true;
    let video = 0, audio = 0;
    const update = () => {
      const tags = [];
      if (video > 0) tags.push('video');
      if (audio > 0) tags.push('audio');
      try { document.documentElement.dataset.bromureMedia = tags.join(','); }
      catch (_) { /* no documentElement yet — page is loading */ }
    };
    const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async function(constraints) {
      const stream = await orig(constraints);
      const wantVideo = !!(constraints && constraints.video);
      const wantAudio = !!(constraints && constraints.audio);
      if (wantVideo) video++;
      if (wantAudio) audio++;
      update();
      const decRef = (kind) => {
        if (kind === 'video' && video > 0) video--;
        else if (kind === 'audio' && audio > 0) audio--;
        update();
      };
      stream.getTracks().forEach((track) => {
        const origStop = track.stop.bind(track);
        track.stop = function() { origStop(); decRef(track.kind); };
        track.addEventListener('ended', () => decRef(track.kind));
      });
      return stream;
    };
  }
  try { return document.documentElement.dataset.bromureMedia || ''; }
  catch (_) { return ''; }
})()
""".strip()


def media_state(ws_url):
    """Inject the getUserMedia wrapper (idempotent) and return a string of
    `'video'`, `'audio'`, `'video,audio'`, or `''`. One CDP roundtrip per
    target per poll; cheap enough."""
    if not ws_url:
        return ""
    res = cdp_ws_call(ws_url, "Runtime.evaluate", {
        "expression": _MEDIA_TRACKER_JS,
        "returnByValue": True,
    })
    if not res:
        return ""
    val = res.get("result", {}).get("value")
    return val if isinstance(val, str) else ""


_CDP_PATH_RE = re.compile(r"^/json/(activate|close)/[A-Za-z0-9-]+$")


def cdp_simple_post(path):
    """Fire-and-forget POST to /json/<action>/<id>. Path is validated to
    block any header / traversal injection from a malformed target id."""
    if not _CDP_PATH_RE.match(path):
        log(f"cdp: refusing unsafe path {path!r}")
        return
    conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=3)
    try:
        conn.request("PUT", path)  # DevTools accepts PUT; some builds require POST
        conn.getresponse().read()
    except Exception:
        try:
            conn.close()
            conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=3)
            conn.request("POST", path)
            conn.getresponse().read()
        except Exception as e:
            log(f"cdp {path} failed: {e}")
    finally:
        conn.close()


def cdp_ws_call(ws_url, method, params=None):
    """One-shot WebSocket round-trip to a target. Returns result dict or None."""
    try:
        sock = _ws_connect(ws_url)
    except Exception as e:
        log(f"ws connect {ws_url[:60]}… failed: {e}")
        return None
    try:
        msg = {"id": 1, "method": method}
        if params:
            msg["params"] = params
        _ws_send(sock, json.dumps(msg))
        sock.settimeout(3)
        # Drain until we see our reply (ignore async events).
        for _ in range(40):
            raw = _ws_recv(sock)
            try:
                obj = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if obj.get("id") == 1:
                return obj.get("result")
        return None
    except Exception as e:
        log(f"ws call {method} failed: {e}")
        return None
    finally:
        try:
            sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Favicon fetching (guest-side; keeps proxy/mTLS in play)
# ---------------------------------------------------------------------------

_FAVICON_CACHE = {}  # url -> (mime, bytes)
_FAVICON_LOCK = threading.Lock()


def _favicon_url_for(tab_url, ws_url):
    """Resolve a favicon URL for a tab. Prefers <link rel=icon>, falls back
    to /favicon.ico on the page's origin."""
    # Ask the page itself — avoids guessing wrong for SPAs that set it late.
    res = cdp_ws_call(ws_url, "Runtime.evaluate", {
        "expression": (
            "(() => { const l = document.querySelector("
            "'link[rel~=\"icon\"], link[rel=\"shortcut icon\"], link[rel=\"apple-touch-icon\"]'); "
            "return l ? l.href : ''; })()"
        ),
        "returnByValue": True,
    })
    href = None
    if res and isinstance(res.get("result"), dict):
        v = res["result"].get("value")
        if isinstance(v, str) and v:
            href = v
    if not href:
        try:
            p = urlparse(tab_url)
            if p.scheme in ("http", "https") and p.netloc:
                href = f"{p.scheme}://{p.netloc}/favicon.ico"
        except Exception:
            pass
    return href


def _http_get(url, max_bytes):
    p = urlparse(url)
    if p.scheme not in ("http", "https"):
        return None
    try:
        if p.scheme == "https":
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection(p.netloc, timeout=4, context=ctx)
        else:
            conn = http.client.HTTPConnection(p.netloc, timeout=4)
        conn.request("GET", (p.path or "/") + (f"?{p.query}" if p.query else ""))
        r = conn.getresponse()
        if r.status != 200:
            return None
        data = r.read(max_bytes + 1)
        if len(data) > max_bytes:
            return None
        mime = r.getheader("Content-Type", "").split(";")[0].strip() or "image/x-icon"
        return mime, data
    except Exception:
        return None
    finally:
        try:
            conn.close()
        except Exception:
            pass


def fetch_favicon(tab_url, ws_url):
    """Return (mime, b64_bytes) or None. Memoised per absolute URL."""
    href = _favicon_url_for(tab_url, ws_url)
    if not href:
        return None
    with _FAVICON_LOCK:
        cached = _FAVICON_CACHE.get(href)
    if cached:
        return href, cached[0], cached[1]
    got = _http_get(href, FAVICON_MAX_BYTES)
    if not got:
        return None
    mime, data = got
    b64 = base64.b64encode(data).decode("ascii")
    with _FAVICON_LOCK:
        _FAVICON_CACHE[href] = (mime, b64)
        # Simple bound: evict oldest when we hit ~200 entries.
        if len(_FAVICON_CACHE) > 200:
            for k in list(_FAVICON_CACHE.keys())[:50]:
                _FAVICON_CACHE.pop(k, None)
    return href, mime, b64


# ---------------------------------------------------------------------------
# Host vsock link
# ---------------------------------------------------------------------------

class HostLink:
    def __init__(self):
        self._sock = None
        self._lock = threading.Lock()

    def connect(self):
        while True:
            try:
                s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                s.connect((HOST_CID, VSOCK_PORT))
                self._sock = s
                log(f"connected to host vsock :{VSOCK_PORT}")
                return
            except Exception as e:
                log(f"vsock connect failed ({e}); retrying")
                time.sleep(1)

    def send(self, obj):
        line = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        with self._lock:
            s = self._sock
            if not s:
                return False
            try:
                s.sendall(line)
                return True
            except OSError as e:
                log(f"send failed: {e}")
                try:
                    s.close()
                except OSError:
                    pass
                self._sock = None
                return False

    def reader_loop(self, on_cmd):
        buf = b""
        while True:
            s = self._sock
            if not s:
                self.connect()
                continue
            try:
                chunk = s.recv(65536)
            except OSError as e:
                log(f"recv failed: {e}")
                chunk = b""
            if not chunk:
                log("host vsock closed; reconnecting")
                try:
                    s.close()
                except OSError:
                    pass
                with self._lock:
                    self._sock = None
                buf = b""
                time.sleep(0.5)
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError as e:
                    log(f"bad cmd json: {e}")
                    continue
                try:
                    on_cmd(msg)
                except Exception as e:
                    log(f"cmd handler raised: {e}")


# ---------------------------------------------------------------------------
# New-tab via CDP Target.createTarget
# ---------------------------------------------------------------------------

def browser_ws_url():
    """Return the browser-level CDP WebSocket URL (/json/version)."""
    try:
        conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=3)
        try:
            conn.request("GET", "/json/version")
            resp = conn.getresponse()
            body = resp.read()
        finally:
            conn.close()
        return json.loads(body).get("webSocketDebuggerUrl")
    except Exception as e:
        log(f"/json/version failed: {e}")
        return None


def create_new_tab(url):
    """Ask Chromium to open a new tab in the existing window. Works because
    the positioning trick keeps us at one-and-only-one browser window: new
    tabs stack into its tab strip (which is clipped off-screen), and their
    content fills the visible area once activated. Returns the new target
    id or None on failure."""
    ws = browser_ws_url()
    if not ws:
        log("create_new_tab: no browser WS; giving up")
        return None
    res = cdp_ws_call(ws, "Target.createTarget", {"url": url})
    if res is None:
        log("create_new_tab: Target.createTarget returned nothing")
        return None
    tid = res.get("targetId")
    if not tid:
        log(f"create_new_tab: response missing targetId: {res}")
        return None
    # Focus the newly-created tab immediately so the user sees the load
    # they just asked for. Chromium auto-activates on createTarget in
    # current versions, but the docs don't promise it and older builds
    # drop activation on background windows.
    cdp_simple_post(f"/json/activate/{tid}")
    log(f"created target {tid}")
    return tid


# ---------------------------------------------------------------------------
# Command handling (host → guest)
# ---------------------------------------------------------------------------

def _target_for(tid, targets_by_id):
    """Look up a target by id. Falls back to a fresh /json poll if the
    cache is stale — the poll loop only refreshes every POLL_INTERVAL, and
    a navigate/reload that races the cache update would otherwise drop."""
    t = targets_by_id.get(tid)
    if t and t.get("webSocketDebuggerUrl"):
        return t
    try:
        for fresh in cdp_list_targets():
            if fresh.get("id") == tid and fresh.get("webSocketDebuggerUrl"):
                return fresh
    except Exception as e:
        log(f"refresh-on-miss failed: {e}")
    return None


# Which target id we believe is currently active. Two signals feed it:
# explicit host commands (cmd: activate / cmd: new) and the X11 active
# window title via xdotool (catches Chromium-side activations like
# target=_blank link clicks). The xdotool read can race the title update
# right after we set `_active_id` ourselves and incorrectly revert it, so
# we mark every explicit set as "trusted" for a short window during which
# the xdotool branch stays out of the way.
_active_id = None
_active_lock = threading.Lock()
_active_trusted_until = 0.0  # monotonic-clock seconds
_ACTIVE_TRUST_TTL = 0.6      # window after explicit set; ≥ poll interval × 1.5


def _set_active(tid):
    global _active_id, _active_trusted_until
    with _active_lock:
        _active_id = tid
        _active_trusted_until = time.monotonic() + _ACTIVE_TRUST_TTL


def _get_active():
    with _active_lock:
        return _active_id


def _is_active_trusted():
    with _active_lock:
        return time.monotonic() < _active_trusted_until


def _xdotool_active_window_title():
    """Read the currently focused X window's title, or None on failure.
    Matches Chromium's window title (= active tab title) so we can pick
    up spontaneous tab activations Chromium does in response to e.g.
    target=_blank link clicks. Empty / 'Chromium' → None so the caller
    falls through to tracked-id logic."""
    try:
        out = subprocess.check_output(
            ["xdotool", "getactivewindow", "getwindowname"],
            stderr=subprocess.DEVNULL, timeout=1.5,
        ).decode("utf-8", errors="replace").strip()
    except Exception:
        return None
    return out or None


def _match_target_by_title(targets, raw_title):
    """Find the target whose title best matches an X11 window title.
    Chromium appends ' - Chromium' (or sometimes a profile suffix); strip
    that, then do an exact-match pass before a substring fallback."""
    if not raw_title:
        return None
    stripped = raw_title.rsplit(" - ", 1)[0].strip().lower()
    # Exact match first.
    for t in targets:
        title = (t.get("title") or "").strip()
        if title and title.lower() == stripped:
            return t["id"]
    # Substring fallback (handles partial titles, e.g. ellipsis truncation).
    lower = raw_title.lower()
    for t in targets:
        title = (t.get("title") or "").strip().lower()
        if title and title in lower:
            return t["id"]
    return None


def active_target_id(targets):
    """Report the currently-active target id, in this priority order:

    1. **Trusted explicit set** (within ``_ACTIVE_TRUST_TTL`` of the last
       `cmd: activate` / `cmd: new`): use ``_active_id`` as-is. Without
       this, the xdotool branch below frequently misreads the X11 title
       in the brief window before Chromium re-renders it after our /json/
       activate, and reverts the host UI back to the previous tab.
    2. The X11 active window's title matched against /json titles —
       picks up Chromium-side activations (target=_blank link clicks,
       window.open popups, etc.) that the host didn't initiate.
    3. The id we last set ourselves, as long as it's still a live target.
    4. The first target in /json as a final fallback for the empty /
       very-short window where no signal is available yet.
    """
    if _is_active_trusted():
        tracked = _get_active()
        if tracked and any(t["id"] == tracked for t in targets):
            return tracked

    xdo = _xdotool_active_window_title()
    if xdo:
        matched = _match_target_by_title(targets, xdo)
        if matched:
            if matched != _get_active():
                _set_active(matched)
            return matched

    tracked = _get_active()
    if tracked and any(t["id"] == tracked for t in targets):
        return tracked

    if targets:
        _set_active(targets[0]["id"])
        return targets[0]["id"]
    return None


def handle_cmd(msg, targets_by_id, link):
    cmd = msg.get("cmd")
    tid = msg.get("id")
    if cmd == "activate" and _is_safe_id(tid):
        cdp_simple_post(f"/json/activate/{tid}")
        _set_active(tid)
    elif cmd == "close" and _is_safe_id(tid):
        cdp_simple_post(f"/json/close/{tid}")
        # If we just closed the active tab, forget it — the next poll will
        # pick up the correct survivor.
        if _get_active() == tid:
            _set_active(None)
    elif cmd == "close_active":
        # ⌘W path: resolve the active tab here, where xdotool sees X11
        # focus in real time. The host's view of "active" is fed by the
        # 400ms /json poll and lags behind spontaneous Chromium-side tab
        # switches (e.g. target=_blank), so closing what the host thinks
        # is active sometimes hits the wrong tab.
        try:
            fresh = cdp_list_targets()
        except Exception as e:
            log(f"close_active: list targets failed: {e}")
            return
        active_id = active_target_id(fresh)
        if active_id and _is_safe_id(active_id):
            cdp_simple_post(f"/json/close/{active_id}")
            if _get_active() == active_id:
                _set_active(None)
    elif cmd == "print":
        request_id = msg.get("request_id", "")
        b64 = ""
        # Hard gate: even if the host issues `cmd: print`, refuse unless
        # the active profile has Allow Printing on (chrome-env propagates
        # ALLOW_PRINTING=1). Reply with empty data so the host's
        # continuation completes; without the reply the host's request
        # would just time out, leaking the user's intent into the wait.
        if not _ALLOW_PRINTING:
            log("print: blocked (ALLOW_PRINTING=0)")
        elif _is_safe_id(msg.get("id")):
            tid = msg["id"]
            t = _target_for(tid, targets_by_id)
            if t and t.get("webSocketDebuggerUrl"):
                # `Page.printToPDF` returns the PDF as a base64 string in
                # the `data` field. We pass it straight through to the
                # host — nothing touches the guest disk.
                res = cdp_ws_call(t["webSocketDebuggerUrl"], "Page.printToPDF", {
                    "preferCSSPageSize": True,
                })
                if res and isinstance(res.get("data"), str):
                    b64 = res["data"]
        link.send({"event": "pdf", "request_id": request_id, "data": b64})
    elif cmd == "get_certificate":
        origin = msg.get("origin", "")
        request_id = msg.get("request_id", "")
        certs = []
        if origin:
            ws = browser_ws_url()
            if ws:
                res = cdp_ws_call(ws, "Network.getCertificate", {"origin": origin})
                if res:
                    # CDP returns the DER chain under `tableNames` (the field
                    # name is misleading — it's a list of base64-encoded
                    # certificates, not table names).
                    certs = res.get("tableNames", []) or []
        link.send({"event": "certificate", "request_id": request_id, "certs": certs})
    elif cmd == "mouse_park":
        # Host cursor crossed out of the visible area into the macOS toolbar.
        # VZ's mouse-tracking still extends into the clipped inset, so without
        # this Chromium thinks the mouse is hovering at the very top of the
        # page (and any y=0 dropdown / hover menu would fire). Send a CDP
        # mouseMoved to (-1, -1) on the active page so Chromium treats it as
        # "cursor left the viewport" and tears down hover state.
        tid = _get_active()
        if not tid:
            return
        t = _target_for(tid, targets_by_id)
        if not t or not t.get("webSocketDebuggerUrl"):
            return
        cdp_ws_call(t["webSocketDebuggerUrl"], "Input.dispatchMouseEvent", {
            "type": "mouseMoved",
            "x": -1,
            "y": -1,
        })
    elif cmd == "new":
        url = msg.get("url") or "about:blank"
        new_tid = create_new_tab(url)
        if not new_tid:
            return
        _set_active(new_tid)
        # Push an immediate upsert so the host UI shows the new tab without
        # waiting for the next 400ms poll, and so any typed URL navigates
        # the new tab instead of the previous one.
        link.send({
            "event": "upsert",
            "id": new_tid,
            "title": "",
            "url": url,
            "active": True,
        })
    elif cmd == "navigate" and _is_safe_id(tid):
        url = msg.get("url")
        if not url:
            return
        t = _target_for(tid, targets_by_id)
        if not t:
            log(f"navigate: target {tid} not found; falling back to new tab")
            new_tid = create_new_tab(url)
            if new_tid:
                _set_active(new_tid)
            return
        res = cdp_ws_call(t["webSocketDebuggerUrl"], "Page.navigate", {"url": url})
        if res is None:
            log(f"navigate: CDP Page.navigate returned nothing for {tid}")
    elif cmd == "reload" and _is_safe_id(tid):
        t = _target_for(tid, targets_by_id)
        if t:
            cdp_ws_call(t["webSocketDebuggerUrl"], "Page.reload", {})
    elif cmd in ("back", "forward") and _is_safe_id(tid):
        t = _target_for(tid, targets_by_id)
        if not t:
            return
        history = cdp_ws_call(t["webSocketDebuggerUrl"], "Page.getNavigationHistory", {})
        if not history:
            return
        idx = history.get("currentIndex")
        entries = history.get("entries", [])
        if idx is None:
            return
        new_idx = idx - 1 if cmd == "back" else idx + 1
        if 0 <= new_idx < len(entries):
            cdp_ws_call(t["webSocketDebuggerUrl"], "Page.navigateToHistoryEntry",
                        {"entryId": entries[new_idx]["id"]})
    else:
        log(f"unknown cmd: {msg}")


# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------

def main():
    # Wait for Chromium
    log("waiting for Chromium CDP…")
    for _ in range(180):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect((CDP_HOST, CDP_PORT))
            s.close()
            break
        except OSError:
            time.sleep(1)
    else:
        log("CDP never came up; exiting")
        return
    log("CDP ready")

    link = HostLink()
    link.connect()

    known = {}           # id → dict(last title/url/favicon_url)
    targets_by_id = {}   # shared with command handler

    # Seed the active-id tracker with whatever Chromium already has open so
    # the very first poll doesn't report "no active tab".
    try:
        initial = cdp_list_targets()
        if initial:
            _set_active(initial[0]["id"])
    except Exception as e:
        log(f"initial target seed failed: {e}")

    def on_cmd(msg):
        handle_cmd(msg, targets_by_id, link)

    threading.Thread(target=link.reader_loop, args=(on_cmd,), daemon=True).start()

    favicon_workers = set()
    workers_lock = threading.Lock()

    def schedule_favicon(tid, url, ws_url):
        with workers_lock:
            if tid in favicon_workers:
                return
            favicon_workers.add(tid)
        def work():
            try:
                res = fetch_favicon(url, ws_url)
                if res:
                    favicon_url, mime, b64 = res
                    link.send({
                        "event": "favicon",
                        "id": tid,
                        "favicon_url": favicon_url,
                        "mime": mime,
                        "data": b64,
                    })
            finally:
                with workers_lock:
                    favicon_workers.discard(tid)
        threading.Thread(target=work, daemon=True).start()

    while True:
        try:
            targets = cdp_list_targets()
        except Exception as e:
            log(f"list targets failed: {e}")
            time.sleep(1)
            continue

        targets_by_id.clear()
        for t in targets:
            targets_by_id[t["id"]] = t

        active_id = active_target_id(targets)

        current_ids = set()
        for t in targets:
            tid = t["id"]
            current_ids.add(tid)
            title = t.get("title") or ""
            url = t.get("url") or ""
            # Inject + read the media tracker. Skipped for non-http(s)
            # pages (about:, devtools:, …) where the wrapper isn't useful
            # and the Runtime.evaluate just adds latency.
            if url.startswith(("http://", "https://")):
                media = media_state(t.get("webSocketDebuggerUrl") or "")
            else:
                media = ""
            using_camera = "video" in media
            using_microphone = "audio" in media
            prev = known.get(tid)
            changed = (
                prev is None
                or prev.get("title") != title
                or prev.get("url") != url
                or prev.get("active") != (tid == active_id)
                or prev.get("camera") != using_camera
                or prev.get("microphone") != using_microphone
            )
            if changed:
                link.send({
                    "event": "upsert",
                    "id": tid,
                    "title": title,
                    "url": url,
                    "active": tid == active_id,
                    "using_camera": using_camera,
                    "using_microphone": using_microphone,
                })
            # Re-fetch favicon whenever URL origin changes (cheap check).
            url_origin = _origin(url)
            prev_origin = _origin(prev.get("url", "")) if prev else None
            if url.startswith(("http://", "https://")) and url_origin != prev_origin:
                schedule_favicon(tid, url, t.get("webSocketDebuggerUrl") or "")
            known[tid] = {
                "title": title,
                "url": url,
                "active": tid == active_id,
                "camera": using_camera,
                "microphone": using_microphone,
            }

        for tid in list(known.keys()):
            if tid not in current_ids:
                link.send({"event": "remove", "id": tid})
                known.pop(tid, None)

        time.sleep(POLL_INTERVAL)


def _origin(url):
    try:
        p = urlparse(url)
        if not p.scheme:
            return None
        return f"{p.scheme}://{p.netloc}"
    except Exception:
        return None


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
