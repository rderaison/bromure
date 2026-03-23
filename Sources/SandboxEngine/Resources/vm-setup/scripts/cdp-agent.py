#!/usr/bin/python3 -u
"""Bromure CDP agent — runs inside the guest VM.

Bridges Chrome DevTools Protocol from Chromium (TCP localhost:9222) to the
host over vsock port 5200.

Architecture (guest-initiated connection pool):
  1. This agent opens N vsock connections to the host (port 5200) proactively.
  2. When the host pairs one with a TCP client, data starts flowing.
  3. On first data, this agent connects to Chromium's CDP and bridges.
  4. After each connection is consumed, a replacement is opened.

This matches the existing Bromure vsock pattern where the guest always
initiates connections to the host (CID 2).

Started from xinitrc when AUTOMATION=1.
"""

import os
import select
import signal
import socket
import sys
import time
import threading

VSOCK_PORT = 5200
HOST_CID = 2
CDP_HOST = "127.0.0.1"
CDP_PORT = 9222
BUF_SIZE = 65536
POOL_SIZE = 8

running = True


def signal_handler(sig, frame):
    global running
    running = False


def bridge(vsock_fd, tcp_sock):
    """Bidirectionally forward data between vsock fd and TCP socket until either closes."""
    try:
        while True:
            readable, _, exceptional = select.select(
                [vsock_fd, tcp_sock], [], [vsock_fd, tcp_sock], 1.0
            )
            if exceptional:
                break
            for sock in readable:
                if sock is tcp_sock:
                    data = tcp_sock.recv(BUF_SIZE)
                    if not data:
                        return
                    total = 0
                    while total < len(data):
                        sent = os.write(vsock_fd, data[total:])
                        if sent <= 0:
                            return
                        total += sent
                else:
                    data = os.read(vsock_fd, BUF_SIZE)
                    if not data:
                        return
                    tcp_sock.sendall(data)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        try:
            tcp_sock.close()
        except OSError:
            pass
        # Don't close vsock_fd — the vsock socket object owns it


def handle_connection(vsock_sock, replenish_fn):
    """Wait for first data on the vsock, then bridge to Chromium CDP."""
    try:
        # Wait for first data from host (this means a TCP client was paired)
        vsock_sock.settimeout(None)
        first_data = vsock_sock.recv(BUF_SIZE)
        if not first_data:
            vsock_sock.close()
            replenish_fn()
            return
    except (ConnectionResetError, OSError):
        try:
            vsock_sock.close()
        except OSError:
            pass
        replenish_fn()
        return

    # Connect to Chromium's CDP
    try:
        tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp_sock.connect((CDP_HOST, CDP_PORT))
    except (ConnectionRefusedError, OSError) as e:
        print(f"cdp-agent: cannot connect to CDP: {e}", file=sys.stderr)
        vsock_sock.close()
        replenish_fn()
        return

    # Forward the first chunk we already read
    try:
        tcp_sock.sendall(first_data)
    except (BrokenPipeError, OSError):
        tcp_sock.close()
        vsock_sock.close()
        replenish_fn()
        return

    # Bridge the rest
    vsock_fd = vsock_sock.fileno()
    bridge(vsock_fd, tcp_sock)
    vsock_sock.close()

    # Replenish the pool
    replenish_fn()


def connect_to_host():
    """Open a vsock connection to the host. Returns socket or None."""
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.connect((HOST_CID, VSOCK_PORT))
        return s
    except (ConnectionRefusedError, ConnectionResetError, OSError) as e:
        return None


def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Wait for Chromium's CDP port to be ready
    print("cdp-agent: waiting for Chromium CDP...", file=sys.stderr)
    for _ in range(120):
        if not running:
            return
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
        print("cdp-agent: Chromium CDP port not ready after 120s, exiting", file=sys.stderr)
        return

    print(f"cdp-agent: Chromium CDP ready on {CDP_HOST}:{CDP_PORT}", file=sys.stderr)

    lock = threading.Lock()

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
        print("cdp-agent: failed to replenish pool after 20 attempts", file=sys.stderr)

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

    print(f"cdp-agent: pool ready ({established} connections)", file=sys.stderr)

    # Keep main thread alive
    while running:
        time.sleep(1)

    print("cdp-agent: shutting down", file=sys.stderr)


if __name__ == "__main__":
    main()
