#!/usr/bin/python3 -u
"""Bromure OpenVPN control agent — runs inside the guest VM.

Listens on vsock port 5704 for JSON commands from the host to
dynamically control an OpenVPN tunnel.

Architecture:
  The openvpn client manages the tun0 interface.  Full-tunnel .ovpn
  configs (`redirect-gateway`) route all guest traffic through it at the
  kernel level — no changes to squid/proxychains are needed.  DNS servers
  the server pushes (`dhcp-option DNS`) are applied to dnsmasq so lookups
  don't leak outside the tunnel.

  This agent handles:
    1. Boot setup: bring up the tunnel if openvpn-auto-connect marker is set
    2. Runtime: toggle the tunnel on enable/disable commands
    3. Monitoring: poll tunnel status every 5s, push changes to host

Protocol: newline-delimited JSON on vsock port 5704.

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
import re
import signal
import socket
import subprocess
import sys
import threading
import time

VSOCK_PORT = 5704
HOST_CID = 2

OVPN_CONFIG = "/etc/openvpn/bromure.conf"
OVPN_PIDFILE = "/run/openvpn-bromure.pid"
OVPN_LOG = "/tmp/bromure/openvpn-client.log"
TUN_INTERFACE = "tun0"

BOOT_SETUP_MARKER = "/tmp/bromure/openvpn-boot-setup"
AUTO_CONNECT_MARKER = "/tmp/bromure/openvpn-auto-connect"
LOG_FILE = "/tmp/bromure/openvpn-agent.log"

# xinitrc gates Chrome on this file when auto-connect was requested.
VPN_STATUS_FILE = "/tmp/bromure/vpn-status"

DNSMASQ_CONF = "/etc/dnsmasq.d/pihole.conf"
DNSMASQ_CONF_BACKUP = "/tmp/bromure/pihole.conf.ovpn-backup"
RESOLV_CONF = "/etc/resolv.conf"
RESOLV_CONF_BACKUP = "/tmp/bromure/resolv.conf.ovpn-backup"

# How long to wait for "Initialization Sequence Completed" after launch.
CONNECT_TIMEOUT_S = 40


def log(msg):
    line = f"openvpn-agent: {msg}"
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


def openvpn_installed():
    rc, _ = run("which openvpn", quiet=True)
    return rc == 0


def ensure_tun():
    """OpenVPN needs the tun module and /dev/net/tun. Nothing else in the
    guest pulls them in (WireGuard uses its own module, IPsec uses XFRM),
    so load/create them on demand. No-op when tun is built into the kernel
    and udev already made the node."""
    run("modprobe tun 2>/dev/null", quiet=True)
    if not os.path.exists("/dev/net/tun"):
        run("mkdir -p /dev/net && mknod /dev/net/tun c 10 200 "
            "&& chmod 600 /dev/net/tun", quiet=True)


def tunnel_up():
    """tun0 exists and the openvpn process is alive."""
    rc, _ = run(f"ip link show {TUN_INTERFACE}", quiet=True)
    return rc == 0 and openvpn_running()


def openvpn_running():
    rc, _ = run("pgrep -f /etc/openvpn/bromure.conf", quiet=True)
    return rc == 0


def effective_state():
    if not openvpn_installed():
        return "not_installed", None
    if not os.path.isfile(OVPN_CONFIG):
        return "not_installed", None
    if tunnel_up():
        return "connected", None
    return "disconnected", None


def sync_clock():
    """Sync system clock from the PL031 RTC. TLS cert validation (and thus
    the OpenVPN handshake) fails when the Alpine image's frozen clock is
    far from real time."""
    run("hwclock --hctosys 2>/dev/null", quiet=True)
    _, ts = run("date '+%Y-%m-%d %H:%M:%S'", quiet=True)
    log(f"clock after hwclock sync: {ts}")


def pushed_dns_servers():
    """Parse `dhcp-option DNS x.x.x.x` lines the server pushed, from the
    client log. Returns a list of DNS server addresses (may be empty)."""
    servers = []
    try:
        with open(OVPN_LOG) as f:
            text = f.read()
    except OSError:
        return servers
    for m in re.finditer(r"dhcp-option\s+DNS\s+([0-9a-fA-F:.]+)", text):
        ip = m.group(1)
        if ip not in servers:
            servers.append(ip)
    return servers


def apply_vpn_dns(dns_servers):
    """Switch DNS to the VPN's own servers to prevent leaks. Mirrors the
    WireGuard agent: squid always resolves via the local dnsmasq, so we
    only repoint dnsmasq's upstream (SIGHUP) and update resolv.conf."""
    if not dns_servers:
        log("no pushed DNS servers — leaving resolver unchanged")
        return

    dns_str = ", ".join(dns_servers)

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


