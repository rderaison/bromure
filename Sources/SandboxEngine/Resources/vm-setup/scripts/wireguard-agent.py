#!/usr/bin/python3 -u
"""Bromure WireGuard control agent — runs inside the guest VM.

Listens on vsock port 5701 for JSON commands from the host to
dynamically control a WireGuard tunnel.

Architecture:
  wg-quick manages the wg0 interface.  When the tunnel is up, all
  guest network traffic is routed through it at the kernel level —
  no changes to squid/proxychains are needed.  The existing
  routing-socks.py forwards connections directly (no warp-active flag),
  and WireGuard handles the outbound routing transparently.

  This agent handles:
    1. Boot setup: bring up wg0 if wireguard-auto-connect marker is set
    2. Runtime: toggle the tunnel on enable/disable commands
    3. Monitoring: poll tunnel status every 5s, push changes to host

Protocol: newline-delimited JSON on vsock port 5701.

Commands from host:
  {"type":"status"}
  {"type":"enable"}
  {"type":"disable"}

Responses to host:
  {"type":"status","state":"connected"|"disconnected"|"not_installed"|"error","error":"..."}
  {"type":"enable","ok":true|false,"error":"..."}
  {"type":"disable","ok":true|false,"error":"..."}

Started at boot via inittab (runs as root).
"""

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

VSOCK_PORT = 5701
HOST_CID = 2

WG_INTERFACE = "wg0"
WG_CONFIG = "/etc/wireguard/wg0.conf"
BOOT_SETUP_MARKER = "/tmp/bromure/wireguard-boot-setup"
AUTO_CONNECT_MARKER = "/tmp/bromure/wireguard-auto-connect"

LOG_FILE = "/tmp/bromure/wireguard-agent.log"

# xinitrc gates Chrome on this file when auto-connect was requested.
VPN_STATUS_FILE = "/tmp/bromure/vpn-status"

DNSMASQ_CONF = "/etc/dnsmasq.d/pihole.conf"
DNSMASQ_CONF_BACKUP = "/tmp/bromure/pihole.conf.wg-backup"
RESOLV_CONF = "/etc/resolv.conf"
RESOLV_CONF_BACKUP = "/tmp/bromure/resolv.conf.wg-backup"


def log(msg):
    """Log to stderr and to a file for post-mortem."""
    line = f"wireguard-agent: {msg}"
    print(line, file=sys.stderr)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def write_vpn_status(ok, error=None):
    """Write the auto-connect result atomically so xinitrc can gate Chrome on it."""
    try:
        body = "ok\n" if ok else f"error\n{error or 'Unknown error'}\n"
        tmp = VPN_STATUS_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write(body)
        os.replace(tmp, VPN_STATUS_FILE)
    except OSError as e:
        log(f"write_vpn_status failed: {e}")


def run(cmd, quiet=False):
    """Run a shell command, return (returncode, stdout)."""
    if not quiet:
        log(f"  exec: {cmd}")
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        log(f"  TIMEOUT after 30s: {cmd}")
        return 1, ""
    if not quiet and r.returncode != 0:
        log(f"  rc={r.returncode} stdout={r.stdout.strip()!r} stderr={r.stderr.strip()!r}")
    return r.returncode, r.stdout.strip()


def wg_installed():
    """Check whether wg-quick is available."""
    rc, _ = run("which wg-quick", quiet=True)
    return rc == 0


def wg_up():
    """Check whether the wg0 interface is currently up."""
    rc, _ = run(f"wg show {WG_INTERFACE}", quiet=True)
    return rc == 0


def effective_state():
    """Return the current VPN state as a string."""
    if not wg_installed():
        return "not_installed", None
    if not os.path.isfile(WG_CONFIG):
        return "not_installed", None
    if wg_up():
        return "connected", None
    return "disconnected", None


def sync_clock():
    """Sync system clock from PL031 hardware RTC.

    WireGuard's cryptographic handshake rejects timestamps that are more
    than ~3 minutes off from real time.  Alpine VMs boot with the time
    frozen in the base image — the PL031 RTC (backed by the host's clock)
    must be read into the system clock before bringing up the tunnel.
    """
    run("hwclock --hctosys 2>/dev/null", quiet=True)
    _, ts = run("date '+%Y-%m-%d %H:%M:%S'", quiet=True)
    log(f"clock after hwclock sync: {ts}")


