#!/usr/bin/python3 -u
"""Routing SOCKS5 proxy — switches between direct and upstream (WARP).

Binds to 127.0.0.1:40001.  Per-connection, checks /tmp/bromure/warp-active:
  - If present: forwards through upstream SOCKS5 at 127.0.0.1:40000 (warp-svc)
  - If absent:  connects directly to the destination

Squid (via proxychains) always connects here.  When WARP is enabled, warp-svc
runs on :40000 and the flag file controls routing.  Enable/disable is instant
— just toggling the flag, no process swap or port rebind.

Supports CONNECT command only (IPv4, IPv6, and domain name addressing).
"""

import os
import select
import signal
import socket
import struct
import sys
import threading
import time

BIND_ADDR = "127.0.0.1"
BIND_PORT = 40001
WARP_UPSTREAM = ("127.0.0.1", 40000)
WARP_FLAG = "/tmp/bromure/warp-active"
RELAY_BUF = 65536
MAX_THREADS = 256
MAX_CONNECTION_TIME = 86400  # 24 hours — matches VM session lifetime

_conn_semaphore = threading.Semaphore(MAX_THREADS)
_monotonic = time.monotonic


def relay(a, b):
    """Bidirectional relay between two sockets until one side closes."""
    deadline = _monotonic() + MAX_CONNECTION_TIME
    try:
        while True:
            remaining = deadline - _monotonic()
            if remaining <= 0:
                break
            timeout = min(remaining, 60.0)
            readable, _, _ = select.select([a, b], [], [], timeout)
            if not readable:
                if _monotonic() >= deadline:
                    break
                continue
            for sock in readable:
                data = sock.recv(RELAY_BUF)
                if not data:
                    return
                peer = b if sock is a else a
                peer.sendall(data)
    except (OSError, BrokenPipeError):
        pass
    finally:
        a.close()
        b.close()


def connect_via_upstream(atyp, addr, port):
    """Connect to target through upstream SOCKS5 proxy (warp-svc on :40001)."""
    upstream = socket.create_connection(WARP_UPSTREAM, timeout=10)
    try:
        # SOCKS5 greeting: version 5, 1 method (no auth)
        upstream.sendall(b"\x05\x01\x00")
        resp = upstream.recv(2)
        if len(resp) < 2 or resp[0] != 0x05 or resp[1] != 0x00:
            raise OSError("upstream SOCKS5 greeting rejected")

        # Build CONNECT request
        req = b"\x05\x01\x00"
        if atyp == 0x01:  # IPv4
            req += b"\x01" + socket.inet_aton(addr) + struct.pack("!H", port)
        elif atyp == 0x03:  # Domain
            encoded = addr.encode("ascii")
            req += b"\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", port)
        elif atyp == 0x04:  # IPv6
            req += b"\x04" + socket.inet_pton(socket.AF_INET6, addr) + struct.pack("!H", port)
        upstream.sendall(req)

        # Read response (variable length depending on address type)
        resp = upstream.recv(256)
        if len(resp) < 2 or resp[1] != 0x00:
            raise OSError("upstream SOCKS5 connect refused")

        return upstream
    except:
        upstream.close()
        raise


def handle_client(client):
    """Handle one SOCKS5 client connection."""
    remote = None
    try:
        # --- Greeting ---
        greeting = client.recv(256)
        if len(greeting) < 2 or greeting[0] != 0x05:
            return
        # No authentication required
        client.sendall(b"\x05\x00")

        # --- Connect request ---
        req = client.recv(256)
        if len(req) < 4 or req[0] != 0x05 or req[1] != 0x01:
            # Only CONNECT (0x01) is supported
            client.sendall(b"\x05\x07\x00\x01" + b"\x00" * 6)
            return

        atyp = req[3]
        if atyp == 0x01:  # IPv4
            if len(req) < 10:
                return
            addr = socket.inet_ntoa(req[4:8])
            port = struct.unpack("!H", req[8:10])[0]
        elif atyp == 0x03:  # Domain name
            alen = req[4]
            if len(req) < 5 + alen + 2:
                return
            raw = req[5 : 5 + alen]
            if not all(0x20 < b < 0x7F for b in raw):
                client.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6)
                return
            addr = raw.decode("ascii")
            port = struct.unpack("!H", req[5 + alen : 7 + alen])[0]
        elif atyp == 0x04:  # IPv6
            if len(req) < 22:
                return
            addr = socket.inet_ntop(socket.AF_INET6, req[4:20])
            port = struct.unpack("!H", req[20:22])[0]
        else:
            client.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6)
            return

        # Reject port 0
        if port == 0:
            client.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)
            return

        # --- Route: through WARP upstream or direct ---
        try:
            if os.path.exists(WARP_FLAG):
                remote = connect_via_upstream(atyp, addr, port)
            else:
                remote = socket.create_connection((addr, port), timeout=10)
        except OSError:
            # Connection refused / host unreachable
            client.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            return

        # Success reply
        client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)

        # --- Relay (takes ownership of both sockets) ---
        relay(client, remote)
        remote = None  # relay closed it
        client = None  # relay closed it

    except (OSError, BrokenPipeError):
        pass
    finally:
        if remote is not None:
            try:
                remote.close()
            except OSError:
                pass
        if client is not None:
            try:
                client.close()
            except OSError:
                pass
        _conn_semaphore.release()


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((BIND_ADDR, BIND_PORT))
    srv.listen(128)
    print(f"routing-socks: listening on {BIND_ADDR}:{BIND_PORT}", file=sys.stderr)

    while True:
        try:
            client, _ = srv.accept()
            client.settimeout(30)
            if not _conn_semaphore.acquire(blocking=False):
                # Too many connections — reject
                client.close()
                continue
            t = threading.Thread(target=handle_client, args=(client,), daemon=True)
            t.start()
        except OSError:
            break


if __name__ == "__main__":
    main()
