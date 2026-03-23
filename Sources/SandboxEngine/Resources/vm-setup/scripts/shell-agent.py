#!/usr/bin/python3 -u
"""Bromure shell agent — runs inside the guest VM.

Provides remote shell execution from the host over vsock port 5800.
Uses length-prefixed JSON protocol:
  Request:  [u32be len][{"cmd": "...", "timeout": 30}]
  Response: [u32be len][{"stdout": "...", "stderr": "...", "exit_code": 0}]

Guest-initiated connection pool pattern (same as cdp-agent.py):
  1. Opens N vsock connections to the host proactively.
  2. When the host sends a command, this agent executes it.
  3. After each command, a replacement connection is opened.

Started from xinitrc when DEBUG_SHELL=1 (set by host when BROMURE_DEBUG_CLAUDE is set).
"""

import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

VSOCK_PORT = 5800
HOST_CID = 2
POOL_SIZE = 4
MAX_REQUEST_SIZE = 10 * 1024 * 1024  # 10 MB

running = True


def signal_handler(sig, frame):
    global running
    running = False


def recv_exact(sock, n):
    """Read exactly n bytes from socket."""
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def handle_connection(vsock_sock, replenish_fn):
    """Wait for a command from the host, execute it, return the result."""
    try:
        # Read length-prefixed JSON request
        hdr = recv_exact(vsock_sock, 4)
        if not hdr:
            vsock_sock.close()
            replenish_fn()
            return

        length = struct.unpack(">I", hdr)[0]
        if length > MAX_REQUEST_SIZE:
            vsock_sock.close()
            replenish_fn()
            return

        data = recv_exact(vsock_sock, length)
        if not data:
            vsock_sock.close()
            replenish_fn()
            return

        req = json.loads(data.decode("utf-8"))
        cmd = req.get("cmd", "")
        timeout = req.get("timeout", 30)
        workdir = req.get("workdir")

        # Execute command
        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=timeout, cwd=workdir
            )
            response = {
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit_code": result.returncode,
            }
        except subprocess.TimeoutExpired:
            response = {
                "stdout": "",
                "stderr": f"Command timed out after {timeout}s",
                "exit_code": -1,
            }
        except Exception as e:
            response = {
                "stdout": "",
                "stderr": str(e),
                "exit_code": -1,
            }

        # Send length-prefixed JSON response
        resp_data = json.dumps(response).encode("utf-8")
        resp_hdr = struct.pack(">I", len(resp_data))
        vsock_sock.sendall(resp_hdr + resp_data)

    except (BrokenPipeError, ConnectionResetError, OSError) as e:
        print(f"shell-agent: connection error: {e}", file=sys.stderr)
    finally:
        try:
            vsock_sock.close()
        except OSError:
            pass
        replenish_fn()


def connect_to_host():
    """Open a vsock connection to the host. Returns socket or None."""
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.connect((HOST_CID, VSOCK_PORT))
        return s
    except (ConnectionRefusedError, ConnectionResetError, OSError):
        return None


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    print("shell-agent: starting", file=sys.stderr)

    def replenish():
        """Open a new vsock connection to refill the pool."""
        for attempt in range(20):
            if not running:
                return
            s = connect_to_host()
            if s:
                t = threading.Thread(target=handle_connection, args=(s, replenish), daemon=True)
                t.start()
                return
            time.sleep(0.1)
        print("shell-agent: failed to replenish pool after 20 attempts", file=sys.stderr)

    # Fill the initial pool
    established = 0
    for _ in range(POOL_SIZE):
        if not running:
            return
        for attempt in range(30):
            if not running:
                return
            s = connect_to_host()
            if s:
                established += 1
                t = threading.Thread(target=handle_connection, args=(s, replenish), daemon=True)
                t.start()
                break
            time.sleep(0.2)

    print(f"shell-agent: pool ready ({established} connections)", file=sys.stderr)

    # Keep main thread alive
    while running:
        time.sleep(1)

    print("shell-agent: shutting down", file=sys.stderr)


if __name__ == "__main__":
    main()