def get_wg_dns():
    """Parse DNS servers from the WireGuard config file.

    Returns a list of DNS server addresses, or an empty list if not specified.
    Example config line: DNS = 10.64.0.1, 10.64.0.2
    """
    try:
        with open(WG_CONFIG) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("DNS"):
                    _, _, val = stripped.partition("=")
                    servers = [s.strip() for s in val.split(",") if s.strip()]
                    return servers
    except OSError:
        pass
    return []


def apply_vpn_dns(dns_servers):
    """Switch DNS to the VPN's own servers to prevent leaks.

    Squid always points to the local dnsmasq (127.0.0.1), so we only need to
    update dnsmasq's upstream server and send it SIGHUP.  dnsmasq handles
    SIGHUP cleanly without dropping existing connections, unlike squid in
    foreground (-N) mode which loses connectivity on reconfiguration.

    /etc/resolv.conf is also updated so the system resolver and wg-quick
    itself use the VPN's DNS for any direct lookups.
    """
    if not dns_servers:
        log("no DNS servers in WireGuard config — skipping DNS update")
        return

    dns_str = ", ".join(dns_servers)

    # Update /etc/resolv.conf (system resolver and wg-quick direct lookups)
    try:
        with open(RESOLV_CONF) as f:
            orig_resolv = f.read()
        with open(RESOLV_CONF_BACKUP, "w") as f:
            f.write(orig_resolv)
        with open(RESOLV_CONF, "w") as f:
            for srv in dns_servers:
                f.write(f"nameserver {srv}\n")
        log(f"resolv.conf → VPN DNS: {dns_str}")
    except OSError as e:
        log(f"apply_vpn_dns: resolv.conf update failed: {e}")

    # Update dnsmasq upstream and SIGHUP (squid always uses dnsmasq)
    try:
        with open(DNSMASQ_CONF) as f:
            original = f.read()
        with open(DNSMASQ_CONF_BACKUP, "w") as f:
            f.write(original)
        new_lines = [l for l in original.splitlines() if not l.startswith("server=")]
        for srv in dns_servers:
            new_lines.append(f"server={srv}")
        with open(DNSMASQ_CONF, "w") as f:
            f.write("\n".join(new_lines) + "\n")
        run("pkill -HUP dnsmasq", quiet=True)
        log(f"dnsmasq upstream → VPN DNS: {dns_str}")
    except OSError as e:
        log(f"apply_vpn_dns: dnsmasq update failed: {e}")


def restore_dns():
    """Restore original DNS config after VPN teardown."""
    if os.path.isfile(RESOLV_CONF_BACKUP):
        try:
            os.replace(RESOLV_CONF_BACKUP, RESOLV_CONF)
            log("resolv.conf restored")
        except OSError as e:
            log(f"restore_dns: resolv.conf restore failed: {e}")

    if os.path.isfile(DNSMASQ_CONF_BACKUP):
        try:
            os.replace(DNSMASQ_CONF_BACKUP, DNSMASQ_CONF)
            run("pkill -HUP dnsmasq", quiet=True)
            log("dnsmasq upstream restored")
        except OSError as e:
            log(f"restore_dns: dnsmasq restore failed: {e}")


def do_enable():
    """Bring up the WireGuard tunnel."""
    if not wg_installed():
        return False, "wg-quick not installed"
    if not os.path.isfile(WG_CONFIG):
        return False, "WireGuard config not found"
    # Tear down first in case of stale state
    run(f"wg-quick down {WG_INTERFACE}", quiet=True)
    # Combine stderr into stdout so the caller sees the full wg-quick output
    rc, out = run(f"wg-quick up {WG_INTERFACE} 2>&1")
    if rc != 0:
        return False, f"wg-quick up failed: {out}"
    # Switch dnsmasq to the VPN's own DNS servers to prevent leaks
    apply_vpn_dns(get_wg_dns())
    return True, None


