#!/usr/bin/python3 -u
"""Bromure Chromium input agent — injects host input events via CDP.

Runs inside the guest VM. The host sends JSON messages over vsock port 5007:

  {"type": "compose", "text": "みち"}              → inline IME composition
  {"type": "commit",  "text": "道"}                → insert final committed text
  {"type": "clear"}                                → cancel composition
  {"type": "rawKeyDown"|"keyUp"|"char", ...}       → passthrough key event
  {"type": "wheel", "x", "y", "deltaX", "deltaY",  → synthetic mouse-wheel
                    "ctrl", ...}                     (used for pinch-to-zoom)

The agent translates these into Chrome DevTools Protocol calls:
  - Input.imeSetComposition  (compose / clear)
  - Input.insertText         (commit)
  - Input.dispatchKeyEvent   (keyDown / keyUp / rawKeyDown / char)
  - Input.dispatchMouseEvent (wheel)

Started at boot via inittab (runs as chrome user).
"""

import hashlib
import http.client
import json
import os
import socket
import struct
import sys
import threading
import time

VSOCK_PORT = 5007
CDP_HOST = "127.0.0.1"
CDP_PORT = 9222


# ---------------------------------------------------------------------------
# Minimal WebSocket client (no external dependencies)
# ---------------------------------------------------------------------------

def ws_connect(url):
    """Open a WebSocket connection. Returns the socket."""
    # Parse ws://host:port/path
    assert url.startswith("ws://")
    rest = url[5:]
    host_port, path = rest.split("/", 1)
    path = "/" + path
    if ":" in host_port:
        host, port = host_port.split(":")
        port = int(port)
    else:
        host, port = host_port, 80

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))

    # WebSocket handshake
    key = "dGhlIHNhbXBsZSBub25jZQ=="  # static key is fine for local CDP
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    sock.sendall(request.encode())

    # Read response headers
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("WebSocket handshake failed")
        response += chunk

    if b"101" not in response.split(b"\r\n")[0]:
        raise ConnectionError(f"WebSocket upgrade rejected: {response[:200]}")

    return sock


def ws_send(sock, data):
    """Send a WebSocket text frame (masked, as required by RFC 6455 for clients)."""
    payload = data.encode("utf-8") if isinstance(data, str) else data
    frame = bytearray()
    frame.append(0x81)  # FIN + text opcode

    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)  # masked
    elif length < 65536:
        frame.append(0x80 | 126)
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(0x80 | 127)
        frame.extend(struct.pack(">Q", length))

    # Masking key (all zeros — local connection, security not relevant)
    mask = b"\x00\x00\x00\x00"
    frame.extend(mask)
    frame.extend(payload)  # XOR with zero mask = identity
    sock.sendall(frame)


