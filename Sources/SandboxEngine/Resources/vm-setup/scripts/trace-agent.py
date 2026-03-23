#!/usr/bin/python3 -u
"""Bromure trace agent — runs inside the guest VM.

Bridges Chrome native messaging (stdin/stdout) to the host over vsock.
The Chrome extension captures web request telemetry and sends batched events;
this agent forwards them to the host trace bridge.

Protocol: newline-delimited JSON over vsock (port 5900).
Native messaging: 4-byte LE length prefix + JSON (Chrome standard).

Reads /tmp/bromure/chrome-env for TRACE_LEVEL on startup and sends it
to the extension as the initial config message.
"""

import json
import os
import select
import signal
import socket
import struct
import sys
import time

VSOCK_PORT = 5900
HOST_CID = 2  # Apple Virtualization.framework host CID
CHROME_ENV_PATH = "/tmp/bromure/chrome-env"


def read_trace_level():
    """Read TRACE_LEVEL from chrome-env config file. Defaults to 1."""
    try:
        with open(CHROME_ENV_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("TRACE_LEVEL="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return int(val)
    except (FileNotFoundError, ValueError, OSError):
        pass
    return 1


def nm_read():
    """Read one native messaging message from stdin. Returns dict or None."""
    raw_len = sys.stdin.buffer.read(4)
    if not raw_len or len(raw_len) < 4:
        return None
    msg_len = struct.unpack("<I", raw_len)[0]
    if msg_len == 0 or msg_len > 4 * 1024 * 1024:
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


def run(sock, trace_level):
    """Main loop: bridge native messaging <-> vsock.

    On connect, sends the trace config to the extension. Then forwards
    extension events to the host and host messages to the extension.
    """
    # Send config to the extension so it knows what level to trace at.
    nm_write({"type": "config", "level": trace_level})

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
                # Forward extension events to host over vsock.
                # Batched events arrive as {type:"events", events:[...]};
                # unbundle and send each individually for simple host parsing.
                if msg.get("type") == "events" and isinstance(
                    msg.get("events"), list
                ):
                    for evt in msg["events"]:
                        send_json(sock, evt)
                else:
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

    trace_level = read_trace_level()

    while True:
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, VSOCK_PORT))
            run(sock, trace_level)
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