def do_disable():
    """Tear down the WireGuard tunnel."""
    if not wg_up():
        return True, None  # Already down — not an error
    rc, out = run(f"wg-quick down {WG_INTERFACE}")
    if rc != 0:
        return False, f"wg-quick down failed: {out}"
    restore_dns()
    return True, None


def handle_message(msg, conn):
    """Process a JSON command from the host and send a response."""
    mtype = msg.get("type")

    if mtype == "status":
        state, err = effective_state()
        resp = {"type": "status", "state": state}
        if err:
            resp["error"] = err
        send_json(conn, resp)

    elif mtype == "enable":
        ok, err = do_enable()
        resp = {"type": "enable", "ok": ok}
        if err:
            resp["error"] = err
        send_json(conn, resp)
        # Push updated status
        state, serr = effective_state()
        sresp = {"type": "status", "state": state}
        if serr:
            sresp["error"] = serr
        send_json(conn, sresp)

    elif mtype == "disable":
        ok, err = do_disable()
        resp = {"type": "disable", "ok": ok}
        if err:
            resp["error"] = err
        send_json(conn, resp)
        # Push updated status
        state, serr = effective_state()
        sresp = {"type": "status", "state": state}
        if serr:
            sresp["error"] = serr
        send_json(conn, sresp)

    else:
        log(f"unknown command type: {mtype!r}")


def send_json(conn, obj):
    """Send a JSON object as a newline-terminated line."""
    try:
        line = json.dumps(obj) + "\n"
        conn.sendall(line.encode())
    except OSError as e:
        log(f"send_json error: {e}")


def run_session(conn):
    """Handle one host connection: process commands and poll status."""
    log("host connected")

    # Boot setup: bring up tunnel if auto-connect is requested
    if os.path.isfile(BOOT_SETUP_MARKER):
        os.remove(BOOT_SETUP_MARKER)
        if os.path.isfile(AUTO_CONNECT_MARKER):
            os.remove(AUTO_CONNECT_MARKER)
            # Sync clock before connecting — WireGuard handshake fails if the
            # system time is more than ~3 minutes off real time.  Alpine boots
            # with the time frozen in the base image; hwclock reads the PL031
            # RTC (which has the host's current time) to fix it.
            sync_clock()
            log("auto-connect: bringing up WireGuard tunnel")
            ok, err = do_enable()
            if not ok:
                log(f"auto-connect failed (attempt 1): {err}")
                # Retry up to 2 more times — NTP or a slow RTC read may need
                # a few extra seconds to produce a valid clock.
                for attempt in range(2, 4):
                    log(f"auto-connect: retrying in 5s (attempt {attempt}/3)...")
                    time.sleep(5)
                    sync_clock()
                    ok, err = do_enable()
                    if ok:
                        log(f"auto-connect: succeeded on attempt {attempt}")
                        break
                    log(f"auto-connect failed (attempt {attempt}): {err}")
                if not ok:
                    log("auto-connect: all attempts failed")
            # Signal xinitrc: it's been showing a splash since boot; unblock it.
            write_vpn_status(ok, err)

    # Send initial status
    state, err = effective_state()
    resp = {"type": "status", "state": state}
    if err:
        resp["error"] = err
    send_json(conn, resp)

    # Background status poller: detect external state changes
    last_state = state
    stop_event = threading.Event()

    def poller():
        nonlocal last_state
        while not stop_event.is_set():
            time.sleep(5)
            cur_state, cur_err = effective_state()
            if cur_state != last_state:
                last_state = cur_state
                r = {"type": "status", "state": cur_state}
                if cur_err:
                    r["error"] = cur_err
                send_json(conn, r)

    poll_thread = threading.Thread(target=poller, daemon=True)
    poll_thread.start()

    # Main receive loop
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
        stop_event.set()
        conn.close()
        log("host disconnected")


def main():
    os.makedirs("/tmp/bromure", exist_ok=True)

    # Connect to host on vsock port 5701 (retry until host listener is ready)
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
    log("session ended, exiting")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