def ws_recv(sock):
    """Read one WebSocket frame. Returns the payload as string."""
    def read_exact(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("WebSocket closed")
            buf += chunk
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

    if opcode == 0x08:  # close
        raise ConnectionError("WebSocket closed by server")
    if opcode == 0x09:  # ping
        # Send pong
        pong = bytearray([0x8A, 0x80, 0, 0, 0, 0])
        sock.sendall(pong)
        return ws_recv(sock)  # read next real frame

    return data.decode("utf-8") if isinstance(data, (bytes, bytearray)) else data


# ---------------------------------------------------------------------------
# CDP helper
# ---------------------------------------------------------------------------

class CDPClient:
    """Minimal Chrome DevTools Protocol client.

    Design note: the response-drain path runs on a dedicated blocking
    reader thread rather than a per-send non-blocking drain. The previous
    non-blocking approach used `ws_recv` against a non-blocking socket;
    when a response frame arrived split across two kernel-buffer deliveries
    (rare at low rates, common at ~60 Hz pinch-zoom), `read_exact` would
    consume the header bytes, then raise `BlockingIOError` mid-payload,
    leaving the WebSocket stream in a corrupt half-parsed state. The next
    read would interpret random payload bytes as a frame header and
    eventually raise `OSError`, which was silently caught and closed the
    socket — breaking all subsequent CDP sends with no log trace.
    """

    def __init__(self):
        self.sock = None
        self.msg_id = 0
        # Serialises writes against the reader thread's pong response in
        # ws_recv. Individual WebSocket frames must be delivered atomically
        # or the peer sees garbage.
        self._send_lock = threading.Lock()
        # Chromium's devicePixelRatio — host sends coordinates in guest device
        # pixels (matching the X11/Xorg framebuffer), but CDP expects CSS
        # pixels (= device / DPR). Queried once at connect time; defaults to
        # 1.0 if the query fails.
        self.dpr = 1.0

    def connect(self):
        """Connect to Chromium's first page target via CDP WebSocket."""
        # Get the list of targets
        conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=5)
        conn.request("GET", "/json")
        resp = conn.getresponse()
        targets = json.loads(resp.read())
        conn.close()

        # Find a page target
        ws_url = None
        for t in targets:
            if t.get("type") == "page":
                ws_url = t.get("webSocketDebuggerUrl")
                break

        if not ws_url:
            raise RuntimeError("No page target found")

        self.sock = ws_connect(ws_url)

        # Synchronously probe devicePixelRatio BEFORE spawning the drain
        # thread (otherwise the drain would consume our reply). Chromium
        # typically runs at --force-device-scale-factor=2 here, so coords
        # from the host — which are in guest device pixels — must be
        # divided by 2 before being dispatched as CSS-pixel CDP events.
        try:
            probe = json.dumps({
                "id": 0,
                "method": "Runtime.evaluate",
                "params": {"expression": "devicePixelRatio", "returnByValue": True},
            })
            ws_send(self.sock, probe)
            for _ in range(10):
                raw = ws_recv(self.sock)
                try:
                    msg = json.loads(raw) if isinstance(raw, str) else json.loads(raw.decode("utf-8"))
                except (ValueError, AttributeError):
                    continue
                if msg.get("id") == 0:
                    value = msg.get("result", {}).get("result", {}).get("value")
                    if isinstance(value, (int, float)) and value > 0:
                        self.dpr = float(value)
                    break
            # msg_id stays where it was — probe used id=0 which can't collide.
            print(f"cjk-input-agent: DPR={self.dpr}", file=sys.stderr)
        except (OSError, ConnectionError, ValueError) as e:
            print(f"cjk-input-agent: DPR probe failed ({e}); assuming 1.0", file=sys.stderr)
            self.dpr = 1.0

        # Spawn a blocking reader that continuously drains response frames.
        # Running it on a thread (instead of draining in `send`) avoids the
        # non-blocking partial-frame corruption described in the class
        # docstring. Binding to the local `sock` value makes the loop exit
        # cleanly if `self.sock` is swapped out by `close()` or reconnect.
        sock = self.sock
        def drain():
            try:
                while self.sock is sock:
                    ws_recv(sock)
            except (ConnectionError, OSError):
                pass
            if self.sock is sock:
                self.sock = None
            try:
                sock.close()
            except OSError:
                pass
        threading.Thread(target=drain, daemon=True).start()

    def send(self, method, params=None):
        """Send a CDP command (fire-and-forget)."""
        sock = self.sock
        if not sock:
            return
        self.msg_id += 1
        msg = {"id": self.msg_id, "method": method}
        if params:
            msg["params"] = params
        try:
            with self._send_lock:
                ws_send(sock, json.dumps(msg))
        except (OSError, ConnectionError):
            self.close()

    def close(self):
        sock = self.sock
        self.sock = None
        if sock:
            try:
                sock.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def handle_message(cdp, msg):
    """Process a JSON message from the host."""
    msg_type = msg.get("type")
    text = msg.get("text", "")

    if msg_type == "compose":
        # Show inline composition (underlined text in the browser)
        cdp.send("Input.imeSetComposition", {
            "text": text,
            "selectionStart": len(text),
            "selectionEnd": len(text),
        })
    elif msg_type == "commit":
        # Insert final committed text
        cdp.send("Input.insertText", {"text": text})
    elif msg_type == "clear":
        # Cancel composition
        cdp.send("Input.imeSetComposition", {
            "text": "",
            "selectionStart": 0,
            "selectionEnd": 0,
        })
    elif msg_type in ("keyDown", "keyUp", "rawKeyDown", "char"):
        # Forward passthrough key events (backspace, arrows, Enter, etc.)
        key = msg.get("key", "")
        params = {
            "type": msg_type,
            "key": key,
        }
        if msg.get("code"):
            params["code"] = msg["code"]
        if msg.get("vk"):
            vk = int(msg["vk"])
            params["windowsVirtualKeyCode"] = vk
            params["nativeVirtualKeyCode"] = vk
        if msg.get("text"):
            params["text"] = msg["text"]
        # Map modifier flags
        modifiers = 0
        if msg.get("shift"): modifiers |= 8
        if msg.get("ctrl"):  modifiers |= 4
        if msg.get("alt"):   modifiers |= 1
        if msg.get("meta"):  modifiers |= 2
        if modifiers:
            params["modifiers"] = modifiers
        cdp.send("Input.dispatchKeyEvent", params)
    elif msg_type == "wheel":
        # Synthetic mouse-wheel (used for trackpad pinch-to-zoom on the host).
        # Host coords are in guest DEVICE pixels; CDP expects CSS pixels.
        # `document.elementFromPoint` and viewport hit-testing both work in
        # CSS units, so sending device-pixel coordinates silently lands the
        # wheel event outside the viewport on DPR>1 setups — Chromium acks
        # the command but dispatches to nothing, looking exactly like the
        # page is ignoring us.
        try:
            dpr = cdp.dpr or 1.0
            params = {
                "type": "mouseWheel",
                "x": float(msg.get("x", 0)) / dpr,
                "y": float(msg.get("y", 0)) / dpr,
                "deltaX": float(msg.get("deltaX", 0)),
                "deltaY": float(msg.get("deltaY", 0)),
            }
        except (TypeError, ValueError):
            return
        # Use CDP-correct modifier bits here (Alt=1, Ctrl=2, Meta=4, Shift=8).
        # The key-event path above intentionally swaps Ctrl/Meta to remap
        # macOS Cmd → Linux Ctrl, but for wheel zoom we need the literal Ctrl
        # bit so Chromium triggers page zoom (and web apps see ctrlKey=true).
        wheel_mods = 0
        if msg.get("alt"):   wheel_mods |= 1
        if msg.get("ctrl"):  wheel_mods |= 2
        if msg.get("meta"):  wheel_mods |= 4
        if msg.get("shift"): wheel_mods |= 8
        if wheel_mods:
            params["modifiers"] = wheel_mods
        cdp.send("Input.dispatchMouseEvent", params)
    else:
        print(f"cjk-input-agent: unknown message type: {msg_type}", file=sys.stderr)


