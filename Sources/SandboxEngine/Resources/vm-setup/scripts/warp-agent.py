#!/usr/bin/python3 -u
"""Bromure WARP control agent — runs inside the guest VM.

Listens on vsock port 5700 for JSON commands from the host to
dynamically control Cloudflare WARP routing.

Architecture:
  warp-svc runs continuously on port 40001 (started at boot by config-agent).
  A routing SOCKS5 proxy on port 40000 switches per-connection between
  warp-svc (when /tmp/bromure/warp-active exists) and direct connections
  (when it doesn't).  Enable/disable is instant — just toggling the flag file.

  This agent handles:
    1. Boot setup: register warp-svc, set proxy mode/port, connect VPN
    2. Runtime: toggle the routing flag on enable/disable commands
    3. Monitoring: poll warp-cli status every 5s, push changes to host

Protocol: newline-delimited JSON on vsock port 5700.

Commands from host:
  {"type":"status"}
  {"type":"enable"}
  {"type":"disable"}

Responses to host:
  {"type":"status","state":"connected"|"disconnected"|"connecting"|"not_installed"|"error","error":"..."}
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

VSOCK_PORT = 5700
HOST_CID = 2

WARP_SVC = "/bin/warp-svc"
WARP_CLI = "/bin/warp-cli"
RESOLV_STUB = "/usr/lib/libresolv_stub.so"
WARP_PORT = 40000
WARP_FLAG = "/tmp/bromure/warp-active"

# WARP is a glibc binary on musl Alpine — needs the resolver stub.
# Force C locale so warp-cli output is always English.
WARP_ENV = dict(os.environ, LD_PRELOAD=RESOLV_STUB,
                LANG="C", LC_ALL="C", LANGUAGE="C")

LOG_FILE = "/tmp/bromure/warp-agent.log"

# xinitrc shows a splash until this file appears; it then reads the contents
# to decide whether to launch Chrome or show the error panel.
VPN_STATUS_FILE = "/tmp/bromure/vpn-status"


def log(msg):
    """Log to stderr (visible in inittab output) and to a file for post-mortem."""
    line = f"warp-agent: {msg}"
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


def run(cmd, env=None, quiet=False):
    """Run a shell command, return (returncode, stdout, stderr).

    Logs the command and output unless ``quiet`` is True (used for
    high-frequency polling like pgrep).
    """
    if not quiet:
        log(f"  exec: {cmd}")
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=15, env=env)
    except subprocess.TimeoutExpired:
        log(f"  TIMEOUT after 15s: {cmd}")
        return 1, "", "command timed out"
    if not quiet:
        if r.returncode != 0:
            log(f"  rc={r.returncode} stdout={r.stdout.strip()!r} stderr={r.stderr.strip()!r}")
        else:
            log(f"  rc=0 stdout={r.stdout.strip()!r}")
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def warp_installed():
    """Check whether warp-cli and warp-svc binaries exist."""
    svc = os.path.isfile(WARP_SVC)
    cli = os.path.isfile(WARP_CLI)
    stub = os.path.isfile(RESOLV_STUB)
    log(f"warp_installed: svc={svc} cli={cli} stub={stub}")
    return svc and cli


def warp_svc_running():
    """Check whether warp-svc process is running."""
    rc, out, _ = run("pgrep -f '[w]arp-svc'", quiet=True)
    return rc == 0


def dbus_running():
    """Check whether dbus-daemon is running (required by warp-svc)."""
    rc, _, _ = run("pgrep -x dbus-daemon", quiet=True)
    return rc == 0


def warp_vpn_status():
    """Query warp-cli for VPN connection status.

    Returns the raw VPN state: "connected", "connecting", "disconnected",
    "not_installed", or "error".
    """
    if not warp_installed():
        return "not_installed", "warp-cli/warp-svc not found"

    if not warp_svc_running():
        return "disconnected", None

    rc, out, err = run(f"{WARP_CLI} --accept-tos status", env=WARP_ENV, quiet=True)
    if rc != 0:
        return "error", err or out or "warp-cli status failed"

    lower = out.lower()
    if "connecting" in lower or "happy eyeballs" in lower:
        return "connecting", None
    elif "connected" in lower and "disconnected" not in lower:
        return "connected", None
    elif "disconnected" in lower or "registration missing" in lower:
        return "disconnected", None
    else:
        return "error", out


def warp_routing():
    """Check if WARP routing is active (flag file exists)."""
    return os.path.exists(WARP_FLAG)


def effective_state():
    """Get the user-facing state based on flag file + VPN status.

    Returns (state, error) where state is one of:
      connected    — traffic routes through WARP
      disconnected — traffic goes direct (even if VPN is up)
      connecting   — VPN handshake in progress
      not_installed — WARP binaries missing
      error        — something went wrong
    """
    vpn_state, vpn_error = warp_vpn_status()

    if vpn_state == "not_installed":
        return "not_installed", vpn_error

    if warp_routing():
        # User wants WARP routing — report actual VPN state
        if vpn_state == "connected":
            return "connected", None
        elif vpn_state == "connecting":
            return "connecting", None
        else:
            # Flag exists but VPN isn't connected — safety: remove flag
            # to prevent routing to a dead upstream
            log("VPN lost while routing active, removing flag")
            try:
                os.unlink(WARP_FLAG)
            except OSError:
                pass
            return "error", vpn_error or "VPN connection lost"
    else:
        return "disconnected", None


# ---------------------------------------------------------------------------
# warp-svc lifecycle
# ---------------------------------------------------------------------------

def ensure_warp_svc():
    """Ensure warp-svc is running and configured in proxy mode on :40000."""
    if not warp_installed():
        return False, "warp-cli/warp-svc not found"

    # Ensure dbus is running (warp-svc needs it)
    if not dbus_running():
        log("dbus not running, starting it")
        run("rm -f /run/dbus/dbus.pid", quiet=True)
        run("/usr/bin/dbus-daemon --system")
        time.sleep(0.5)
        if not dbus_running():
            log("WARNING: dbus-daemon failed to start")

    if not warp_svc_running():
        run("rm -f /run/cloudflare-warp/warp-svc.sock", quiet=True)
        log("starting warp-svc...")
        svc_log_path = "/tmp/bromure/warp-svc.log"
        svc_log = open(svc_log_path, "a")
        proc = subprocess.Popen(
            [WARP_SVC],
            env=WARP_ENV,
            stdout=svc_log,
            stderr=svc_log)
        log(f"warp-svc spawned (pid {proc.pid})")

        started = False
        for i in range(30):
            time.sleep(0.3)
            if warp_svc_running():
                log(f"warp-svc ready after {(i+1)*0.3:.1f}s")
                started = True
                break
            ret = proc.poll()
            if ret is not None:
                svc_log.close()
                log(f"warp-svc exited immediately with code {ret}")
                try:
                    with open(svc_log_path) as f:
                        tail = f.read()[-500:]
                    log(f"warp-svc.log tail: {tail}")
                except OSError:
                    pass
                return False, f"warp-svc exited with code {ret}"

        svc_log.close()
        if not started:
            log("warp-svc did not appear after 9s")
            return False, "warp-svc failed to start (timeout)"

        log("waiting 1s for dbus registration...")
        time.sleep(1)

    # Register if needed
    log("checking warp-cli status...")
    rc, out, err = run(f"{WARP_CLI} --accept-tos status", env=WARP_ENV)
    combined = (out + " " + err).lower()

    if "registration" in combined and "missing" in combined:
        log("registration missing, registering...")
        run(f"{WARP_CLI} --accept-tos registration new", env=WARP_ENV)
        time.sleep(1)

    # Always ensure proxy mode (warp-svc defaults to :40000)
    log("setting proxy mode...")
    run(f"{WARP_CLI} --accept-tos mode proxy", env=WARP_ENV)

    return True, None


def ensure_warp_connected():
    """Ensure warp-svc is running, configured, and VPN is connected."""
    ok, err = ensure_warp_svc()
    if not ok:
        return False, err

    vpn_state, _ = warp_vpn_status()
    if vpn_state == "connected":
        return True, None

    log("connecting...")
    rc, out, err = run(f"{WARP_CLI} --accept-tos connect", env=WARP_ENV)
    if rc != 0:
        return False, err or out or "warp-cli connect failed"

    # Poll until connected (may go through "connecting" / happy eyeballs)
    log("waiting for connection...")
    for i in range(30):
        time.sleep(1)
        state, msg = warp_vpn_status()
        log(f"  poll {i+1}: state={state}")
        if state == "connected":
            return True, None
        elif state == "connecting":
            continue
        else:
            return False, msg or "WARP did not connect"

    return False, "WARP connection timed out (30s)"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def do_enable():
    """Enable WARP routing: ensure VPN is connected, then set flag."""
    log("do_enable: starting")

    ok, err = ensure_warp_connected()
    if not ok:
        return False, err

    # Set routing flag — routing-socks.py will forward through WARP
    open(WARP_FLAG, "w").close()
    log("do_enable: success (flag set)")
    return True, None


def do_disable():
    """Disable WARP routing: remove flag. VPN stays connected for fast re-enable."""
    log("do_disable: starting")
    try:
        os.unlink(WARP_FLAG)
    except FileNotFoundError:
        pass
    log("do_disable: success (flag removed)")
    return True, None


def handle_message(msg, sock):
    """Process a JSON command and return a JSON response dict."""
    msg_type = msg.get("type")
    log(f"handling command: {msg_type}")

    if msg_type == "status":
        state, error = effective_state()
        resp = {"type": "status", "state": state}
        if error:
            resp["error"] = error
        log(f"status result: {resp}")
        return resp

    elif msg_type == "enable":
        # Notify host that we're connecting before blocking
        send_json(sock, {"type": "status", "state": "connecting"})
        ok, error = do_enable()
        resp = {"type": "enable", "ok": ok}
        if error:
            resp["error"] = error
        log(f"enable result: {resp}")
        return resp

    elif msg_type == "disable":
        ok, error = do_disable()
        resp = {"type": "disable", "ok": ok}
        if error:
            resp["error"] = error
        log(f"disable result: {resp}")
        return resp

    return {"type": "error", "error": f"unknown command: {msg_type}"}


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

_send_lock = threading.Lock()


def send_json(sock, obj):
    """Send a newline-delimited JSON message (thread-safe)."""
    data = json.dumps(obj, separators=(",", ":")).encode() + b"\n"
    with _send_lock:
        sock.sendall(data)


def status_poller(sock, stop_event):
    """Background thread: poll WARP status every 5s and push changes to host."""
    last_state = None
    last_error = None
    while not stop_event.wait(5):
        state, error = effective_state()
        if state != last_state or error != last_error:
            last_state = state
            last_error = error
            resp = {"type": "status", "state": state}
            if error:
                resp["error"] = error
            try:
                send_json(sock, resp)
                log(f"status poll: pushed {state}")
            except (OSError, BrokenPipeError):
                break


MAX_BUF = 1_048_576  # 1 MB — cap receive buffer to prevent memory exhaustion


def run_session():
    """Connect to the host, handle commands, return on disconnect."""
    # Connect to host (retry until host listener is ready)
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            break
        except (ConnectionRefusedError, ConnectionResetError, OSError):
            s.close()
            time.sleep(0.5)

    log("connected to host")

    # -----------------------------------------------------------------------
    # Boot setup: config-agent started warp-svc and wrote a marker.
    # We finish configuration (register, mode, port) and connect the VPN.
    # -----------------------------------------------------------------------
    boot_marker = "/tmp/bromure/warp-boot-setup"
    auto_marker = "/tmp/bromure/warp-auto-connect"

    if os.path.exists(boot_marker):
        log("boot setup marker found, configuring warp-svc...")
        try:
            os.unlink(boot_marker)
        except OSError:
            pass

        auto_connect_requested = os.path.exists(auto_marker)

        send_json(s, {"type": "status", "state": "connecting"})

        ok, err = ensure_warp_connected()
        if ok:
            if auto_connect_requested:
                # Auto-connect: enable routing immediately
                try:
                    os.unlink(auto_marker)
                except OSError:
                    pass
                open(WARP_FLAG, "w").close()
                send_json(s, {"type": "status", "state": "connected"})
                write_vpn_status(True)
                log("boot: VPN connected, routing enabled (auto-connect)")
            else:
                send_json(s, {"type": "status", "state": "disconnected"})
                log("boot: VPN connected, routing disabled (toggle to enable)")
        else:
            send_json(s, {"type": "status", "state": "error", "error": err})
            log(f"boot: VPN setup failed: {err}")
            if auto_connect_requested:
                write_vpn_status(False, err)
    elif os.path.exists(auto_marker):
        # Legacy path: auto-connect marker without boot-setup
        log("auto-connect marker found (legacy path)")
        try:
            os.unlink(auto_marker)
        except OSError:
            pass
        send_json(s, {"type": "status", "state": "connecting"})
        ok, error = do_enable()
        if ok:
            send_json(s, {"type": "status", "state": "connected"})
            write_vpn_status(True)
            log("auto-connect succeeded")
        else:
            send_json(s, {"type": "status", "state": "error", "error": error})
            write_vpn_status(False, error)
            log(f"auto-connect failed: {error}")

    # Start background status poller
    stop_event = threading.Event()
    poller = threading.Thread(target=status_poller, args=(s, stop_event), daemon=True)
    poller.start()

    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
            if not chunk:
                log("host disconnected")
                break
            buf += chunk

            # Cap buffer to prevent memory exhaustion
            if len(buf) > MAX_BUF:
                log("receive buffer overflow, disconnecting")
                break

            # Process complete newline-delimited messages
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    log(f"invalid JSON: {line!r}")
                    continue

                resp = handle_message(msg, s)
                send_json(s, resp)

        except (ConnectionError, OSError) as e:
            log(f"connection error: {e}")
            break

    stop_event.set()
    s.close()


def main():
    os.makedirs("/tmp/bromure", exist_ok=True)
    log(f"starting (pid={os.getpid()}, uid={os.getuid()}, euid={os.geteuid()})")

    while True:
        run_session()
        log("reconnecting in 1s...")
        time.sleep(1)


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    main()
