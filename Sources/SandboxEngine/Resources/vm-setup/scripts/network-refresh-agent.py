#!/usr/bin/python3 -u
"""Bromure network-refresh agent — runs inside the guest VM.

Connects to the host on vsock port 5703 and waits for "refresh" commands
that fire when the host's primary network changes (Wi-Fi roam, Ethernet
plug/unplug, VPN toggle, etc).

Only meaningful in bridged mode — in NAT mode the host never sends
refresh commands because vmnet handles roaming transparently, so this
agent just idles connected to a no-op host listener.

Refresh steps:
  1. Bounce eth0 (link-state toggle → kernel clears stale ARP/ND state).
  2. Kill any stale udhcpc daemon from the boot-time DHCP lease.
  3. Flush the neighbor cache (old gateway's MAC is no longer valid).
  4. Run udhcpc once to pick up a new lease. Alpine's default udhcpc
     script regenerates /etc/resolv.conf as a side effect.
  5. SIGHUP dnsmasq (if present) so ad-blocking resolvers also pick up
     the new upstream DNS servers.

Protocol: newline-delimited JSON on vsock port 5703.

Commands from host:
  {"type":"refresh"}

Responses to host (best-effort, host does not block on them):
  {"type":"refresh","ok":true|false,"error":"..."}

Started at boot via inittab (runs as root).
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time

VSOCK_PORT = 5703
HOST_CID = 2

IFACE = "eth0"
LOG_FILE = "/tmp/bromure/network-refresh-agent.log"


def log(msg):
    line = f"network-refresh-agent: {msg}"
    print(line, file=sys.stderr)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def run(cmd, quiet=False):
    if not quiet:
        log(f"  exec: {cmd}")
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        log(f"  TIMEOUT after 15s: {cmd}")
        return 1, ""
    if not quiet and r.returncode != 0:
        log(f"  rc={r.returncode} stderr={r.stderr.strip()!r}")
    return r.returncode, r.stdout.strip()


def do_refresh():
    """Re-acquire network configuration for eth0."""
    log("refresh: begin")

    # 1. Bounce the link. This forces the kernel to drop stale neighbor
    # entries on the interface and re-negotiate carrier with the host bridge.
    run(f"ip link set {IFACE} down", quiet=True)
    run(f"ip link set {IFACE} up", quiet=True)

    # 2. Kill any existing udhcpc daemon so it doesn't fight us over the lease.
    run("pkill -x udhcpc", quiet=True)

    # 3. Flush neighbor cache — old default gateway's MAC is stale.
    run("ip neigh flush all", quiet=True)

    # 4. Request a fresh DHCP lease. -t 5 = try up to 5 times, -n = exit on
    # failure instead of daemonizing indefinitely (we want to know if it
    # didn't work). Alpine's udhcpc default.script rewrites /etc/resolv.conf
    # and sets the default route.
    rc, _ = run(f"udhcpc -i {IFACE} -t 5 -n")
    if rc != 0:
        return False, f"udhcpc failed (rc={rc})"

    # 5. Nudge dnsmasq (used by Pi-hole / ad-blocking path) to reload
    # upstream servers from the new resolv.conf. No-op if not running.
    run("pkill -HUP dnsmasq", quiet=True)

    log("refresh: done")
    return True, None


def send_json(conn, obj):
    try:
        conn.sendall((json.dumps(obj) + "\n").encode())
    except OSError as e:
        log(f"send_json error: {e}")


def handle_message(msg, conn):
    if msg.get("type") == "refresh":
        ok, err = do_refresh()
        resp = {"type": "refresh", "ok": ok}
        if err:
            resp["error"] = err
        send_json(conn, resp)
    else:
        log(f"unknown command type: {msg.get('type')!r}")


def run_session(conn):
    log("host connected")
    buf = b""
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            if len(buf) > 1_048_576:
                log("buffer overflow, closing connection")
                break
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    log(f"invalid JSON: {line!r}")
                    continue
                handle_message(msg, conn)
    except OSError as e:
        log(f"connection error: {e}")
    finally:
        conn.close()
        log("host disconnected")


def main():
    os.makedirs("/tmp/bromure", exist_ok=True)

    while True:
        sock = None
        while True:
            try:
                s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                s.connect((HOST_CID, VSOCK_PORT))
                sock = s
                break
            except (ConnectionRefusedError, ConnectionResetError, OSError):
                time.sleep(0.5)

        log(f"connected to host on vsock port {VSOCK_PORT}")
        run_session(sock)
        # Reconnect loop — host may have restarted the bridge (new session).
        time.sleep(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
