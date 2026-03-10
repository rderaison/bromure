#!/usr/bin/python3 -u
"""Bromure credential bridge agent — runs inside the guest VM.

Bridges Chrome native messaging (stdin/stdout) to the host over vsock.
The Chrome extension sends WebAuthn/password requests via native messaging;
this agent forwards them to the host CredentialBridge and relays responses.

Protocol: newline-delimited JSON over vsock (same as file-agent.py).
Native messaging: 4-byte LE length prefix + JSON (Chrome standard).

Started from xinitrc unconditionally (lightweight when idle).
"""

import json
import os
import select
import signal
import socket
import struct
import sys
import threading

VSOCK_PORT = 5200
HOST_CID = 2  # Apple Virtualization.framework host CID

# Native messaging reads/writes on stdin/stdout with 4-byte LE length prefix.

def nm_read():
    """Read one native messaging message from stdin. Returns dict or None."""
    raw_len = sys.stdin.buffer.read(4)
    if not raw_len or len(raw_len) < 4:
        return None
    msg_len = struct.unpack("<I", raw_len)[0]
    if msg_len == 0 or msg_len > 10 * 1024 * 1024:
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

    # Pending requests: requestId -> True (just tracking, response goes to stdout)
    pending = set()

    while True:
        readable, _, _ = select.select([sock_fd, stdin_fd], [], [], 5.0)

        for fd in readable:
            if fd == stdin_fd:
                # Native messaging from Chrome extension
                msg = nm_read()
                if msg is None:
                    # Extension disconnected
                    return
                # Forward to host via vsock
                send_json(sock, msg)
                rid = msg.get("requestId")
                if rid:
                    pending.add(rid)

            elif fd == sock_fd:
                # Response from host via vsock
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

                    rid = resp.get("requestId")
                    if rid and rid in pending:
                        pending.discard(rid)
                    # Send response back to Chrome extension
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
        import time
        time.sleep(3)


if __name__ == "__main__":
    main()