def parse_openvpn_error():
    """Extract a user-friendly error from the openvpn client log."""
    try:
        with open(OVPN_LOG) as f:
            log_tail = f.read()[-4000:]
    except OSError:
        log_tail = ""

    low = log_tail.lower()
    if "auth_failed" in low or "authenticate/decrypt packet error" in low:
        return "Authentication failed. Check your username/password or certificate."
    if "certificate verify failed" in low or "verify error" in low or "ca md too weak" in low:
        return "Server certificate not trusted. Add the server's CA in the profile's Enterprise tab."
    if "tls handshake failed" in low or "tls error" in low:
        return "TLS handshake failed. Check the server address, port, and protocol."
    if "cannot resolve host" in low or "resolve: could not" in low:
        return "Cannot resolve server address. Check the hostname and DNS settings."
    if "connection refused" in low:
        return "Connection refused by server. Check the port and protocol (udp/tcp)."
    if "connection timed out" in low or "tls key negotiation failed" in low:
        return "Connection timed out. Check the server address and network connectivity."
    # Surface the last non-empty log line as a fallback.
    for line in reversed(log_tail.splitlines()):
        if line.strip():
            return f"Connection failed: {line.strip()[:200]}"
    return "Connection failed."


def do_enable():
    """Bring up the OpenVPN tunnel."""
    if not openvpn_installed():
        return False, "openvpn not installed"
    if not os.path.isfile(OVPN_CONFIG):
        return False, "OpenVPN config not found"

    ensure_tun()

    # Tear down any stale client first.
    do_disable_quiet()

    # Truncate the log so we only parse this attempt's output.
    try:
        open(OVPN_LOG, "w").close()
    except OSError:
        pass

    rc, out = run(
        "openvpn --config %s --daemon openvpn-bromure --writepid %s "
        "--log %s --verb 3" % (OVPN_CONFIG, OVPN_PIDFILE, OVPN_LOG)
    )
    if rc != 0:
        return False, f"openvpn launch failed: {out}"

    # Wait for the client to finish initialising (or fail).
    deadline = time.time() + CONNECT_TIMEOUT_S
    while time.time() < deadline:
        if not openvpn_running():
            return False, parse_openvpn_error()
        try:
            with open(OVPN_LOG) as f:
                body = f.read()
        except OSError:
            body = ""
        if "Initialization Sequence Completed" in body:
            apply_vpn_dns(pushed_dns_servers())
            return True, None
        if "AUTH_FAILED" in body or "Exiting due to fatal error" in body:
            do_disable_quiet()
            return False, parse_openvpn_error()
        time.sleep(1)

    do_disable_quiet()
    return False, "Connection timed out. Check the server address and network connectivity."


def do_disable_quiet():
    """Kill the openvpn client without touching DNS — used internally."""
    run("pkill -TERM -f /etc/openvpn/bromure.conf", quiet=True)
    for _ in range(20):
        if not openvpn_running():
            break
        time.sleep(0.5)
    else:
        run("pkill -KILL -f /etc/openvpn/bromure.conf", quiet=True)
    try:
        os.unlink(OVPN_PIDFILE)
    except FileNotFoundError:
        pass


def do_disable():
    """Tear down the OpenVPN tunnel."""
    if not openvpn_running():
        return True, None  # Already down — not an error
    do_disable_quiet()
    restore_dns()
    return True, None


def handle_message(msg, conn):
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
        state, serr = effective_state()
        sresp = {"type": "status", "state": state}
        if serr:
            sresp["error"] = serr
        send_json(conn, sresp)

    else:
        log(f"unknown command type: {mtype!r}")


def send_json(conn, obj):
    try:
        line = json.dumps(obj) + "\n"
        conn.sendall(line.encode())
    except OSError as e:
        log(f"send_json error: {e}")


def run_session(conn):
    log("host connected")

    # Boot setup: bring up tunnel if auto-connect is requested
    if os.path.isfile(BOOT_SETUP_MARKER):
        os.remove(BOOT_SETUP_MARKER)
        if os.path.isfile(AUTO_CONNECT_MARKER):
            os.remove(AUTO_CONNECT_MARKER)
            sync_clock()
            log("auto-connect: bringing up OpenVPN tunnel")
            ok, err = do_enable()
            if not ok:
                log(f"auto-connect failed (attempt 1): {err}")
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
    log("starting")

    # This agent starts at boot before config-agent has written the config.
    # If no OpenVPN profile is configured, sleep forever instead of exiting
    # (exiting spams the resilient-launch CRASHED log).
    if not os.path.isfile(BOOT_SETUP_MARKER) and not os.path.isfile(OVPN_CONFIG):
        log("waiting for config-agent...")
        for _ in range(60):
            if os.path.isfile(BOOT_SETUP_MARKER) or os.path.isfile(OVPN_CONFIG):
                break
            time.sleep(1)
        else:
            log("no OpenVPN config — sleeping")
            signal.pause()

    # Connect to host on vsock (retry until the host listener is ready)
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            run_session(s)
        except OSError as e:
            log(f"vsock connect error: {e}")
        finally:
            try:
                s.close()
            except Exception:
                pass
        time.sleep(2)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