def main():
    # Wait for Chromium's CDP port
    print("cjk-input-agent: waiting for Chromium CDP...", file=sys.stderr)
    for _ in range(120):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect((CDP_HOST, CDP_PORT))
            s.close()
            break
        except (ConnectionRefusedError, OSError):
            s.close()
            time.sleep(1)
    else:
        print("cjk-input-agent: CDP not ready after 120s, exiting", file=sys.stderr)
        return

    cdp = CDPClient()

    while True:
        try:
            # (Re)connect to CDP if needed
            if not cdp.sock:
                try:
                    cdp.connect()
                    print("cjk-input-agent: connected to CDP", file=sys.stderr)
                except Exception as e:
                    print(f"cjk-input-agent: CDP connect failed: {e}", file=sys.stderr)
                    time.sleep(2)
                    continue

            # Listen for host messages on vsock
            srv = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
            srv.listen(1)

            while True:
                conn, _ = srv.accept()
                try:
                    # Transparent reconnect: the background reader thread
                    # clears cdp.sock when CDP closes (peer shutdown, read
                    # error, etc.). Without this check we'd keep accepting
                    # vsock messages and silently drop every one forever
                    # because cdp.send() bails early on a None socket.
                    if not cdp.sock:
                        cdp.connect()
                        print("cjk-input-agent: reconnected to CDP", file=sys.stderr)

                    data = conn.recv(4096)
                    if not data:
                        continue
                    text = data.decode("utf-8")
                    try:
                        msg = json.loads(text)
                    except json.JSONDecodeError:
                        # Legacy plain-text protocol: treat as commit
                        msg = {"type": "commit", "text": text}

                    handle_message(cdp, msg)
                except Exception as e:
                    print(f"cjk-input-agent: message error: {e}", file=sys.stderr)
                    # CDP connection may have broken — reconnect next iteration
                    cdp.close()
                finally:
                    conn.close()

        except Exception as e:
            print(f"cjk-input-agent: error: {e}", file=sys.stderr)
            cdp.close()
            time.sleep(1)


if __name__ == "__main__":
    main()
