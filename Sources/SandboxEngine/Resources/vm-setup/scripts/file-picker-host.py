#!/usr/bin/python3 -u
"""Bromure file picker native messaging host — runs inside the guest VM.

Bridges Chrome native messaging (stdin/stdout) to the host over vsock.

Two flows:
  1. File picker (guest-initiated): Chrome extension sends "pick" →
     this agent forwards to host → host shows NSOpenPanel → file sent via
     port 5100 → this agent waits for file on disk → tells Chrome the path →
     background.js uses chrome.debugger + DOM.setFileInputFiles.

  2. Drag-and-drop (host-initiated): host sends "drop" on vsock with
     filenames + coordinates → files arrive via port 5100 → this agent waits
     for files on disk → tells Chrome the paths + coordinates →
     background.js uses chrome.debugger + Input.dispatchDragEvent.

Protocol with host (vsock port 5600): newline-delimited JSON.
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


def drain_vsock(sock, buf):
    """Read available data from vsock and yield complete JSON messages."""
    try:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    except BlockingIOError:
        pass

    messages = []
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if line:
            messages.append(json.loads(line))
    return messages, buf


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


def safe_filepath(filename):
    """Return a safe path under FILE_DIR for the given filename."""
    safe_name = os.path.basename(filename)
    if not safe_name or safe_name in (".", ".."):
        safe_name = "upload"
    return os.path.join(FILE_DIR, safe_name)


def handle_pick_response(resp, request_id):
    """Process a pick_result from the host and forward to Chrome."""
    log(f"host response: status={resp.get('status')} filename={resp.get('filename', '')}")

    if resp.get("status") == "cancelled":
        nm_write({
            "type": "pick_result",
            "requestId": request_id,
            "status": "cancelled",
        })
        log("cancelled, notified Chrome")
        return

    filename = resp.get("filename", "file")
    expected_size = resp.get("size", 0)
    filepath = safe_filepath(filename)

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
        return

    log(f"file ready: {filepath} ({os.path.getsize(filepath)} bytes)")
    nm_write({
        "type": "pick_result",
        "requestId": request_id,
        "status": "ok",
        "path": filepath,
    })
    log(f"sent path to Chrome: {filepath}")


def handle_drop(msg):
    """Process a drop message from the host: wait for files, forward to Chrome."""
    files_info = msg.get("files", [])
    x = msg.get("x", 0)
    y = msg.get("y", 0)
    log(f"drop: {len(files_info)} file(s) at ({x}, {y})")

    # Wait for all files to appear on disk
    paths = []
    for finfo in files_info:
        filename = finfo.get("filename", "file")
        expected_size = finfo.get("size", 0)
        filepath = safe_filepath(filename)

        log(f"waiting for {filepath} ({expected_size} bytes)...")
        if not wait_for_file(filepath, expected_size, FILE_WAIT_TIMEOUT):
            actual = -1
            try:
                actual = os.path.getsize(filepath)
            except OSError:
                pass
            log(f"timeout waiting for {filepath} (expected={expected_size}, actual={actual})")
            return  # silently abort if any file doesn't arrive
        paths.append(filepath)

    log(f"all {len(paths)} file(s) ready, forwarding to Chrome")
    nm_write({
        "type": "drop",
        "files": paths,
        "x": x,
        "y": y,
    })


def run(sock):
    """Main loop: bridge native messaging <-> vsock."""
    vsock_buf = b""
    stdin_fd = sys.stdin.buffer.fileno()
    sock_fd = sock.fileno()
    sock.setblocking(False)

    # Pending pick requests waiting for host response: requestId -> True
    pending_picks = {}

    log("connected to host, entering main loop")

    while True:
        readable, _, _ = select.select([stdin_fd, sock_fd], [], [], 5.0)

        for fd in readable:
            if fd == stdin_fd:
                msg = nm_read()
                if msg is None:
                    log("stdin closed (Chrome disconnected)")
                    return

                log(f"Chrome message: type={msg.get('type')}")
                if msg.get("type") == "pick":
                    request_id = msg.get("requestId", "")
                    # Forward pick request to host
                    send_json(sock, {
                        "type": "pick",
                        "accept": msg.get("accept", ""),
                        "multiple": msg.get("multiple", False),
                        "requestId": request_id,
                    })
                    pending_picks[request_id] = True
                    log(f"forwarded pick to host: {request_id}")

            elif fd == sock_fd:
                messages, vsock_buf = drain_vsock(sock, vsock_buf)
                for vmsg in messages:
                    msg_type = vmsg.get("type", "")

                    if msg_type == "pick_result":
                        # Response to a pending pick request
                        request_id = vmsg.get("requestId", "")
                        if request_id in pending_picks:
                            del pending_picks[request_id]
                            handle_pick_response(vmsg, request_id)
                        else:
                            log(f"pick_result for unknown request: {request_id}")

                    elif msg_type == "drop":
                        # Host-initiated drag-and-drop
                        handle_drop(vmsg)

                    elif msg_type in ("drag_enter", "drag_move", "drag_exit"):
                        # Drag hover events — forward directly to Chrome
                        nm_write(vmsg)


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
