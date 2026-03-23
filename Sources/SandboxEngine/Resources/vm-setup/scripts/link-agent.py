#!/usr/bin/python3 -u
"""Bromure link sender agent — runs inside the guest VM.

Bridges Chrome native messaging (stdin/stdout) to the host over vsock.
The Chrome extension sends "open this URL in another profile" requests;
this agent forwards them to the host LinkSenderBridge.

Protocol: newline-delimited JSON over vsock (port 5300).
Native messaging: 4-byte LE length prefix + JSON (Chrome standard).

Started from xinitrc when the link-sender extension is loaded.
"""

import json
import select
import signal
import socket
import struct
import sys
import time

VSOCK_PORT = 5300
HOST_CID = 2  # Apple Virtualization.framework host CID


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


def run(sock):
    """Main loop: bridge native messaging <-> vsock."""
    sock_buf = b""
    sock_fd = sock.fileno()
    stdin_fd = sys.stdin.buffer.fileno()

    while True:
        readable, _, _ = select.select([sock_fd, stdin_fd], [], [], 5.0)

        for fd in readable:
            if fd == stdin_fd:
                msg = nm_read()
                if msg is None:
                    return
                send_json(sock, msg)

            elif fd == sock_fd:
                chunk = sock.recv(65536)
                if not chunk:
                    return
                sock_buf += chunk

                while b"\n" in sock_buf:
                    line, sock_buf = sock_buf.split(b"\n", 1)
                    if not line:
                        continue
                    try:
                        resp = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    nm_write(resp)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    while True:
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, VSOCK_PORT))
            run(sock)
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                sock.close()
            except Exception:
                pass
        time.sleep(3)


if __name__ == "__main__":
    main()
