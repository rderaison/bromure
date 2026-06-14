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
import sqlite3
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

# Browser-chrome accelerators the host may inject via xdotool (menu clicks
# that bypass the VZ keyboard path). xdotool sees the guest X server directly,
# so these are the real Chromium chords (no Cmd↔Ctrl swap).
_ALLOWED_CHORDS = {"ctrl+shift+b", "ctrl+d"}

VSOCK_PORT = 5810
HOST_CID = 2
CDP_HOST = "127.0.0.1"
CDP_PORT = 9222
SHORTCUT_PORT = 5917          # localhost: Openbox -> bromure-hostkey -> here
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

    # Reassemble a full message across fragmentation. Large CDP replies
    # (notably Page.printToPDF, whose base64 payload can be hundreds of KB)
    # are split into a leading frame (FIN=0) plus continuation frames
    # (opcode 0x00) until a frame with FIN=1. Reading only the first frame
    # — as this used to — truncated the JSON and silently dropped the reply.
    chunks = []
    while True:
        header = read_exact(2)
        fin = bool(header[0] & 0x80)
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
            data = bytes(read_exact(length))
        if opcode == 0x08:
            raise ConnectionError("ws closed by peer")
        if opcode == 0x09:  # ping — pong back, keep reading (may be mid-message)
            sock.sendall(bytearray([0x8A, 0x80, 0, 0, 0, 0]))
            continue
        if opcode == 0x0A:  # pong — ignore
            continue
        chunks.append(bytes(data))
        if fin:
            break
    return b"".join(chunks).decode("utf-8")


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


# JS wrapper for getUserMedia tracking + visibility readout. Injected
# lazily on each poll via Runtime.evaluate; the `__bromureMediaPatched`
# guard makes the wrapper idempotent across navigations. Returns
# `"<visibility>|<media>"` so a single CDP roundtrip per tab carries
# both signals. `document.visibilityState` is the primary "which tab is
# active" signal — the active tab reports `'visible'`, all others
# `'hidden'` — which catches Chromium-side activations (target=_blank
# clicks, window.open, etc.) that the X11-title fallback can miss in
# the brief window between the new tab opening and its title settling.
_TAB_TRACKER_JS = r"""
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
  let media = '';
  try { media = document.documentElement.dataset.bromureMedia || ''; }
  catch (_) { /* no documentElement yet */ }
  const vis = (typeof document !== 'undefined' && document.visibilityState) || '';
  return vis + '|' + media;
})()
""".strip()


def tab_state(ws_url):
    """Inject the tracker (idempotent) and return ``(visibility, media)``.

    visibility: ``'visible'`` / ``'hidden'`` / ``'prerender'`` / ``''``
    media: ``''`` / ``'video'`` / ``'audio'`` / ``'video,audio'``
    """
    if not ws_url:
        return ("", "")
    res = cdp_ws_call(ws_url, "Runtime.evaluate", {
        "expression": _TAB_TRACKER_JS,
        "returnByValue": True,
    })
    if not res:
        return ("", "")
    val = res.get("result", {}).get("value")
    if not isinstance(val, str):
        return ("", "")
    parts = val.split("|", 1)
    return (parts[0] if parts else "", parts[1] if len(parts) > 1 else "")


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


def cdp_ws_call(ws_url, method, params=None, timeout=3):
    """One-shot WebSocket round-trip to a target. Returns result dict or None.

    `timeout` bounds each socket read; bump it for slow methods like
    Page.printToPDF, which can take several seconds to rasterise a complex
    page before the (large) reply starts arriving."""
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
        sock.settimeout(timeout)
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
# Trust window after explicit tab creation. A fresh about:blank tab can't
# confirm itself through the visibility signal (non-http(s) URLs aren't
# evaluable), so once the standard trust expires the only remaining signal
# is the X11 title match — which can be stale or ambiguous and steal
# `active` back to the previous tab while the user is already typing in
# the new tab's address bar. Nothing would ever flip it back (the blank
# tab never reports 'visible'), so hold the explicit set longer.
_NEW_TAB_TRUST_TTL = 2.0


def _set_active(tid, ttl=_ACTIVE_TRUST_TTL):
    global _active_id, _active_trusted_until
    with _active_lock:
        _active_id = tid
        _active_trusted_until = time.monotonic() + ttl


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
    # A bare "Chromium" means the active tab has no title yet (fresh
    # about:blank, page still loading); matching on it would pick an
    # arbitrary tab. Let the caller fall through to tracked-id logic.
    if not out or out.lower() in ("chromium", "chromium-browser"):
        return None
    return out


