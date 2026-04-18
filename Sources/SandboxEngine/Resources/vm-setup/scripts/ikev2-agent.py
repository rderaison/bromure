#!/usr/bin/python3 -u
"""Bromure IKEv2/IPsec control agent — runs inside the guest VM.

Listens on vsock port 5702 for JSON commands from the host to
dynamically control an IKEv2 tunnel via strongSwan (swanctl).

Protocol: newline-delimited JSON on vsock port 5702.

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

VSOCK_PORT = 5702
HOST_CID = 2

SWANCTL_CONF = "/etc/swanctl/conf.d/bromure.conf"
BOOT_SETUP_MARKER = "/tmp/bromure/ikev2-boot-setup"
AUTO_CONNECT_MARKER = "/tmp/bromure/ikev2-auto-connect"
LOG_FILE = "/tmp/bromure/ikev2-agent.log"
CHILD_SA = "bromure-child"

# xinitrc gates Chrome on this file when auto-connect was requested.
VPN_STATUS_FILE = "/tmp/bromure/vpn-status"


def log(msg):
    line = f"ikev2-agent: {msg}"
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


def ipsec_installed():
    rc, _ = run("which swanctl", quiet=True)
    return rc == 0


def is_connected():
    """Check if the IKEv2 SA is established."""
    rc, out = run("swanctl --list-sas 2>/dev/null", quiet=True)
    if rc != 0:
        return False
    return "ESTABLISHED" in out


def charon_running():
    rc, _ = run("pgrep -f charon", quiet=True)
    return rc == 0


def effective_state():
    if not ipsec_installed():
        return "not_installed", None
    if not os.path.isfile(SWANCTL_CONF):
        return "not_installed", None
    if not charon_running():
        return "disconnected", None
    if is_connected():
        return "connected", None
    return "disconnected", None


def sync_clock():
    run("hwclock --hctosys 2>/dev/null", quiet=True)
    _, ts = run("date '+%Y-%m-%d %H:%M:%S'", quiet=True)
    log(f"clock after hwclock sync: {ts}")


def do_enable():
    if not ipsec_installed():
        return False, "strongSwan not installed"
    if not os.path.isfile(SWANCTL_CONF):
        return False, "IKEv2 config not found"

    # Start charon if not running (or socket is gone)
    if not charon_running() or not os.path.exists("/var/run/charon.vici"):
        # Kill any leftover charon before restarting
        if charon_running():
            run("ipsec stop 2>&1", quiet=True)
            for _ in range(20):
                if not charon_running():
                    break
                time.sleep(0.5)
        # Remove stale socket so the wait loop below detects the fresh one
        try:
            os.unlink("/var/run/charon.vici")
        except FileNotFoundError:
            pass
        rc, out = run("ipsec start 2>&1")
        if rc != 0:
            return False, f"ipsec start failed: {out}"
        # Wait for charon's VICI socket to be ready
        for _ in range(20):
            if os.path.exists("/var/run/charon.vici"):
                break
            time.sleep(0.5)
        else:
            return False, "charon did not start"

    # Load configuration
    rc, out = run("swanctl --load-all 2>&1")
    if rc != 0:
        return False, f"swanctl --load-all failed: {out}"

    # Initiate the connection
    rc, out = run(f"swanctl --initiate --child {CHILD_SA} 2>&1")
    if rc != 0:
        return False, parse_swanctl_error(out)

    return True, None


def parse_swanctl_error(output):
    """Extract a user-friendly error from swanctl/charon log output."""
    # Read charon log for detailed errors
    charon_log = ""
    try:
        _, charon_log = run("cat /var/log/charon.log 2>/dev/null | tail -30", quiet=True)
    except Exception:
        pass
    combined = output + "\n" + charon_log

    if "no trusted" in combined or "issuer certificate" in combined:
        # Extract the issuer name if available
        for line in combined.splitlines():
            if "issuer is" in line:
                issuer = line.split("issuer is")[-1].strip().strip('"').strip("'")
                return f"Server certificate not trusted (unknown CA: {issuer}). Add the CA certificate in the profile's Enterprise tab."
        return "Server certificate not trusted. Add the server's CA certificate in the profile's Enterprise tab."
    if "AUTH_FAILED" in combined or "authentication failed" in combined.lower():
        return "Authentication failed. Check your username/password or pre-shared key."
    if "NO_PROPOSAL_CHOSEN" in combined:
        return "No compatible cipher suite. The server rejected all proposed encryption algorithms."
    if "AUTHENTICATION_FAILED" in combined:
        return "Authentication rejected by the server."
    if "timed out" in combined.lower() or "TIMEOUT" in combined:
        return "Connection timed out. Check the server address and network connectivity."
    if "resolving" in combined.lower() or "DNS" in combined:
        return "Cannot resolve server address. Check the hostname and DNS settings."
    if "connection refused" in combined.lower():
        return "Connection refused by server."
    return f"Connection failed: {output[:200]}"


def do_disable():
    if not charon_running():
        return True, None

    # Terminate all SAs
    run("swanctl --terminate --ike bromure-vpn 2>&1", quiet=True)
    # Stop charon
    run("ipsec stop 2>&1", quiet=True)
    # Wait for charon to fully exit so a subsequent enable doesn't race
    for _ in range(20):
        if not charon_running():
            break
        time.sleep(0.5)

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

    # Boot setup
    if os.path.isfile(BOOT_SETUP_MARKER):
        os.remove(BOOT_SETUP_MARKER)
        if os.path.isfile(AUTO_CONNECT_MARKER):
            os.remove(AUTO_CONNECT_MARKER)
            sync_clock()
            log("auto-connect: bringing up IKEv2 tunnel")
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

    # Background status poller
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
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    log(f"bad JSON: {line!r}")
                    continue
                handle_message(msg, conn)
    except OSError as e:
        log(f"recv error: {e}")
    finally:
        stop_event.set()
        log("host disconnected")


def main():
    log("starting")

    # Wait for config-agent to signal whether IKEv2 is configured.
    # The agent starts at boot before config-agent has run, so we poll
    # for the boot marker or swanctl conf.  If neither appears after 60s,
    # this session doesn't use IKEv2 — sleep forever instead of exiting
    # (exiting causes the resilient-launch wrapper to log CRASHED spam).
    if not os.path.isfile(BOOT_SETUP_MARKER) and not os.path.isfile(SWANCTL_CONF):
        log("waiting for config-agent...")
        for _ in range(60):
            if os.path.isfile(BOOT_SETUP_MARKER) or os.path.isfile(SWANCTL_CONF):
                break
            time.sleep(1)
        else:
            log("no IKEv2 config — sleeping")
            signal.pause()

    # Wait for config-agent to finish writing the swanctl config
    for _ in range(120):
        if os.path.isfile(SWANCTL_CONF):
            break
        time.sleep(1)
    else:
        log("timed out waiting for swanctl config")
        signal.pause()

    # Connect to host vsock
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
