#!/usr/bin/python3 -u
"""Bromure file picker native messaging host — runs inside the guest VM.

Bridges Chrome native messaging (stdin/stdout) to the host over vsock.
The Chrome extension sends "pick a file" requests; this agent forwards
them to the host FilePickerBridge (vsock port 5600, JSON-only control channel).

The actual file data is sent by the host via the existing file-agent.py
(vsock port 5100) which writes to /home/chrome/. This agent waits for
the file to appear on disk, then tells Chrome the local path so the
background SW can use chrome.debugger + DOM.setFileInputFiles.

Protocol with host (vsock port 5600): newline-delimited JSON.

  Guest → Host:  {"type":"pick","accept":"image/*,.pdf","requestId":"..."}
  Host → Guest:  {"type":"pick_result","requestId":"...","status":"ok",
                   "filename":"photo.jpg","mimeType":"image/jpeg","size":12345}
            OR:  {"type":"pick_result","requestId":"...","status":"cancelled"}
"""

import json
import os
import select
import signal
import socket
import struct
import sys
import time

VSOCK_PORT = 5600
HOST_CID = 2  # Apple Virtualization.framework host CID
FILE_DIR = "/home/chrome"
FILE_WAIT_TIMEOUT = 30  # seconds to wait for file to appear


def log(msg):
    """Log to stderr (stdout is reserved for native messaging)."""
    print(f"[file-picker-host] {msg}", file=sys.stderr, flush=True)


def nm_read():
    """Read one native messaging message from stdin. Returns dict or None."""
    raw_len = sys.stdin.buffer.read(4)
    if not raw_len or len(raw_len) < 4:
        return None
    msg_len = struct.unpack("<I", raw_len)[0]
    if msg_len == 0 or msg_len > 1 * 1024 * 1024:
        return None
    data = sys.stdin.buffer.read(msg_len)
    if not data or len(data) < msg_len:
        return None
    return json.loads(data)


def nm_write(obj):
    """Write one native messaging message to stdout."""
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def send_json(sock, obj):
    """Send a JSON object as a newline-terminated string over vsock."""
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    sock.sendall(line.encode("utf-8"))


def recv_line(sock, buf):
    """Read a complete newline-delimited JSON line from buffer + socket.
    Returns (parsed_dict, remaining_buf)."""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line), buf


def wait_for_file(filepath, expected_size, timeout):
    """Wait for a file to appear on disk and reach expected_size bytes.
    Returns True if the file reached the expected size."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            size = os.path.getsize(filepath)
            if size >= expected_size:
                return True
        except OSError:
            pass
        time.sleep(0.05)
    return False


def handle_pick_request(sock, msg, vsock_buf):
    """Forward a pick request to the host and relay the response back to Chrome."""
    request_id = msg.get("requestId", "")
    log(f"pick request: requestId={request_id}")

    # Forward to host
    send_json(sock, {
        "type": "pick",
        "accept": msg.get("accept", ""),
        "multiple": msg.get("multiple", False),
        "requestId": request_id,
    })
    log("forwarded to host, waiting for response...")

    # Wait for host JSON response (metadata only, no file data on this channel)
    resp, vsock_buf = recv_line(sock, vsock_buf)
    log(f"host response: status={resp.get('status')} filename={resp.get('filename', '')}")

    if resp.get("status") == "cancelled":
        nm_write({
            "type": "pick_result",
            "requestId": request_id,
            "status": "cancelled",
        })
        log("cancelled, notified Chrome")
        return vsock_buf

    filename = resp.get("filename", "file")
    expected_size = resp.get("size", 0)

    # The file data arrives via file-agent.py (port 5100) → /home/chrome/<filename>
    safe_name = os.path.basename(filename)
    if not safe_name or safe_name in (".", ".."):
        safe_name = "upload"
    filepath = os.path.join(FILE_DIR, safe_name)

    log(f"waiting for {filepath} ({expected_size} bytes via file-agent)...")
    if not wait_for_file(filepath, expected_size, FILE_WAIT_TIMEOUT):
        actual = -1
        try:
            actual = os.path.getsize(filepath)
        except OSError:
            pass
        log(f"timeout waiting for {filepath} (expected={expected_size}, actual={actual})")
        nm_write({
            "type": "pick_result",
            "requestId": request_id,
            "status": "cancelled",
        })
        return vsock_buf

    log(f"file ready: {filepath} ({os.path.getsize(filepath)} bytes)")

    # Tell Chrome the local path — background.js will use chrome.debugger
    # + DOM.setFileInputFiles to set it on the <input>
    nm_write({
        "type": "pick_result",
        "requestId": request_id,
        "status": "ok",
        "path": filepath,
    })
    log(f"sent path to Chrome: {filepath}")

    return vsock_buf


def run(sock):
    """Main loop: bridge native messaging <-> vsock."""
    vsock_buf = b""
    stdin_fd = sys.stdin.buffer.fileno()

    log("connected to host, entering main loop")

    while True:
        readable, _, _ = select.select([stdin_fd], [], [], 5.0)

        for fd in readable:
            if fd == stdin_fd:
                msg = nm_read()
                if msg is None:
                    log("stdin closed (Chrome disconnected)")
                    return
                log(f"Chrome message: type={msg.get('type')}")
                if msg.get("type") == "pick":
                    vsock_buf = handle_pick_request(sock, msg, vsock_buf)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    log("starting")

    while True:
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, VSOCK_PORT))
            log("connected to host vsock")
            run(sock)
        except (ConnectionError, OSError) as e:
            log(f"connection error: {e}")
        finally:
            try:
                sock.close()
            except Exception:
                pass
        time.sleep(3)


if __name__ == "__main__":
    main()