def _match_target_by_title(targets, raw_title):
    """Find the target whose title best matches an X11 window title.
    Chromium appends ' - Chromium' (or sometimes a profile suffix); strip
    that, then do an exact-match pass before a substring fallback.

    Titles aren't unique — two ⌘T tabs are both "about:blank" — so when
    several targets match, prefer the one we already track as active
    instead of blindly returning the first. Switching to an arbitrary
    same-titled tab is exactly the active-flap that yanks the host's
    address bar out from under the user mid-edit."""
    if not raw_title:
        return None
    stripped = raw_title.rsplit(" - ", 1)[0].strip().lower()

    def pick(ids):
        if not ids:
            return None
        tracked = _get_active()
        return tracked if tracked in ids else ids[0]

    # Exact match first.
    exact = [
        t["id"] for t in targets
        if (t.get("title") or "").strip() and (t.get("title") or "").strip().lower() == stripped
    ]
    if exact:
        return pick(exact)
    # Substring fallback (handles partial titles, e.g. ellipsis truncation).
    lower = raw_title.lower()
    subs = [
        t["id"] for t in targets
        if (t.get("title") or "").strip() and (t.get("title") or "").strip().lower() in lower
    ]
    return pick(subs)


def active_target_id(targets, visibility=None):
    """Report the currently-active target id, in this priority order:

    1. **Trusted explicit set** (within ``_ACTIVE_TRUST_TTL`` of the last
       `cmd: activate` / `cmd: new`): use ``_active_id`` as-is. Without
       this, the visibility / xdotool branches can flap in the brief
       window before Chromium fully settles the new active tab after
       our `/json/activate`, reverting the host UI to the previous tab.
    2. **document.visibilityState**: the active tab reports ``'visible'``;
       all others ``'hidden'``. This is the source of truth — Chromium
       sets it the moment a tab becomes the active web contents, even
       for Chromium-initiated activations like target=_blank link
       clicks or window.open popups. It works regardless of X11 window-
       title timing, which the previous fallback (xdotool) raced.
    3. **xdotool window title**: secondary fallback when visibility is
       unknown for every target (e.g. tabs whose JS context isn't
       evaluable yet — non-http(s) urls, very-fresh pages).
    4. The id we last set ourselves, as long as it's still a live target.
    5. The first target in /json as a final fallback for the empty /
       very-short window where no signal is available yet.
    """
    if _is_active_trusted():
        tracked = _get_active()
        if tracked and any(t["id"] == tracked for t in targets):
            # Enforce, don't just report: if Chromium visibly disagrees
            # (a boot-time /json/activate can be dropped while the window
            # manager is still coming up), re-issue the activation. A
            # blank tab can never flip itself back via the visibility
            # signal, so without this one dropped activate strands the
            # user on the wrong tab as soon as trust expires.
            if visibility and _is_safe_id(tracked):
                visible = [
                    t["id"] for t in targets
                    if visibility.get(t["id"]) == "visible"
                ]
                if visible and tracked not in visible:
                    cdp_simple_post(f"/json/activate/{tracked}")
            return tracked

    if visibility:
        visible_ids = [
            t["id"] for t in targets
            if visibility.get(t["id"]) == "visible"
        ]
        if len(visible_ids) == 1:
            tid = visible_ids[0]
            if tid != _get_active():
                _set_active(tid)
            return tid
        if len(visible_ids) > 1:
            # Transient (mid-switch). Prefer the one we already track
            # if it's still in the visible set; otherwise pick the
            # first.
            tracked = _get_active()
            if tracked in visible_ids:
                return tracked
            tid = visible_ids[0]
            _set_active(tid)
            return tid

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


def _chromium_profile_dir():
    """Chromium's user-data-dir, read from the PROFILE_DIR env var that
    xinitrc exports from chrome-env (config-agent writes it to match the
    `--user-data-dir` it passes Chromium). Persistent profiles mount their
    disk at that path, so the bookmarks we read and the history DB we write
    beside it survive reboots. Ephemeral profiles leave PROFILE_DIR unset,
    so we fall back to the default profile location on the throwaway root
    disk — which is the right place for a session that shouldn't persist."""
    return os.environ.get("PROFILE_DIR") or os.path.expanduser("~/.config/chromium")


def _simplify_bookmark_node(node):
    """Reduce a Chromium bookmarks node to {type, name, url?/children?}."""
    ntype = node.get("type")
    if ntype == "url":
        return {"type": "url", "name": node.get("name", ""), "url": node.get("url", "")}
    if ntype == "folder":
        children = [
            s for s in (_simplify_bookmark_node(c) for c in node.get("children", []))
            if s is not None
        ]
        return {"type": "folder", "name": node.get("name", ""), "children": children}
    return None


def read_bookmarks():
    """Read and simplify Chromium's bookmark tree into the bookmark-bar and
    other-bookmarks top-level lists. Returns None when no bookmarks file has
    been written yet (a fresh profile with no bookmarks). Chromium flushes
    this file a beat after edits, so a just-added bookmark may lag by a
    second or two."""
    path = os.path.join(_chromium_profile_dir(), "Default", "Bookmarks")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        log(f"bookmarks: cannot read {path}: {e}")
        return None
    roots = data.get("roots", {})

    def children_of(key):
        node = roots.get(key) or {}
        return [
            s for s in (_simplify_bookmark_node(c) for c in node.get("children", []))
            if s is not None
        ]

    return {"bookmark_bar": children_of("bookmark_bar"), "other": children_of("other")}


# ---------------------------------------------------------------------------
# Session history — recorded into a SQLite DB under Chromium's user-data-dir.
# It therefore inherits the profile's persistence: ephemeral profiles lose it
# with the VM; persistent profiles get it back on the next boot. The full,
# Chromium-owned history still lives behind "Show Full History"
# (chrome://history); these two lists feed the macOS History menu.
# ---------------------------------------------------------------------------
_HISTORY_VISITED_CAP = 100
_HISTORY_CLOSED_CAP = 50
_HISTORY_MENU_LIMIT = 25
_history_db = None
_history_lock = threading.Lock()


def _history_connect():
    """Open (once) the history DB beside Chromium's profile data. Returns the
    connection or None if SQLite is unavailable / the path can't be opened."""
    global _history_db
    if _history_db is not None:
        return _history_db
    path = os.path.join(_chromium_profile_dir(), "bromure-history.db")
    try:
        conn = sqlite3.connect(path, check_same_thread=False)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS visited "
            "(url TEXT PRIMARY KEY, title TEXT, ts REAL)")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS closed "
            "(id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT, title TEXT, ts REAL)")
        conn.commit()
        _history_db = conn
        log(f"history: opened {path}")
    except Exception as e:
        log(f"history: cannot open {path}: {e}")
        _history_db = None
    return _history_db


def _record_visit(title, url):
    if not url.startswith(("http://", "https://")):
        return
    with _history_lock:
        conn = _history_connect()
        if conn is None:
            return
        try:
            conn.execute(
                "INSERT INTO visited(url, title, ts) VALUES(?, ?, ?) "
                "ON CONFLICT(url) DO UPDATE SET title=excluded.title, ts=excluded.ts",
                (url, title or url, time.time()))
            conn.execute(
                "DELETE FROM visited WHERE url NOT IN "
                "(SELECT url FROM visited ORDER BY ts DESC LIMIT ?)",
                (_HISTORY_VISITED_CAP,))
            conn.commit()
        except Exception as e:
            log(f"history: visit write failed: {e}")


def _record_close(title, url):
    if not url.startswith(("http://", "https://")):
        return
    with _history_lock:
        conn = _history_connect()
        if conn is None:
            return
        try:
            conn.execute(
                "INSERT INTO closed(url, title, ts) VALUES(?, ?, ?)",
                (url, title or url, time.time()))
            conn.execute(
                "DELETE FROM closed WHERE id NOT IN "
                "(SELECT id FROM closed ORDER BY id DESC LIMIT ?)",
                (_HISTORY_CLOSED_CAP,))
            conn.commit()
        except Exception as e:
            log(f"history: close write failed: {e}")


def _history_snapshot():
    with _history_lock:
        conn = _history_connect()
        if conn is None:
            return {"recently_closed": [], "recently_visited": []}
        try:
            visited = [
                {"title": t or u, "url": u}
                for (u, t) in conn.execute(
                    "SELECT url, title FROM visited ORDER BY ts DESC LIMIT ?",
                    (_HISTORY_MENU_LIMIT,))
            ]
            closed = [
                {"title": t or u, "url": u}
                for (u, t) in conn.execute(
                    "SELECT url, title FROM closed ORDER BY id DESC LIMIT ?",
                    (_HISTORY_MENU_LIMIT,))
            ]
            return {"recently_closed": closed, "recently_visited": visited}
        except Exception as e:
            log(f"history: read failed: {e}")
            return {"recently_closed": [], "recently_visited": []}


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
                # host — nothing touches the guest disk. Rendering a real
                # page is slow and the reply is large, so allow a generous
                # read timeout (the host gives us 30 s).
                res = cdp_ws_call(t["webSocketDebuggerUrl"], "Page.printToPDF", {
                    "preferCSSPageSize": True,
                }, timeout=25)
                if res and isinstance(res.get("data"), str):
                    b64 = res["data"]
                log(f"print: tab {tid} -> {len(b64)} b64 chars")
            else:
                log(f"print: no target for id {tid}")
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
    elif cmd == "get_bookmarks":
        request_id = msg.get("request_id", "")
        tree = read_bookmarks()
        link.send({"event": "bookmarks", "request_id": request_id, "tree": tree})
    elif cmd == "get_history":
        request_id = msg.get("request_id", "")
        snap = _history_snapshot()
        link.send({
            "event": "history",
            "request_id": request_id,
            "recently_closed": snap["recently_closed"],
            "recently_visited": snap["recently_visited"],
        })
    elif cmd == "key_chord":
        # Deliver a real browser-chrome accelerator to Chromium via xdotool
        # (X11), used by menu-bar clicks that can't ride the VZ keyboard
        # path. Allowlisted so only known bookmark chords are injectable.
        chord = msg.get("chord", "")
        if chord in _ALLOWED_CHORDS:
            try:
                subprocess.run(["xdotool", "key", "--clearmodifiers", chord], timeout=3)
            except Exception as e:
                log(f"key_chord {chord} failed: {e}")
        else:
            log(f"key_chord: refusing chord {chord!r}")
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
        _set_active(new_tid, ttl=_NEW_TAB_TRUST_TTL)
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
                _set_active(new_tid, ttl=_NEW_TAB_TRUST_TTL)
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

def shortcut_listener(link):
    """Relay browser-chrome shortcuts that Openbox grabbed in the guest back
    to the macOS host. While the VM holds keyboard focus the VZ view forwards
    every chord to the guest before AppKit can swallow it, so Openbox grabs
    ⌘T/⌘W/⌘L/⌘R/⌘P (which the Cmd↔Ctrl swap turns into Ctrl+… that Chromium
    would act on) and runs `bromure-hostkey <k>`, which connects here and
    sends the bare key letter. We forward it over vsock so the host owns the
    chord. Localhost-only listener; only an allowlisted key letter is
    relayed."""
    allowed = {"t", "w", "l", "r", "p", "[", "]"}
    # Debounce: a held chord autorepeats in the guest X server (xset r rate),
    # firing the Openbox keybind — and thus this listener — many times for one
    # intentional press. Collapse repeats of the same key within this window so
    # ⌘T doesn't spawn a pile of tabs. Well under a human double-tap interval.
    debounce = 0.2
    last_fire = {}
    try:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", SHORTCUT_PORT))
        srv.listen(8)
    except OSError as e:
        log(f"shortcut listener bind failed: {e}")
        return
    log(f"shortcut listener on 127.0.0.1:{SHORTCUT_PORT}")
    while True:
        try:
            conn, _ = srv.accept()
            conn.settimeout(1)
            try:
                data = conn.recv(8)
            finally:
                conn.close()
            key = data.decode("utf-8", "ignore").strip()
            if key in allowed:
                now = time.monotonic()
                if now - last_fire.get(key, 0.0) < debounce:
                    continue
                last_fire[key] = now
                log(f"shortcut -> host: {key}")
                link.send({"event": "shortcut", "key": key})
        except Exception as e:
            log(f"shortcut listener: {e}")
            time.sleep(0.1)


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
    threading.Thread(target=shortcut_listener, args=(link,), daemon=True).start()

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

        # Inject + read the per-tab tracker once per target; the result
        # carries both visibility (used to pick the active tab) and
        # media tracker output. Skipped for non-evaluable urls.
        states = {}
        for t in targets:
            url = t.get("url") or ""
            ws = t.get("webSocketDebuggerUrl") or ""
            if ws and url.startswith(("http://", "https://")):
                states[t["id"]] = tab_state(ws)
            else:
                states[t["id"]] = ("", "")

        visibility = {tid: vis for tid, (vis, _) in states.items()}
        active_id = active_target_id(targets, visibility)

        current_ids = set()
        for t in targets:
            tid = t["id"]
            current_ids.add(tid)
            title = t.get("title") or ""
            url = t.get("url") or ""
            _, media = states.get(tid, ("", ""))
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
                # Record navigations into session history. Fire on URL change
                # and on title change (the first upsert of a page often lands
                # before its <title> resolves) — _record_visit upserts by URL.
                if prev is None or prev.get("url") != url or prev.get("title") != title:
                    _record_visit(title, url)
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
                gone = known.get(tid, {})
                _record_close(gone.get("title", ""), gone.get("url", ""))
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
