#!/usr/bin/python3 -u
"""Bromure AC consolidated headless daemon — runs inside the guest VM.

This ONE python3 process replaces the entire X11 session that used to be
started by the host-generated ~/.xinitrc + ~/.bromure-tab-agent.sh. There is
no X server, no openbox, no kitty and no spice-vdagent any more: the terminal
is headless (tmux only) and the host attaches to it over the shell-agent's
vsock pty channel. bromure-agentd runs as user `ubuntu` under a systemd unit
with Restart=always, started after /mnt/bromure-meta (virtiofs, host-writable)
mounts.

Design
------
* Every long-lived job is a *service*: a callable run inside a supervised
  daemon thread. If a service raises, the supervisor logs it and restarts it
  with a 1s→5s capped backoff. One crashing thread never kills the process.
* Signal handlers are installed ONCE, on the main thread, in main() — never
  inside a service (signal.signal only works on the main thread).
* One-shot startup tasks (MTU, CA install, docker proxy, timezone, …) run
  once, each wrapped in try/except so a failure is non-fatal.
* Logging goes to stderr AND (best-effort) /mnt/bromure-outbox/agentd.log via
  a single lock-guarded helper, tagged with a per-service name.
* Hot upgrade: main() hashes its own source at startup; a watcher thread
  re-hashes the staged copy on mtime change and os._exit(0) (systemd
  respawns) when it differs. The shell-agent request protocol also carries an
  optional "agentVersion"; a mismatch exits after the request completes.

Wire protocols, vsock ports, file paths and retry/pool patterns are preserved
byte-for-byte from the five agents this daemon absorbs (shell-agent.py,
bromure-vm-bridge.py, claude-token-agent.py, codex-token-agent.py,
loopback-relay-agent.py). The tab engine is a behaviour-exact port of
Profile.swift's tabAgentContent (roster_loop, command_loop, worktree helpers,
session lifecycle + reboot detection). The macOS host parses tabs.txt and the
outbox markers, so their formats must not drift.

Section index
-------------
  §0  Imports & constants
  §1  Logging + service supervisor
  §2  Self-hash / hot-upgrade support
  §3  shell-agent   (vsock 5800 guest-initiated pool; exec + pty + views)
  §4  vm-bridge     (127.0.0.1:8080 + unix sockets → host vsock MITM)
  §5  claude-token  (vsock 8446, ~/.claude/.credentials.json)
  §6  codex-token   (vsock 8447, ~/.codex/auth.json)
  §7  loopback-relay(vsock 5010, OAuth callback relay)
  §8  Tab engine    (tmux session, roster_loop, command_loop, worktrees)
  §9  Session tasks (MTU, CA, resume-watcher, docker, binfmt, tz, ip, shares)
  §10 main()        (env, one-shot tasks, thread launch, supervise)
"""

# ─────────────────────────────── §0 Imports & constants ────────────────────
import base64
import errno
import fcntl
import glob
import hashlib
import ipaddress
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import traceback

HOST_CID = 2  # well-known CID for the macOS host under VZ

# vsock ports (unchanged from the absorbed agents)
SHELL_VSOCK_PORT = 5800
HTTP_PROXY_VSOCK_PORT = 8443
SSH_AGENT_VSOCK_PORT = 8444
AWS_CREDS_VSOCK_PORT = 8445
LLM_ENGINE_VSOCK_PORT = 8446
CLAUDE_TOKEN_PORT = 8446
CODEX_TOKEN_PORT = 8447
LOOPBACK_VSOCK_PORT = 5010

# local listeners bridged to the host
HTTP_PROXY_TCP_PORT = 8080
SSH_AGENT_UNIX_PATH = "/tmp/bromure-agent.sock"
AWS_CREDS_UNIX_PATH = "/tmp/bromure-aws-creds.sock"
LLM_ENGINE_TCP_PORT = 11434

# shell-agent pool
POOL_SIZE = 4
MAX_REQUEST_SIZE = 10 * 1024 * 1024  # 10 MB

# paths
META = "/mnt/bromure-meta"
OUTBOX = "/mnt/bromure-outbox"
AGENTD_LOG = os.path.join(OUTBOX, "agentd.log")
TMUX_S = "bromure"
# New shells (the initial window + plain new-tab) open here. Without an
# explicit -c, tmux windows inherit the server's start directory, which
# under systemd is "/" — so pin it to the user's home.
HOME = os.path.expanduser("~")

# token-agent validators
ACCESS_FAKE_PREFIX = "sk-ant-oat01-brm-"
REFRESH_FAKE_PREFIX = "sk-ant-ort01-brm-"
JWT_SIG_FAKE_MARKER = "brm-cdX-sig"
REFRESH_FAKE_MARKER = "brm-cdX-rfs"

CLAUDE_CREDS_PATH = os.path.expanduser("~/.claude/.credentials.json")
CODEX_CREDS_PATH = os.path.expanduser("~/.codex/auth.json")

# loopback-relay
MAX_PORT_HEADER = 16

# hot-upgrade
UPGRADE_POLL_SECONDS = 3.0

# ASCII Unit Separator (0x1f) — the worktree-registry + roster read delimiter.
US = "\x1f"


# ─────────────────────── §1 Logging + service supervisor ───────────────────
_LOG_LOCK = threading.Lock()
# Set true once we are shutting down (SIGTERM/SIGINT), so services stop looping.
_RUNNING = threading.Event()
_RUNNING.set()


def log(tag, *parts):
    """Unified logger: timestamp + service tag to stderr AND the outbox log.

    Best-effort on the file (the outbox is a virtiofs mount that may not be
    ready or may be read-only); stderr always gets it (journald captures it
    for the systemd unit).
    """
    msg = " ".join(str(p) for p in parts)
    line = "%s [%s] %s" % (time.strftime("%H:%M:%S"), tag, msg)
    with _LOG_LOCK:
        try:
            print(line, file=sys.stderr, flush=True)
        except Exception:
            pass
        try:
            with open(AGENTD_LOG, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass


def supervise(name, target, backoff_start=1.0, backoff_max=5.0):
    """Run `target` forever, restarting it on crash with capped backoff.

    Each service body is expected to loop internally; if it returns or raises
    we treat that as a crash and restart (after backoff on a raise, promptly on
    a clean return). The backoff resets after a service survives >30s, so a
    service that crashes once then runs fine doesn't stay penalised.
    """
    backoff = backoff_start
    while _RUNNING.is_set():
        started = time.time()
        try:
            target()
            # Clean return: services are meant to loop forever, so a return is
            # unexpected but not an error — restart promptly.
            log(name, "service returned; restarting")
            backoff = backoff_start
        except Exception:
            uptime = time.time() - started
            log(name, "crashed:\n" + traceback.format_exc())
            if uptime > 30:
                backoff = backoff_start
            time.sleep(backoff)
            backoff = min(backoff * 2, backoff_max)
            continue
        if not _RUNNING.is_set():
            break
        time.sleep(backoff_start)


def start_service(name, target):
    """Spawn a supervised daemon thread for a service body."""
    t = threading.Thread(
        target=supervise, args=(name, target), name=name, daemon=True)
    t.start()
    return t


# ─────────────────────── §2 Self-hash / hot-upgrade support ─────────────────
def _sha256_of_file(path):
    """Full sha256 hex of a file, or None if unreadable."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


# The daemon's own source hash, computed once in main(). A module-level default
# keeps the value defined for the import-smoke test (which never calls main()).
SELF_HASH = None


def compute_self_hash():
    """Hash this file's own source (`__file__`). Stored in SELF_HASH."""
    global SELF_HASH
    SELF_HASH = _sha256_of_file(os.path.abspath(__file__))
    return SELF_HASH


def upgrade_watcher():
    """Stat the staged source every 3s; on mtime change, rehash and, if the
    content differs from the running hash, log "upgrade: <old8>→<new8>" and
    os._exit(0) so systemd (Restart=always) respawns from the new source.

    The staged path is this very file (__file__); the host overwrites it in
    place on the meta share / home when a new agentd ships.
    """
    path = os.path.abspath(__file__)
    try:
        last_mtime = os.stat(path).st_mtime
    except OSError:
        last_mtime = None
    while _RUNNING.is_set():
        time.sleep(UPGRADE_POLL_SECONDS)
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        if mtime == last_mtime:
            continue
        last_mtime = mtime
        new_hash = _sha256_of_file(path)
        if new_hash and SELF_HASH and new_hash != SELF_HASH:
            log("upgrade", "upgrade: %s→%s" % (SELF_HASH[:8], new_hash[:8]))
            os._exit(0)


# ─────────────────── §3 shell-agent (vsock 5800, guest-initiated pool) ──────
# Provides remote shell execution from the host over vsock port 5800.
# Length-prefixed JSON protocol:
#   Request:  [u32be len][{"cmd": "...", "timeout": 30}]
#   Response: [u32be len][{"stdout": "...", "stderr": "...", "exit_code": 0}]
# Interactive requests ({"interactive": true, "cols": N, "rows": N}) switch the
# connection to the framed pty protocol. Two flavors:
#   - {"cmd": "..."} — run the command (or a login shell) on a fresh pty.
#   - {"view": "<id>", "window": <idx>} — host terminal view: attach a tmux
#     session *grouped* with `bromure` so N host views can show N windows.
#
# Guest-initiated connection pool: open N vsock connections proactively; when
# the host sends a command, execute it; after each command open a replacement.
#
# Optional protocol extension: a request may carry "agentVersion"; if present
# and != this daemon's self-hash, the request is served normally and then the
# process exits(0) so systemd respawns from the (already-staged) new source.

# Interactive PTY framing (both directions):
#   [1 byte type][4 byte BE length][payload]
#   type 0 = data (raw tty bytes), 1 = resize (payload: u16be cols, u16be rows),
#   2 = exit (guest→host; payload: i32be exit code), 3 = stdin EOF (host→guest).
FRAME_DATA = 0
FRAME_RESIZE = 1
FRAME_EXIT = 2
FRAME_EOF = 3


def _recv_exact(sock, n):
    """Read exactly n bytes from socket."""
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def _send_frame(sock, ftype, payload=b""):
    sock.sendall(bytes([ftype]) + struct.pack(">I", len(payload)) + payload)


def _set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def _view_attach_command(view, window):
    """Build the tmux attach command for a host terminal view.

    Each view gets its own session *grouped* with `bromure` (shared windows,
    independent current-window) — two clients on the same session would mirror
    one active window, which is exactly what a grid must not do.
    destroy-unattached reaps the view session when the host detaches; the
    grouped windows (the real tabs) are untouched. status goes off because the
    host draws its own chrome; allow-passthrough lets kitty-graphics escape
    tmux for hosts that render it.
    """
    name = "view-" + re.sub(r"[^A-Za-z0-9-]", "", str(view))[:32]
    if name == "view-":
        name = "view-" + os.urandom(4).hex()
    tmux = (
        "exec tmux"
        " set-option -g allow-passthrough on \\;"
        # set-clipboard on is safe now that tmux mouse is off (no tmux-side
        # copy happens on selection) — it just lets a program's own OSC 52
        # copy reach the macOS clipboard.
        " set-option -s set-clipboard on \\;"
        " set-window-option -g aggressive-resize on \\;"
        " new-session -t bromure -s " + name + " \\;"
        " set-option destroy-unattached on \\;"
        " set-option status off \\;"
        # mouse OFF: tmux does not capture the mouse, so a plain drag is
        # ghostty's own native selection (macOS-like — select never copies,
        # ⌘C copies). The wheel scrolls tmux history through the user-keys
        # bridge bound in create_session (the client pins the surface to the
        # alternate screen, so there is no host-side scrollback to scroll).
        # tmux still forwards mouse events to apps that request them
        # (Claude/vim), so TUI clicks keep working.
        " set-option mouse off"
    )
    if window is not None:
        try:
            tmux += " \\; select-window -t :%d" % int(window)
        except (TypeError, ValueError):
            pass
    # The bromure session normally exists (the boot terminal creates it); cover
    # the race/headless case so the view never lands on an error.
    return (
        "tmux has-session -t bromure 2>/dev/null"
        " || tmux new-session -d -s bromure; " + tmux
    )


def _run_interactive(vsock_sock, req):
    """Allocate a pty, run the command on it, and bridge it to the vsock."""
    cmd = req.get("cmd", "")
    if req.get("view"):
        cmd = _view_attach_command(req["view"], req.get("window"))
    cols = int(req.get("cols", 80) or 80)
    rows = int(req.get("rows", 24) or 24)

    pid, master = pty.fork()
    if pid == 0:
        # Child: stdin/stdout/stderr are the pty slave. Source proxy.env so
        # curl/pip/npm see the MITM proxy, then exec the command (or a login
        # shell). `bash -li` makes the default shell interactive so .bashrc
        # runs; `-lc` runs an explicit command with the login environment.
        try:
            os.environ.setdefault("TERM", "xterm-256color")
            if cmd:
                # NB: no `exec` prefix — it would replace the shell with the
                # first word of a compound command (`a; b; c`) and drop the rest.
                wrapped = (
                    "if [ -r /mnt/bromure-meta/proxy.env ]; then "
                    "set -a; . /mnt/bromure-meta/proxy.env; set +a; fi; " + cmd
                )
                os.execvp("/bin/bash", ["/bin/bash", "-lc", wrapped])
            else:
                os.execvp("/bin/bash", ["/bin/bash", "-li"])
        except Exception:
            pass
        os._exit(127)

    # Parent: pump pty master <-> vsock until the child exits or the host hangs up.
    _set_winsize(master, rows, cols)
    buf = b""
    try:
        while True:
            try:
                rlist, _, _ = select.select([vsock_sock, master], [], [])
            except (OSError, ValueError):
                break
            if master in rlist:
                try:
                    out = os.read(master, 65536)
                except OSError:
                    out = b""
                if not out:
                    break  # child closed the pty (exited)
                _send_frame(vsock_sock, FRAME_DATA, out)
            if vsock_sock in rlist:
                try:
                    chunk = vsock_sock.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    break  # host hung up
                buf += chunk
                while len(buf) >= 5:
                    ftype = buf[0]
                    flen = struct.unpack(">I", buf[1:5])[0]
                    if len(buf) < 5 + flen:
                        break
                    payload = buf[5:5 + flen]
                    buf = buf[5 + flen:]
                    if ftype == FRAME_DATA:
                        try:
                            os.write(master, payload)
                        except OSError:
                            pass
                    elif ftype == FRAME_RESIZE and flen >= 4:
                        c, r = struct.unpack(">HH", payload[:4])
                        _set_winsize(master, r, c)
                    elif ftype == FRAME_EOF:
                        break
    finally:
        try:
            os.close(master)
        except OSError:
            pass
        code = 0
        try:
            os.kill(pid, signal.SIGHUP)
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
            if hasattr(os, "waitstatus_to_exitcode"):
                code = os.waitstatus_to_exitcode(status)
            elif os.WIFEXITED(status):
                code = os.WEXITSTATUS(status)
            else:
                code = -1
        except OSError:
            pass
        try:
            _send_frame(vsock_sock, FRAME_EXIT, struct.pack(">i", code))
        except OSError:
            pass


def _version_mismatch(req):
    """True if the request pins an agentVersion that isn't ours."""
    v = req.get("agentVersion")
    return bool(v) and SELF_HASH is not None and v != SELF_HASH


def _shell_handle_connection(vsock_sock, replenish_fn):
    """Wait for a command from the host, execute it, return the result."""
    replenished = False
    version_exit = False
    try:
        hdr = _recv_exact(vsock_sock, 4)
        if not hdr:
            vsock_sock.close()
            replenish_fn()
            return

        length = struct.unpack(">I", hdr)[0]
        if length > MAX_REQUEST_SIZE:
            vsock_sock.close()
            replenish_fn()
            return

        data = _recv_exact(vsock_sock, length)
        if not data:
            vsock_sock.close()
            replenish_fn()
            return

        req = json.loads(data.decode("utf-8"))
        cmd = req.get("cmd", "")
        timeout = req.get("timeout", 30)
        workdir = req.get("workdir")
        version_exit = _version_mismatch(req)

        # Interactive PTY session (`exec -it`, a tab attach running
        # `tmux attach`, or a host terminal view): allocate a pty, run the
        # command on it, and stream raw bytes framed over the vsock until the
        # child exits.
        if req.get("interactive"):
            # Replenish on claim, not on close: this connection is now held for
            # the life of the terminal session (possibly hours). Without an
            # immediate replacement, N concurrent host terminals would drain the
            # POOL_SIZE idle connections and starve exec/roster traffic.
            replenished = True
            replenish_fn()
            _run_interactive(vsock_sock, req)
            return  # finally below closes the vsock

        # Source /mnt/bromure-meta/proxy.env before running so the command sees
        # HTTPS_PROXY + the per-language CA bundle paths. .bashrc only sources
        # proxy.env for interactive shells (the `case $- in *i*) return` guard);
        # the shell subprocess.run() spawns below is non-interactive, so without
        # this prefix curl / pip / npm bypass the MITM proxy entirely.
        wrapped = (
            "if [ -r /mnt/bromure-meta/proxy.env ]; then "
            "set -a; . /mnt/bromure-meta/proxy.env; set +a; "
            "fi; "
            + cmd
        )

        try:
            result = subprocess.run(
                wrapped, shell=True, capture_output=True, text=True,
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

        resp_data = json.dumps(response).encode("utf-8")
        resp_hdr = struct.pack(">I", len(resp_data))
        vsock_sock.sendall(resp_hdr + resp_data)

    except (BrokenPipeError, ConnectionResetError, OSError) as e:
        log("shell", "connection error: %s" % e)
    finally:
        try:
            vsock_sock.close()
        except OSError:
            pass
        if not replenished:
            replenish_fn()
        if version_exit:
            # Host pinned a newer agentVersion: request is done, so hand off to
            # a fresh process (systemd Restart=always respawns from the staged
            # source, which the host has already updated).
            log("shell", "agentVersion mismatch — exiting after request")
            os._exit(0)


def _shell_connect_to_host():
    """Open a vsock connection to the host. Returns socket or None."""
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.connect((HOST_CID, SHELL_VSOCK_PORT))
        return s
    except (ConnectionRefusedError, ConnectionResetError, OSError):
        return None


def shell_agent_service():
    """Guest-initiated vsock pool to host port 5800 (see shell-agent.py)."""
    log("shell", "starting")

    def replenish():
        """Open a new vsock connection to refill the pool."""
        for _ in range(20):
            if not _RUNNING.is_set():
                return
            s = _shell_connect_to_host()
            if s:
                t = threading.Thread(
                    target=_shell_handle_connection, args=(s, replenish),
                    daemon=True)
                t.start()
                return
            time.sleep(0.1)
        log("shell", "failed to replenish pool after 20 attempts")

    # Fill the initial pool.
    established = 0
    for _ in range(POOL_SIZE):
        if not _RUNNING.is_set():
            return
        for _ in range(30):
            if not _RUNNING.is_set():
                return
            s = _shell_connect_to_host()
            if s:
                established += 1
                t = threading.Thread(
                    target=_shell_handle_connection, args=(s, replenish),
                    daemon=True)
                t.start()
                break
            time.sleep(0.2)

    log("shell", "pool ready (%d connections)" % established)

    while _RUNNING.is_set():
        time.sleep(1)


# ─────────────── §4 vm-bridge (local listeners → host vsock MITM) ───────────
# Bridges several in-VM clients to the host's MITM engine over vsock:
#   • HTTP proxy:  0.0.0.0:8080 (TCP)                →  vsock CID 2 port 8443
#   • ssh-agent:   /tmp/bromure-agent.sock (Unix)    →  vsock CID 2 port 8444
#   • AWS creds:   /tmp/bromure-aws-creds.sock (Unix) →  vsock CID 2 port 8445
#   • Local LLM:   127.0.0.1:11434 (TCP)             →  vsock CID 2 port 8446
# Bytes are pumped both directions per connection. No TLS, no inspection.
BRIDGE_LOG_PATH = "/tmp/bromure-vm-bridge.log"


def _bridge_log(msg):
    try:
        with open(BRIDGE_LOG_PATH, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def _bridge_pump(src, dst):
    """Copy bytes from src to dst until either side closes."""
    try:
        while True:
            chunk = src.recv(64 * 1024)
            if not chunk:
                break
            dst.sendall(chunk)
    except (OSError, ConnectionError):
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _bridge(client, vsock_port, label):
    """Open a vsock connection to the host, then pump both directions."""
    try:
        host = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        host.connect((HOST_CID, vsock_port))
    except OSError as e:
        _bridge_log("[%s] vsock connect to host:%d failed: %s"
                    % (label, vsock_port, e))
        client.close()
        return

    _bridge_log("[%s] bridging client → host:%d" % (label, vsock_port))
    t1 = threading.Thread(target=_bridge_pump, args=(client, host), daemon=True)
    t2 = threading.Thread(target=_bridge_pump, args=(host, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    host.close()


def _proxy_allowed_nets():
    """Networks permitted to use the HTTP proxy: loopback + docker bridges.

    We bind 0.0.0.0 so containers reach us via the bridge gateway, but only
    *serve* loopback + docker bridge subnets — LAN/NAT peers are refused. Always
    include 127.0.0.0/8 and docker's default pool (172.16.0.0/12), plus any live
    docker0 / br-* interface subnets.
    """
    nets = [
        ipaddress.ip_network("127.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
    ]
    try:
        out = subprocess.check_output(
            ["ip", "-o", "-f", "inet", "addr", "show"],
            text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and (parts[1].startswith("docker")
                                    or parts[1].startswith("br-")):
                try:
                    nets.append(ipaddress.ip_network(parts[3], strict=False))
                except ValueError:
                    pass
    except Exception:
        pass
    return nets


def _proxy_peer_allowed(nets, addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in n for n in nets)


def bridge_http_proxy_service():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Bind 0.0.0.0 so docker containers can route through the MITM proxy via the
    # bridge gateway. We still firewall in userspace: only loopback + docker
    # bridge peers are served, so the open bind isn't exposed to LAN/NAT.
    s.bind(("0.0.0.0", HTTP_PROXY_TCP_PORT))
    s.listen(64)
    allowed = _proxy_allowed_nets()
    _bridge_log("[http] listening on 0.0.0.0:%d (allowed: %s)"
                % (HTTP_PROXY_TCP_PORT,
                   ", ".join(str(n) for n in allowed)))
    while True:
        conn, addr = s.accept()
        if not _proxy_peer_allowed(allowed, addr[0]):
            _bridge_log("[http] refused %s (not loopback / docker bridge)"
                        % addr[0])
            try:
                conn.close()
            except OSError:
                pass
            continue
        threading.Thread(
            target=_bridge, args=(conn, HTTP_PROXY_VSOCK_PORT, "http"),
            daemon=True).start()


def bridge_ssh_agent_service():
    try:
        os.unlink(SSH_AGENT_UNIX_PATH)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(SSH_AGENT_UNIX_PATH)
    os.chmod(SSH_AGENT_UNIX_PATH, 0o600)
    s.listen(8)
    _bridge_log("[ssh] listening on %s" % SSH_AGENT_UNIX_PATH)
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=_bridge, args=(conn, SSH_AGENT_VSOCK_PORT, "ssh"),
            daemon=True).start()


def bridge_aws_creds_service():
    try:
        os.unlink(AWS_CREDS_UNIX_PATH)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(AWS_CREDS_UNIX_PATH)
    os.chmod(AWS_CREDS_UNIX_PATH, 0o600)
    s.listen(8)
    _bridge_log("[aws] listening on %s" % AWS_CREDS_UNIX_PATH)
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=_bridge, args=(conn, AWS_CREDS_VSOCK_PORT, "aws"),
            daemon=True).start()


def bridge_llm_engine_service():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", LLM_ENGINE_TCP_PORT))
    s.listen(64)
    _bridge_log("[llm] listening on 127.0.0.1:%d" % LLM_ENGINE_TCP_PORT)
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=_bridge, args=(conn, LLM_ENGINE_VSOCK_PORT, "llm"),
            daemon=True).start()


# ─────────────────── §5 claude-token (vsock 8446, credentials) ──────────────
# Connects to the host over vsock and answers read/write RPCs against
# ~/.claude/.credentials.json. Security invariant: real → host, fake → VM. The
# write path refuses any value that doesn't carry the brm- fake shape.
# Wire format: line-delimited JSON, one request/response per line, persistent
# connection, host pushes requests as needed.
CLAUDE_LOG_PATH = "/tmp/bromure-claude-token.log"


def _claude_log(msg):
    try:
        with open(CLAUDE_LOG_PATH, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def _claude_read_credentials():
    """Pull (access, refresh) from the on-disk credentials JSON, or (None, None)
    if the file / oauth block is missing (what `claude login` not run looks
    like)."""
    try:
        with open(CLAUDE_CREDS_PATH, "r") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, None
    except (OSError, json.JSONDecodeError) as e:
        _claude_log("read failed: %s" % e)
        return None, None
    oauth = data.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return None, None
    access = oauth.get("accessToken")
    refresh = oauth.get("refreshToken")
    if isinstance(access, str) and isinstance(refresh, str):
        return access, refresh
    return None, None


def _claude_write_credentials(access, refresh):
    """Replace accessToken + refreshToken in-place, preserving every other
    field. Atomic via tempfile + rename."""
    if not (isinstance(access, str) and access.startswith(ACCESS_FAKE_PREFIX)):
        return False, "access token does not match fake prefix"
    if not (isinstance(refresh, str) and refresh.startswith(REFRESH_FAKE_PREFIX)):
        return False, "refresh token does not match fake prefix"

    try:
        os.makedirs(os.path.dirname(CLAUDE_CREDS_PATH), exist_ok=True)
        try:
            with open(CLAUDE_CREDS_PATH, "r") as f:
                doc = json.load(f)
        except FileNotFoundError:
            doc = {}
        except json.JSONDecodeError:
            return False, "existing credentials file is not valid JSON"
        oauth = doc.get("claudeAiOauth")
        if not isinstance(oauth, dict):
            oauth = {}
            doc["claudeAiOauth"] = oauth
        oauth["accessToken"] = access
        oauth["refreshToken"] = refresh

        target_dir = os.path.dirname(CLAUDE_CREDS_PATH) or "."
        fd, tmp = tempfile.mkstemp(prefix=".credentials.", suffix=".tmp",
                                   dir=target_dir)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, CLAUDE_CREDS_PATH)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True, None
    except Exception as e:
        _claude_log("write failed: %s" % e)
        return False, str(e)


def _claude_serve(conn):
    f = conn.makefile("rwb", buffering=0)
    while True:
        line = f.readline()
        if not line:
            return
        try:
            req = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            f.write(b'{"ok":false,"reason":"bad json"}\n')
            continue
        op = req.get("op")
        if op == "read":
            access, refresh = _claude_read_credentials()
            resp = {"ok": True, "access": access, "refresh": refresh}
        elif op == "write":
            access = req.get("access")
            refresh = req.get("refresh")
            ok, reason = _claude_write_credentials(access, refresh)
            resp = {"ok": ok}
            if not ok:
                resp["reason"] = reason
        else:
            resp = {"ok": False, "reason": "unknown op: %r" % op}
        f.write((json.dumps(resp) + "\n").encode("utf-8"))


def claude_token_service():
    while _RUNNING.is_set():
        s = None
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, CLAUDE_TOKEN_PORT))
            _claude_log("connected to host vsock %d" % CLAUDE_TOKEN_PORT)
            _claude_serve(s)
            _claude_log("connection closed by host")
        except (OSError, socket.error) as e:
            # Host hasn't opened the listener yet (or VM rebooted faster than
            # the host bridge instantiated). Back off briefly.
            if e.errno not in (errno.ECONNREFUSED, errno.ENOTCONN,
                               errno.ENETUNREACH):
                _claude_log("vsock error: %s" % e)
        finally:
            try:
                if s is not None:
                    s.close()
            except Exception:
                pass
        time.sleep(2)


# ─────────────────── §6 codex-token (vsock 8447, auth.json) ─────────────────
# Mirrors the Claude agent for Codex CLI's ~/.codex/auth.json tokens block.
CODEX_LOG_PATH = "/tmp/bromure-codex-token.log"


def _codex_log(msg):
    try:
        with open(CODEX_LOG_PATH, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def _codex_is_jwt_fake(tok):
    if not isinstance(tok, str):
        return False
    parts = tok.split(".")
    if len(parts) != 3:
        return False
    return parts[2].startswith(JWT_SIG_FAKE_MARKER)


def _codex_is_refresh_fake(tok):
    if not isinstance(tok, str):
        return False
    return tok.startswith("rt_" + REFRESH_FAKE_MARKER + "-")


def _codex_read_credentials():
    try:
        with open(CODEX_CREDS_PATH, "r") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as e:
        _codex_log("read failed: %s" % e)
        return None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    out = {
        "access": tokens.get("access_token"),
        "refresh": tokens.get("refresh_token"),
        "id_token": tokens.get("id_token"),
    }
    if not all(isinstance(v, str) for v in out.values()):
        return None
    return out


def _codex_write_credentials(access, refresh, id_token):
    if not _codex_is_jwt_fake(access):
        return False, "access token does not have brm-cdX-sig signature marker"
    if not _codex_is_refresh_fake(refresh):
        return False, "refresh token does not have brm-cdX-rfs marker"
    if not _codex_is_jwt_fake(id_token):
        return False, "id token does not have brm-cdX-sig signature marker"

    try:
        os.makedirs(os.path.dirname(CODEX_CREDS_PATH), exist_ok=True)
        try:
            with open(CODEX_CREDS_PATH, "r") as f:
                doc = json.load(f)
        except FileNotFoundError:
            doc = {}
        except json.JSONDecodeError:
            return False, "existing credentials file is not valid JSON"
        tokens = doc.get("tokens")
        if not isinstance(tokens, dict):
            tokens = {}
            doc["tokens"] = tokens
        tokens["access_token"] = access
        tokens["refresh_token"] = refresh
        tokens["id_token"] = id_token

        target_dir = os.path.dirname(CODEX_CREDS_PATH) or "."
        fd, tmp = tempfile.mkstemp(prefix="auth.", suffix=".tmp", dir=target_dir)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, CODEX_CREDS_PATH)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True, None
    except Exception as e:
        _codex_log("write failed: %s" % e)
        return False, str(e)


def _codex_serve(conn):
    f = conn.makefile("rwb", buffering=0)
    while True:
        line = f.readline()
        if not line:
            return
        try:
            req = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            f.write(b'{"ok":false,"reason":"bad json"}\n')
            continue
        op = req.get("op")
        if op == "read":
            t = _codex_read_credentials()
            if t is None:
                resp = {"ok": True, "access": None, "refresh": None,
                        "id_token": None}
            else:
                resp = {"ok": True, **t}
        elif op == "write":
            ok, reason = _codex_write_credentials(req.get("access"),
                                                  req.get("refresh"),
                                                  req.get("id_token"))
            resp = {"ok": ok}
            if not ok:
                resp["reason"] = reason
        else:
            resp = {"ok": False, "reason": "unknown op: %r" % op}
        f.write((json.dumps(resp) + "\n").encode("utf-8"))


def codex_token_service():
    while _RUNNING.is_set():
        s = None
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, CODEX_TOKEN_PORT))
            _codex_log("connected to host vsock %d" % CODEX_TOKEN_PORT)
            _codex_serve(s)
            _codex_log("connection closed by host")
        except (OSError, socket.error) as e:
            if e.errno not in (errno.ECONNREFUSED, errno.ENOTCONN,
                               errno.ENETUNREACH):
                _codex_log("vsock error: %s" % e)
        finally:
            try:
                if s is not None:
                    s.close()
            except Exception:
                pass
        time.sleep(2)


# ─────────────────── §7 loopback-relay (vsock 5010, OAuth callback) ─────────
# Lets the macOS host reach a loopback server the guest opened on
# 127.0.0.1:<port> — e.g. the redirect listener an OAuth CLI starts for its
# redirect_uri. The host opens the login URL in the *host* browser and, for the
# callback, connects here over vsock and asks us to splice to 127.0.0.1:<port>.
# Protocol (vsock 5010 — guest listens, host connects):
#     host -> guest:  "<target-port>\n"  (ASCII, newline-terminated)
#     then raw bytes spliced bidirectionally with 127.0.0.1:<target-port>.
# One vsock connection == one forwarded TCP connection.
LOOPBACK_STATUS_LOG = os.path.join(OUTBOX, "loopback-relay.log")


def _loopback_log(*parts):
    msg = " ".join(str(p) for p in parts)
    print("loopback-relay:", msg, file=sys.stderr, flush=True)
    try:
        with open(LOOPBACK_STATUS_LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except OSError:
        pass


def _loopback_connect(port):
    """Connect to the CLI's callback listener. Try IPv4 127.0.0.1 first (what
    the redirect_uri advertises), then IPv6 ::1 — some runtimes bind only the
    v6 loopback for `localhost`."""
    last = None
    for family, host in ((socket.AF_INET, "127.0.0.1"),
                         (socket.AF_INET6, "::1")):
        sock = None
        try:
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((host, port))
            sock.settimeout(None)
            return sock, host
        except OSError as exc:
            last = exc
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
    raise last if last else OSError("no loopback family")


def _loopback_pipe(src, dst, label=None):
    total = 0
    first = True
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            if first and label:
                head = chunk.split(b"\r\n", 1)[0][:160].decode("latin1",
                                                               "replace")
                _loopback_log("%s first line: %r" % (label, head))
                first = False
            total += len(chunk)
            dst.sendall(chunk)
    except OSError as exc:
        if label:
            _loopback_log("%s pipe error after %dB: %s" % (label, total, exc))
    finally:
        if label:
            _loopback_log("%s done, %dB" % (label, total))
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _loopback_handle(vs):
    # Read the newline-terminated target port that prefixes the stream.
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = vs.recv(64)
            if not chunk:
                vs.close()
                return
            buf += chunk
            # The cap only applies while we still haven't seen the newline — the
            # host may coalesce the "<port>\n" header with the start of the
            # request in one segment, so buf legitimately exceeds the cap once
            # the newline has arrived.
            if b"\n" not in buf and len(buf) > MAX_PORT_HEADER:
                vs.close()
                return
    except OSError:
        vs.close()
        return

    line, _, rest = buf.partition(b"\n")
    try:
        port = int(line.strip())
    except ValueError:
        vs.close()
        return
    if not (1 <= port <= 65535):
        vs.close()
        return

    try:
        tcp, host = _loopback_connect(port)
    except OSError as exc:
        # Single-shot listeners (grok) shut down after receiving the code; the
        # browser often opens parallel/retry connections, so late ones find
        # nothing listening. Return a clean 200 so the tab lands on a tidy
        # "you can close this" page instead of a dropped-connection error.
        _loopback_log("callback for port %d: listener gone (%s); "
                      "returning synthetic 200" % (port, exc))
        body = ("<!doctype html><html><body style=\"font-family:-apple-system,"
                "sans-serif;text-align:center;margin-top:4em\"><h2>Login "
                "complete</h2><p>You can close this tab and return to the "
                "terminal.</p></body></html>").encode("utf-8")
        resp = (b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/html; charset=utf-8\r\n"
                b"Connection: close\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n"
                + body)
        try:
            vs.sendall(resp)
        except OSError:
            pass
        vs.close()
        return

    # Any bytes that arrived after the port header belong to the TCP side.
    if rest:
        try:
            tcp.sendall(rest)
        except OSError:
            vs.close()
            tcp.close()
            return

    req_line = (rest.split(b"\r\n", 1)[0][:160].decode("latin1", "replace")
                if rest else "(none yet)")
    _loopback_log("callback for port %d: forwarding via %s; request: %r"
                  % (port, host, req_line))
    # Browser→CLI (request body, if any) on a thread; CLI→browser (response) in
    # the foreground with logging so we capture the CLI's status line.
    t = threading.Thread(target=_loopback_pipe, args=(vs, tcp),
                         kwargs={"label": "req[%d]" % port}, daemon=True)
    t.start()
    _loopback_pipe(tcp, vs, label="resp[%d]" % port)
    t.join(timeout=1)
    try:
        vs.close()
    except OSError:
        pass
    try:
        tcp.close()
    except OSError:
        pass


def loopback_relay_service():
    _loopback_log("starting (pid %d, python %s)"
                  % (os.getpid(), sys.version.split()[0]))
    srv = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((socket.VMADDR_CID_ANY, LOOPBACK_VSOCK_PORT))
    srv.listen(8)
    _loopback_log("listening on vsock port %d" % LOOPBACK_VSOCK_PORT)
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=_loopback_handle, args=(conn,),
                         daemon=True).start()


# ─────────────────── §8 Tab engine (tmux session + roster + commands) ───────
# Behaviour-exact port of Profile.swift's tabAgentContent. tabs.txt and the
# outbox marker files are parsed by the macOS host, so their formats must not
# drift. The kitty foreground loop and the openbox HOSTKEY marker-bounce are
# NOT ported (headless).

# One-shot-per-process reboot signal guard (the shell's REBOOT_SIGNALLED; the
# host dedupes the marker write, so a single shared flag is behaviour-equal).
_REBOOT_SIGNALLED = threading.Event()

# ── subprocess helpers ──────────────────────────────────────────────────────
_DEVNULL = subprocess.DEVNULL


def _capture(args, timeout=None):
    """Run args, return stdout (str). '' on any failure."""
    try:
        p = subprocess.run(args, capture_output=True, text=True,
                           timeout=timeout)
        return p.stdout
    except Exception:
        return ""


def _tmux(*args):
    try:
        return subprocess.run(["tmux", *args], capture_output=True, text=True)
    except OSError:
        # tmux binary missing / transient exec failure — behave like a failed
        # command so callers fall through to their has-session guard rather than
        # crash-looping the roster service.
        return subprocess.CompletedProcess(args, 1, "", "")


def _tmux_ok(*args):
    try:
        return subprocess.run(["tmux", *args], stdout=_DEVNULL,
                             stderr=_DEVNULL).returncode == 0
    except Exception:
        return False


def _has_session():
    return _tmux_ok("has-session", "-t", TMUX_S)


def _new_window(command=None, cwd=None, env=None):
    """tmux new-window -P -F '#{window_id}' … → window id ('' on failure)."""
    args = ["tmux", "new-window", "-P", "-F", "#{window_id}", "-t", TMUX_S]
    if cwd:
        args += ["-c", cwd]
    if env:
        for k, v in env.items():
            args += ["-e", "%s=%s" % (k, v)]
    if command is not None:
        args.append(command)
    try:
        p = subprocess.run(args, capture_output=True, text=True)
        return p.stdout.strip()
    except Exception:
        return ""


def _set_window_option(win, name, value):
    try:
        subprocess.run(["tmux", "set-option", "-w", "-t", win, name, value],
                       stdout=_DEVNULL, stderr=_DEVNULL)
    except Exception:
        pass


def _b64d(s):
    """base64 -d, returning '' on failure (matches the shell pipeline)."""
    try:
        return base64.b64decode(s).decode("utf-8", "replace")
    except Exception:
        return ""


def _b64e(s):
    return base64.b64encode(s.encode("utf-8")).decode("ascii")


def _sp(s):
    """First-space split, mirroring shell ${x%% *} / ${x#* }. When there is no
    space both halves equal the original (as the shell parameter expansions do).
    """
    i = s.find(" ")
    if i < 0:
        return s, s
    return s[:i], s[i + 1:]


# ── atomic outbox publishing ────────────────────────────────────────────────
def _atomic_publish(tmp_name, final_name, content):
    """Write content to OUTBOX/tmp_name then mv -f to OUTBOX/final_name."""
    tmp = os.path.join(OUTBOX, tmp_name)
    dst = os.path.join(OUTBOX, final_name)
    try:
        with open(tmp, "w") as f:
            f.write(content)
        os.replace(tmp, dst)
        return True
    except OSError:
        return False


def docker_err(msg):
    _atomic_publish(".docker-error.tmp", "docker-error.txt", msg)


def worktree_err(msg):
    _atomic_publish(".worktree-error.tmp", "worktree-error.txt", msg)


def docker_run_status(state, image, done, total):
    _atomic_publish(".docker-run-status.tmp", "docker-run-status.txt",
                    "%s\t%s\t%s\t%s" % (state, image, done, total))


def docker_run_status_clear():
    _atomic_publish(".docker-run-status.tmp", "docker-run-status.txt", "")


# ── reboot detection (port of reboot_pending / signal_reboot_if_pending) ─────
def reboot_pending():
    """True while systemd is taking the system down for a *reboot*."""
    # User-level query first: succeeds while dbus is up (the common case).
    try:
        p = subprocess.run(["systemctl", "list-jobs", "--no-legend"],
                           capture_output=True, text=True)
        if p.returncode == 0:
            return "reboot.target" in p.stdout
    except Exception:
        pass
    # dbus already down (late shutdown): root systemctl falls back to systemd's
    # private socket, which answers until the very end.
    try:
        p = subprocess.run(["sudo", "-n", "systemctl", "list-jobs",
                           "--no-legend"], capture_output=True, text=True)
        if "reboot.target" in p.stdout:
            return True
    except Exception:
        pass
    try:
        rl = _capture(["runlevel"])
        parts = rl.split()
        return len(parts) >= 2 and parts[1] == "6"
    except Exception:
        return False


def signal_reboot_if_pending():
    """Drop the one-shot reboot marker if the OS is rebooting. Idempotent."""
    if _REBOOT_SIGNALLED.is_set():
        return True
    if reboot_pending():
        log("tabs", "reboot detected — signalling host to relaunch")
        try:
            open(os.path.join(OUTBOX, "reboot-intent"), "w").close()
        except OSError:
            pass
        try:
            os.sync()
        except Exception:
            pass
        _REBOOT_SIGNALLED.set()
        return True
    return False


# ── worktree registry + helpers ─────────────────────────────────────────────
def _wt_registry(repo_name):
    return os.path.join(os.path.expanduser("~"), ".bromure", "worktrees",
                        repo_name, ".registry")


def _wt_registry_add(repo_name, branch, parent, display, tool):
    reg = _wt_registry(repo_name)
    try:
        os.makedirs(os.path.dirname(reg), exist_ok=True)
    except OSError:
        return
    try:
        with open(reg, "a") as f:
            f.write("%s%s%s%s%s%s%s\n" % (branch, US, parent, US, display,
                                          US, tool))
    except OSError:
        pass


def _wt_registry_del(repo_name, branch):
    reg = _wt_registry(repo_name)
    if not os.access(reg, os.R_OK):
        return
    try:
        with open(reg, "r") as f:
            lines = f.readlines()
    except OSError:
        return
    kept = []
    for line in lines:
        fields = line.rstrip("\n").split(US)
        r_branch = fields[0] if fields else ""
        # Skip (drop) lines with an empty branch OR a matching branch.
        if not r_branch or r_branch == branch:
            continue
        r_parent = fields[1] if len(fields) > 1 else ""
        r_display = fields[2] if len(fields) > 2 else ""
        r_tool = fields[3] if len(fields) > 3 else ""
        kept.append("%s%s%s%s%s%s%s\n" % (r_branch, US, r_parent, US,
                                          r_display, US, r_tool))
    tmp = "%s.tmp.%d" % (reg, os.getpid())
    try:
        with open(tmp, "w") as f:
            f.writelines(kept)
        os.replace(tmp, reg)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _read_registry(repo_name):
    """Yield (branch, parent, display, tool) tuples from a repo's registry."""
    reg = _wt_registry(repo_name)
    if not os.access(reg, os.R_OK):
        return []
    rows = []
    try:
        with open(reg, "r") as f:
            for line in f:
                if line.endswith("\n"):
                    line = line[:-1]
                fields = line.split(US, 3)
                while len(fields) < 4:
                    fields.append("")
                rows.append(tuple(fields[:4]))
    except OSError:
        return []
    return rows


def _worktree_dir_for_branch(root, branch):
    """Resolve a branch's checkout dir from `git worktree list --porcelain`
    (empty if the branch isn't checked out anywhere). The main worktree matches
    too."""
    out = _capture(["git", "-C", root, "worktree", "list", "--porcelain"])
    target = "refs/heads/" + branch
    cur = ""
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[len("worktree "):]
        elif line.startswith("branch "):
            parts = line.split()
            if len(parts) >= 2 and parts[1] == target:
                return cur
    return ""


def _worktree_main_root(cwd):
    """First `worktree <dir>` line = the primary checkout (never a worktree)."""
    out = _capture(["git", "-C", cwd, "worktree", "list", "--porcelain"])
    for line in out.splitlines():
        if line.startswith("worktree "):
            return line[len("worktree "):]
    return ""


def _worktree_include(main_root, wt_dir):
    """Copy files listed in the repo's .worktreeinclude into a fresh worktree.

    git worktree add makes a clean checkout, so gitignored config agents rely on
    (.env, local tokens) is absent. Each non-comment line is a path relative to
    the main worktree root; copied only when it exists there and isn't already
    in the new checkout.
    """
    inc = os.path.join(main_root, ".worktreeinclude")
    if not os.access(inc, os.R_OK):
        return
    try:
        with open(inc, "r") as f:
            pats = f.read().splitlines()
    except OSError:
        return
    for pat in pats:
        if pat == "" or pat.startswith("#"):
            continue
        src = os.path.join(main_root, pat)
        dst = os.path.join(wt_dir, pat)
        if not os.path.exists(src):
            continue
        if os.path.exists(dst):
            continue
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
        except OSError:
            continue
        try:
            subprocess.run(["cp", "-a", src, dst], stdout=_DEVNULL,
                           stderr=_DEVNULL)
        except Exception:
            pass


def _restore_worktrees(repo_root, repo_name):
    """Reboot restore: re-open a tab for each registered worktree of this repo
    that still exists on disk and isn't already open. Once per boot per repo
    (marker in /tmp, cleared by a reboot)."""
    rows = _read_registry(repo_name)
    if not rows:
        return
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", repo_name)
    marker = "/tmp/.bromure-wt-restored-" + safe
    if os.path.exists(marker):
        return
    try:
        open(marker, "w").close()
    except OSError:
        pass
    open_branches = set(
        _capture(["tmux", "list-windows", "-t", TMUX_S, "-F",
                  "#{@worktree}"]).splitlines())
    for r_branch, r_parent, r_display, r_tool in rows:
        if not r_branch:
            continue
        if r_branch in open_branches:   # already open
            continue
        wdir = _worktree_dir_for_branch(repo_root, r_branch)
        if not wdir or not os.path.isdir(wdir):   # git worktree gone
            continue
        win = _new_window(command="bash -l", cwd=wdir,
                          env={"BROMURE_AC_WT_TOOL": r_tool})
        if not win:
            continue
        _set_window_option(win, "@worktree", r_branch)
        _set_window_option(win, "@parent_branch", r_parent)
        _set_window_option(win, "@root_repo", repo_root)
        _set_window_option(win, "@label", r_tool)
        _set_window_option(win, "@display", r_display)


def _worktree_create(cwd, slug, display, tool, prompt_b64):
    if prompt_b64 == "-":
        prompt_b64 = ""   # "-" sentinel = no prompt
    if not os.path.isdir(cwd):
        worktree_err("worktree: cwd is gone: " + cwd)
        return
    parent_branch = _capture(
        ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]).strip()
    main_root = _worktree_main_root(cwd)
    if not main_root:
        worktree_err("worktree: %s is not a git repo" % cwd)
        return
    if parent_branch == "HEAD":
        parent_branch = _capture(
            ["git", "-C", cwd, "rev-parse", "--short", "HEAD"]).strip()

    repo_name = os.path.basename(main_root)
    base = os.path.join(os.path.expanduser("~"), ".bromure", "worktrees",
                        repo_name)
    try:
        os.makedirs(base, exist_ok=True)
    except OSError:
        pass
    # Unique branch + dir: append -2, -3, … if the slug is taken.
    branch = "wt/" + slug
    wt_dir = os.path.join(base, slug)
    n = 2
    while (subprocess.run(
            ["git", "-C", cwd, "show-ref", "--verify", "--quiet",
             "refs/heads/" + branch], stdout=_DEVNULL,
            stderr=_DEVNULL).returncode == 0) or os.path.exists(wt_dir):
        branch = "wt/%s-%d" % (slug, n)
        wt_dir = os.path.join(base, "%s-%d" % (slug, n))
        n += 1

    add = subprocess.run(
        ["git", "-C", cwd, "worktree", "add", "-b", branch, wt_dir, "HEAD"],
        capture_output=True, text=True)
    if add.returncode != 0:
        worktree_err("worktree add failed: " + (add.stderr or add.stdout))
        return
    _worktree_include(main_root, wt_dir)

    win = _new_window(command="bash -l", cwd=wt_dir,
                      env={"BROMURE_AC_WT_TOOL": tool,
                           "BROMURE_AC_WT_PROMPT": prompt_b64})
    if not win:
        worktree_err("worktree: could not open a tab (created %s at %s)"
                     % (branch, wt_dir))
        return
    _set_window_option(win, "@worktree", branch)
    _set_window_option(win, "@parent_branch", parent_branch)
    _set_window_option(win, "@root_repo", main_root)
    _set_window_option(win, "@label", tool)
    _set_window_option(win, "@display", display)
    _wt_registry_add(repo_name, branch, parent_branch, display, tool)


# Prompt the coding agent gets when a merge conflicts (verbatim from source).
_MERGE_PROMPT = ("A git merge in this directory hit conflicts. Run 'git status'"
                 " to see them, then resolve every conflicted file, keeping both"
                 " sides' intent, and stage the resolutions with 'git add'. Do"
                 " NOT commit yet: give me a short summary of how you resolved"
                 " each conflict and ask whether I'd like to review the changes"
                 " first. Only run 'git commit --no-edit' to finish the merge"
                 " after I confirm.")

# The merge window command (behaviour-equal to the shell heredoc): run the merge
# unless one is already in progress, then either hand the checkout to the coding
# agent (conflicts → exec bash -l → .bashrc worktree-launch branch) or report a
# clean merge and wait. Branch names arrive via -e (env VALUES, never re-parsed).
_MERGE_WINDOW_CMD = (
    'if ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then '
    'git merge --no-edit "$WT_SRC"; fi; echo; '
    'if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then '
    'echo "bromure: merge conflicts — starting $BROMURE_AC_WT_TOOL to resolve…";'
    ' echo; exec bash -l; else '
    'echo "bromure: merged $WT_SRC into $WT_DST."; '
    'echo; echo Press Enter to close; read _; fi')


def _worktree_merge(branch, target, root, display, tool):
    tdir = _worktree_dir_for_branch(root, target)
    if not tdir:
        tdir = root
    if not os.path.isdir(tdir):
        worktree_err("merge: no checkout for '%s'" % target)
        return
    rp64 = _b64e(_MERGE_PROMPT)
    win = _new_window(command=_MERGE_WINDOW_CMD, cwd=tdir,
                      env={"WT_SRC": branch, "WT_DST": target,
                           "BROMURE_AC_WT_TOOL": tool,
                           "BROMURE_AC_WT_PROMPT": rp64})
    # @display "Merge → …" is the host's marker for a merge tab.
    if win:
        _set_window_option(win, "@display", "Merge → " + target)


def _worktree_remove(root, branch):
    if not root:
        return
    wdir = _worktree_dir_for_branch(root, branch)
    if wdir and wdir != root:
        subprocess.run(["git", "-C", root, "worktree", "remove", "--force",
                        wdir], stdout=_DEVNULL, stderr=_DEVNULL)
    subprocess.run(["git", "-C", root, "branch", "-D", branch],
                   stdout=_DEVNULL, stderr=_DEVNULL)
    subprocess.run(["git", "-C", root, "worktree", "prune"],
                   stdout=_DEVNULL, stderr=_DEVNULL)
    _wt_registry_del(os.path.basename(root), branch)


def _worktree_terminal(root, branch):
    wtt_dir = _worktree_dir_for_branch(root, branch)
    if not wtt_dir or not os.path.isdir(wtt_dir):
        worktree_err("terminal: no checkout for '%s'" % branch)
        return
    win = _new_window(cwd=wtt_dir)
    if not win:
        worktree_err("terminal: could not open a tab")
        return
    _set_window_option(win, "@parent_branch", branch)
    _set_window_option(win, "@root_repo", root)


_RESOLVE_PROMPT = ("A git merge in this directory has conflicts. Run 'git"
                   " status' to see them, then resolve every conflicted file and"
                   " stage the resolutions with 'git add'. Do NOT commit yet:"
                   " give me a short summary of your resolution and ask whether"
                   " I'd like to review the changes first. Only run 'git commit"
                   " --no-edit' after I confirm.")


def _worktree_resolve(merge_dir, tool):
    if not os.path.isdir(merge_dir):
        worktree_err("resolve: checkout is gone: " + merge_dir)
        return
    p64 = _b64e(_RESOLVE_PROMPT)
    win = _new_window(command="bash -l", cwd=merge_dir,
                      env={"BROMURE_AC_WT_TOOL": tool,
                           "BROMURE_AC_WT_PROMPT": p64})
    if win:
        _set_window_option(win, "@display", "Resolve conflicts")


# ── roster: tab list published to /mnt/bromure-outbox/tabs.txt ───────────────
# Internal tmux -F list is TAB-separated with 13 columns (idx, active, cmd, tty,
# @label, @container, cwd, @worktree, @parent_branch, @root_repo, @display,
# mouse_any, title). The free-text pane_title stays LAST so a stray tab inside
# a title can't shift the fixed columns (the parse's maxsplit folds it in).
# The PUBLISHED tabs.txt line is TAB-separated with 10 columns (the host
# contract): idx, active, name, container, cwd, worktree, pbranch, rroot,
# display, isrepo. (cmd + tty are consumed to compute `name`; mouse_any feeds
# the stuck-mouse heal.)
_ROSTER_FMT = ("#{window_index}\t#{?window_active,1,0}\t"
               "#{pane_current_command}\t#{pane_tty}\t#{@label}\t"
               "#{@container}\t#{pane_current_path}\t#{@worktree}\t"
               "#{@parent_branch}\t#{@root_repo}\t#{@display}\t"
               "#{mouse_any_flag}\t#{pane_title}")

# The pane title (OSC 2) an agent sets, when it's a real session title rather
# than tmux's default (the hostname) or a shell's "user@host" / path. Used to
# turn a bare "claude" tab into "Refactor website (claude)".
try:
    _HOSTNAME = socket.gethostname()
except Exception:
    _HOSTNAME = ""


def _agent_title(pane_title, agent):
    """A cleaned agent session title, or '' if pane_title isn't meaningful.

    Claude Code (and similar) set the terminal title to the current task
    summary via OSC 2; tmux exposes it as #{pane_title}. We ignore the
    defaults: empty, the hostname, a user@host/path form, or just the agent
    name itself."""
    t = (pane_title or "").strip()
    if not t or t == _HOSTNAME or t == agent:
        return ""
    # Shell defaults like "ubuntu@host: ~/proj" or a bare path — not a title.
    if "@" in t or t.startswith("/") or t.startswith("~"):
        return ""
    # Strip a leading status glyph/spinner + spaces some agents prepend.
    t = t.lstrip("✳✻✽·*•◐◓◑◒⏳ \t")
    # Collapse whitespace and cap length so the tab stays readable.
    t = " ".join(t.split())
    if not t or t.lower() == agent:
        return ""
    return t[:60]

# Interpreters that hide the real program (claude/codex/grok all run as `node`).
# Mirrors the shell case: node|node[0-9]*|deno|bun|python|python[0-9.]*|ruby|uv|tsx
_INTERP_RE = re.compile(
    r"^(node|node[0-9].*|deno|bun|python|python[0-9.].*|ruby|uv|tsx)$")
_AGENTS = ("claude", "codex", "grok", "aider", "goose", "amp", "opencode",
           "gemini", "cursor")
_AGENTS_SET = frozenset(_AGENTS)


def roster_format_line(idx, active, name, container, cwd, worktree, pbranch,
                       rroot, display, isrepo):
    """The exact tabs.txt line (10 TAB-separated fields, no trailing newline).

    Matches the shell printf:
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
            "$idx" "$active" "$name" "$container" "$cwd" \\
            "$worktree" "$pbranch" "$rroot" "$display" "$isrepo"
    """
    return "\t".join((idx, active, name, container, cwd, worktree, pbranch,
                      rroot, display, isrepo))


def _foreground_script(tty):
    """First non-flag arg of the tty's FOREGROUND process (STAT has '+') — the
    script an interpreter runs. Mirrors:
        ps -ww -t <tty> -o stat=,args= |
        awk '$1 ~ /[+]/ {for(i=3;i<=NF;i++) if($i !~ /^-/){print $i; exit}}'
    """
    dev = tty[len("/dev/"):] if tty.startswith("/dev/") else tty
    out = _capture(["ps", "-ww", "-t", dev, "-o", "stat=,args="])
    for line in out.splitlines():
        toks = line.split()
        if not toks:
            continue
        if "+" in toks[0]:
            for tk in toks[2:]:
                if not tk.startswith("-"):
                    return tk
    return ""


def _resolve_tab_name(label, cmd, tty, pane_title=""):
    """Resolve a window's tab label (port of the roster shell name logic).

    1. explicit @label wins;
    2. else the foreground command, but map an interpreter (node/python/…) to
       the agent script it runs (claude/codex/grok/…);
    3. an agent tab with a real session title shows "<title> (<agent>)";
    4. an absolute-path name falls back to "shell".
    """
    name = label
    resolved_agent = ""
    if not name:
        name = cmd
        if _INTERP_RE.match(cmd):
            script = _foreground_script(tty)
            prog = script.rsplit("/", 1)[-1]
            prog = prog.split(".", 1)[0]
            if prog in _AGENTS_SET:
                name = prog
            else:
                for ag in _AGENTS:
                    if ag in script:
                        name = ag
                        break
        if name in _AGENTS_SET:
            resolved_agent = name
    elif name in _AGENTS_SET:
        resolved_agent = name
    # Agent tab with a real OSC-2 title → "Refactor website (claude)".
    if resolved_agent:
        title = _agent_title(pane_title, resolved_agent)
        if title:
            return "%s (%s)" % (title, resolved_agent)
    if name.startswith("/"):
        name = "shell"
    return name


def _git_toplevel(cwd):
    """`timeout 3 git -C cwd rev-parse --show-toplevel`, '' on failure/timeout.
    The 3s cap keeps a hung git on a virtiofs repo from stalling the roster."""
    try:
        p = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3)
        return p.stdout.strip()
    except Exception:
        return ""


_ROSTER_LOCK = threading.Lock()

# ── stuck mouse-tracking heal ────────────────────────────────────────────────
# A TUI that dies uncleanly (SIGKILL, crash, lost connection) never sends the
# DECSET resets, so tmux keeps the pane's mouse-tracking mode on and forwards
# the host terminal's mouse reports into the pane — where the now-foreground
# shell echoes them as escape garbage on every mouse move. When a plain shell
# is in the foreground but a tracking mode is still set, write the resets to
# the pane tty ourselves: tmux parses pane output no matter who wrote it, so
# this clears the pane's modes and propagates the disable out to the host
# surface without touching the screen (unlike `send-keys -R`). Requires two
# consecutive roster sightings (~1.4s) so it can't race a TUI mid-startup
# that has enabled the mouse before tmux reports it as the foreground command.
_PLAIN_SHELLS = frozenset(("bash", "zsh", "fish", "sh", "dash", "ash"))
_MOUSE_RESET = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l"
_stuck_mouse = {}  # pane tty → consecutive stuck sightings


def _heal_stuck_mouse(tty, cmd, mouse_any):
    """One roster row's stuck-mouse check; see the block comment above."""
    if (mouse_any != "1" or cmd.lstrip("-") not in _PLAIN_SHELLS
            or not tty.startswith("/dev/")):
        _stuck_mouse.pop(tty, None)
        return
    if _stuck_mouse.get(tty, 0) < 1:
        _stuck_mouse[tty] = 1
        return
    _stuck_mouse.pop(tty, None)
    try:
        with open(tty, "wb", buffering=0) as f:
            f.write(_MOUSE_RESET)
        log("roster", "cleared stuck mouse-tracking on", tty)
    except OSError:
        pass


def publish_roster():
    """Build and atomically publish the window list to tabs.txt. Safe to call
    from both the roster loop (periodic) and the command loop (immediately
    after a tab-mutating command, so a new/closed tab shows up without waiting
    for the next 0.7s tick). The lock serializes the shared .tabs.tmp writer."""
    with _ROSTER_LOCK:
        p = _tmux("list-windows", "-t", TMUX_S, "-F", _ROSTER_FMT)
        if p.returncode == 0:
            out_lines = []
            seen_ttys = set()
            for raw in p.stdout.splitlines():
                cols = raw.split("\t", 12)
                while len(cols) < 13:
                    cols.append("")
                (idx, active, cmd, tty, label, container, cwd, worktree,
                 pbranch, rroot, display, mouse_any, pane_title) = cols[:13]
                if not idx:
                    continue
                seen_ttys.add(tty)
                _heal_stuck_mouse(tty, cmd, mouse_any)
                name = _resolve_tab_name(label, cmd, tty, pane_title)
                # Is the cwd inside a git repo? Gates the "New worktree" menu
                # host-side. Skip for worktree tabs (known repos) and empty cwds.
                isrepo = ""
                if cwd and not worktree:
                    isrepo = _git_toplevel(cwd)
                out_lines.append(roster_format_line(
                    idx, active, name, container, cwd, worktree, pbranch,
                    rroot, display, isrepo))
                # A repo tab is active → restore its worktree tabs if a reboot
                # wiped them (self-guards; once per boot per repo).
                if isrepo:
                    _restore_worktrees(isrepo, os.path.basename(isrepo))
            for gone in [t for t in _stuck_mouse if t not in seen_ttys]:
                _stuck_mouse.pop(gone, None)
            content = "".join(line + "\n" for line in out_lines)
            _atomic_publish(".tabs.tmp", "tabs.txt", content)
        elif not _has_session():
            # list-windows failed AND the session is genuinely gone — the user
            # closed the last window. Mark a pending reboot FIRST (host drains it
            # on its fast tick), then publish an EMPTY roster so the host's
            # applyTabList([]) runs the close action.
            signal_reboot_if_pending()
            _atomic_publish(".tabs.tmp", "tabs.txt", "")


def roster_loop_service():
    """Every 0.7s publish the window list atomically to tabs.txt. (Tab-mutating
    commands also publish immediately via publish_roster(), so this tick is the
    catch-all for changes the host didn't drive — e.g. a program the agent ran
    that opened its own window.)"""
    while _RUNNING.is_set():
        # Catch a reboot the moment systemd queues its job (within one tick of
        # the user typing `reboot`, while dbus is still alive).
        signal_reboot_if_pending()
        publish_roster()
        time.sleep(0.7)


# ── vitals loops (vmstat / ports / docker), published to the outbox ──────────
def vmstat_loop_service():
    """Aggregate CPU% / mem / load / disk → vmstat.txt every 1.5s."""
    prev_idle = 0
    prev_total = 0
    while _RUNNING.is_set():
        u = n = s = idle = iow = irq = sirq = steal = 0
        try:
            with open("/proc/stat", "r") as f:
                first = f.readline().split()
            vals = [int(x) for x in first[1:9]]
            while len(vals) < 8:
                vals.append(0)
            u, n, s, idle, iow, irq, sirq, steal = vals[:8]
        except Exception:
            pass
        total = u + n + s + idle + iow + irq + sirq + steal
        didle = idle - prev_idle
        dtotal = total - prev_total
        cpu = 0
        if dtotal > 0:
            cpu = (100 * (dtotal - didle)) // dtotal
        prev_idle = idle
        prev_total = total
        memtotal = 0
        memavail = 0
        try:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        memtotal = int(line.split()[1])
                    elif line.startswith("MemAvailable:"):
                        memavail = int(line.split()[1])
        except Exception:
            pass
        memused = memtotal - memavail
        load = "0"
        try:
            with open("/proc/loadavg", "r") as f:
                load = f.read().split(" ")[0] or "0"
        except Exception:
            pass
        diskused = "0"
        disktotal = "0"
        dfout = _capture(["df", "-kP", "/"])
        rows = dfout.splitlines()
        if len(rows) >= 2:
            cells = rows[1].split()
            if len(cells) >= 3:
                disktotal = cells[1]
                diskused = cells[2]
        content = ("cpu %s\nmem_used_kb %s\nmem_total_kb %s\nload %s\n"
                   "disk_used_kb %s\ndisk_total_kb %s\n"
                   % (cpu, memused, memtotal, load, diskused, disktotal))
        _atomic_publish(".vmstat.tmp", "vmstat.txt", content)
        time.sleep(1.5)


def ports_loop_service():
    """Listening sockets → ports.txt every 3s (`ss -tulnpH`, sudo if possible).

    Mirrors `{ sudo -n ss -tulnpH || ss -tulnH; }`: the unprivileged snapshot
    (no process names) is used only when the sudo variant actually fails."""
    while _RUNNING.is_set():
        try:
            p = subprocess.run(["sudo", "-n", "ss", "-tulnpH"],
                               capture_output=True, text=True)
            out = p.stdout if p.returncode == 0 else _capture(["ss", "-tulnH"])
        except Exception:
            out = _capture(["ss", "-tulnH"])
        _atomic_publish(".ports.tmp", "ports.txt", out)
        time.sleep(3)


def docker_loop_service():
    """Container list (NDJSON) → docker.txt every 2s; gated dashboard extras."""
    while _RUNNING.is_set():
        out = _capture(["docker", "ps", "-a", "--no-trunc",
                        "--format", "{{json .}}"])
        _atomic_publish(".docker.tmp", "docker.txt", out)
        if os.path.exists(os.path.join(OUTBOX, ".docker-watch")):
            s = _capture(["docker", "stats", "--no-stream",
                          "--format", "{{json .}}"])
            if s:
                _atomic_publish(".docker-stats.tmp", "docker-stats.txt", s)
            i = _capture(["docker", "images", "--format", "{{json .}}"])
            if i:
                _atomic_publish(".docker-images.tmp", "docker-images.txt", i)
            # binfmt_misc: which qemu interpreters are registered AND enabled.
            b = ""
            for qf in sorted(glob.glob("/proc/sys/fs/binfmt_misc/qemu-*")):
                try:
                    with open(qf, "r") as f:
                        head = f.readline()
                except OSError:
                    continue
                if head.startswith("enabled"):
                    b += " " + os.path.basename(qf)[len("qemu-"):]
            _atomic_publish(".docker-binfmt.tmp", "docker-binfmt.txt",
                            b[1:] if b.startswith(" ") else b)
            # Per-running-container architecture: one "id<TAB>arch" line each.
            a = ""
            for cid in _capture(["docker", "ps", "-q"]).split():
                img = _capture(
                    ["docker", "inspect", "--format", "{{.Image}}", cid]).strip()
                ar = _capture(
                    ["docker", "image", "inspect", "--format",
                     "{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}",
                     img]).strip()
                a += "%s\t%s\n" % (cid, ar)
            _atomic_publish(".docker-arch.tmp", "docker-arch.txt", a)
        time.sleep(2)


# ── docker command windows / lifecycle ──────────────────────────────────────
def _docker_attach_label_loop(win, cid):
    """Label a docker-attach tab with the container's FOREGROUND process."""
    while _tmux_ok("list-panes", "-t", win):
        out = _capture(["docker", "top", cid, "-eo", "stat,comm"])
        fg = ""
        for line in out.splitlines()[1:]:
            toks = line.split()
            if len(toks) >= 2 and "+" in toks[0]:
                fg = toks[1]
        if fg:
            _set_window_option(win, "@label", fg)
        time.sleep(2)


def _docker_attach(arg):
    cid, sh = _sp(arg)
    if sh == arg:   # no shell provided → default sh
        sh = "sh"
    cmd = ("docker exec -it %s %s || { echo; echo bromure: attach failed. is %s"
           " in this container -- try shell sh; echo Press Enter to close; "
           "read _; }" % (cid, sh, sh))
    win = _new_window(command=cmd)
    if win:
        _set_window_option(win, "@container", cid)
        _set_window_option(win, "@label", sh)
        threading.Thread(target=_docker_attach_label_loop, args=(win, cid),
                         daemon=True).start()


def _docker_logs(arg):
    cid = arg
    cmd = ("docker logs -f %s; echo; echo bromure: log stream ended -- press "
           "Enter to close; read _" % cid)
    win = _new_window(command=cmd)
    if win:
        _set_window_option(win, "@container", cid)
        _set_window_option(win, "@label", "Logs")


def _docker_simple(op_args, arg):
    """docker start/stop/remove: run, surface stderr to the host on failure."""
    p = subprocess.run(["docker"] + op_args + [arg], capture_output=True,
                       text=True)
    if p.returncode != 0:
        docker_err(p.stderr)


def _docker_binfmt(enable):
    if enable:
        try:
            open(os.path.join(os.path.expanduser("~"),
                              ".bromure-binfmt-enabled"), "w").close()
        except OSError:
            pass
        p = subprocess.run(
            ["docker", "run", "--privileged", "--rm", "tonistiigi/binfmt",
             "--install", "all"], capture_output=True, text=True)
    else:
        try:
            os.unlink(os.path.join(os.path.expanduser("~"),
                                   ".bromure-binfmt-enabled"))
        except OSError:
            pass
        p = subprocess.run(
            ["docker", "run", "--privileged", "--rm", "tonistiigi/binfmt",
             "--uninstall", "qemu-*"], capture_output=True, text=True)
    if p.returncode != 0:
        docker_err(p.stderr)


_PROXY_ENV_LINES = (
    'http_proxy=http://host.docker.internal:8080',
    'https_proxy=http://host.docker.internal:8080',
    'HTTP_PROXY=http://host.docker.internal:8080',
    'HTTPS_PROXY=http://host.docker.internal:8080',
    'no_proxy=localhost,127.0.0.1,::1',
    'NO_PROXY=localhost,127.0.0.1,::1',
    'NODE_EXTRA_CA_CERTS=/etc/ssl/certs/bromure-ca.pem',
    'REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt',
    'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt',
    'CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt',
    'GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt',
    'PIP_CERT=/etc/ssl/certs/ca-certificates.crt',
    'AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt',
)

_ENV_EXTRACT_CMD = (
    "timeout 5 env -i PATH=/usr/bin:/bin bash -c "
    "'[ -r /mnt/bromure-meta/api_key.env ] && "
    ". /mnt/bromure-meta/api_key.env 2>/dev/null; env' 2>/dev/null "
    "| grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "
    "| grep -vE '^(PATH|PWD|SHLVL|_|SHELL|HOME|HOSTNAME)='")


def _docker_run(arg):
    """Launch a container with host-injected env/proxy forwarding.

    arg = "<mode> <it> <tag> <img> <full docker run …>" where
    mode ∈ none|env|proxy|both selects which host-injected env to forward.
    """
    rmode, rrest = _sp(arg)
    rit, rrest2 = _sp(rrest)
    rtag, rrest3 = _sp(rrest2)
    rimg, rcmd = _sp(rrest3)

    ef = None
    extra = ""
    # env/both: forward the host-injected TOKENS (dynamic fakes) from api_key.env.
    if rmode in ("env", "both"):
        fd, ef = tempfile.mkstemp()
        os.close(fd)
        extracted = _capture(["bash", "-c", _ENV_EXTRACT_CMD])
        try:
            with open(ef, "a") as f:
                f.write(extracted)
        except OSError:
            pass
    # proxy/both: route through the VM's MITM proxy + trust the MITM CA.
    if rmode in ("proxy", "both"):
        if ef is None:
            fd, ef = tempfile.mkstemp()
            os.close(fd)
        try:
            with open(ef, "a") as f:
                for ln in _PROXY_ENV_LINES:
                    f.write(ln + "\n")
        except OSError:
            pass
        extra = extra + " --add-host=host.docker.internal:host-gateway"
        if os.access("/etc/ssl/certs/ca-certificates.crt", os.R_OK):
            extra += (" -v /etc/ssl/certs/ca-certificates.crt:"
                      "/etc/ssl/certs/ca-certificates.crt:ro")
        if os.access("/etc/ssl/certs/bromure-ca.pem", os.R_OK):
            extra += (" -v /etc/ssl/certs/bromure-ca.pem:"
                      "/etc/ssl/certs/bromure-ca.pem:ro")
    if ef:
        extra = "--env-file %s %s" % (ef, extra)

    if extra:
        full = rcmd.replace("docker run ", "docker run " + extra + " ", 1)
    else:
        full = rcmd

    if rit == "1":
        # Interactive (-it): run in a fresh tmux window so the user drives it.
        win = _new_window(command=full)
        if win:
            if rtag != "-":
                _set_window_option(win, "@container", rtag)
        else:
            docker_err("failed to open interactive container")
    else:
        # Detached: if the image isn't local, pull it first + report progress.
        if rimg != "-" and subprocess.run(
                ["docker", "image", "inspect", rimg], stdout=_DEVNULL,
                stderr=_DEVNULL).returncode != 0:
            docker_run_status("pulling", rimg, 0, 0)
            dl = 0
            tot = 0
            try:
                proc = subprocess.Popen(
                    ["docker", "pull", rimg], stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True)
                for pl in proc.stdout:
                    if "Pulling fs layer" in pl:
                        tot += 1
                        docker_run_status("pulling", rimg, dl, tot)
                    elif "Pull complete" in pl:
                        dl += 1
                        docker_run_status("pulling", rimg, dl, tot)
                proc.wait()
            except Exception:
                pass
        docker_run_status("starting", rimg, 0, 0)
        p = subprocess.run(["bash", "-c", full], stdout=_DEVNULL,
                           stderr=subprocess.PIPE, text=True)
        if p.returncode != 0:
            docker_err(p.stderr)
        docker_run_status_clear()
        if ef:
            try:
                os.unlink(ef)
            except OSError:
                pass


# ── command loop: consume cmd-*.txt from the outbox ─────────────────────────
def _bg(target, *args):
    """Run a command handler on a daemon thread (the shell backgrounds these)."""
    threading.Thread(target=target, args=args, daemon=True).start()


def _fields(arg, n):
    """`set -- $arg` then pad to n positional fields (empty when absent)."""
    f = arg.split()
    while len(f) < n:
        f.append("")
    return f


def _dispatch_command(action, arg):
    if action == "new-tab":
        _tmux_ok("new-window", "-t", TMUX_S, "-c", HOME)
    elif action == "select-tab":
        _tmux_ok("select-window", "-t", "%s:%s" % (TMUX_S, arg))
    elif action == "close-tab":
        _tmux_ok("kill-window", "-t", "%s:%s" % (TMUX_S, arg))
    elif action == "worktree-create":
        # Fields 1-4 are base64; field 5 (tool) is passed RAW (matches "$5").
        f = _fields(arg, 5)
        _bg(_worktree_create, _b64d(f[0]), _b64d(f[1]), _b64d(f[2]),
            _b64d(f[3]), f[4])
    elif action == "worktree-merge":
        f = _fields(arg, 5)
        _bg(_worktree_merge, _b64d(f[0]), _b64d(f[1]), _b64d(f[2]),
            _b64d(f[3]), _b64d(f[4]))
    elif action == "worktree-remove":
        f = _fields(arg, 2)
        _bg(_worktree_remove, _b64d(f[0]), _b64d(f[1]))
    elif action == "worktree-resolve":
        f = _fields(arg, 2)
        _bg(_worktree_resolve, _b64d(f[0]), _b64d(f[1]))
    elif action == "worktree-terminal":
        f = _fields(arg, 2)
        _bg(_worktree_terminal, _b64d(f[0]), _b64d(f[1]))
    elif action == "docker-attach":
        _docker_attach(arg)
    elif action == "docker-logs":
        _docker_logs(arg)
    elif action == "docker-start":
        _bg(_docker_simple, ["start"], arg)
    elif action == "docker-stop":
        _bg(_docker_simple, ["stop"], arg)
    elif action == "docker-remove":
        _bg(_docker_simple, ["rm", "-f"], arg)
    elif action == "docker-binfmt":
        _bg(_docker_binfmt, True)
    elif action == "docker-binfmt-off":
        _bg(_docker_binfmt, False)
    elif action == "docker-run":
        _bg(_docker_run, arg)
    elif action == "soft-reboot":
        log("tabs", "soft-reboot triggered (halt → host relaunch)")
        try:
            os.sync()
        except Exception:
            pass
        subprocess.run(["sudo", "poweroff"])
    else:
        log("tabs", "unknown action '%s'" % action)


def command_loop_service():
    """Consume cmd-<action>.txt files from the outbox (port of command_loop)."""
    while _RUNNING.is_set():
        # Gate on the session existing: kitty (here, the startup one-shot)
        # creates it, and a command that races VM boot must wait, not fail.
        if os.path.isdir(OUTBOX) and _has_session():
            for f in sorted(glob.glob(os.path.join(OUTBOX, "cmd-*.txt"))):
                if not os.path.exists(f):
                    continue
                try:
                    with open(f, "r") as fh:
                        line = fh.readline()
                    if line.endswith("\n"):
                        line = line[:-1]
                except OSError:
                    line = ""
                try:
                    os.remove(f)
                except OSError:
                    pass
                action, arg = _sp(line)
                log("tabs", "got cmd action=%s arg=%s" % (action, arg))
                try:
                    _dispatch_command(action, arg)
                except Exception:
                    log("tabs", "command %s failed:\n%s"
                        % (action, traceback.format_exc()))
                # Publish immediately so the new/closed/renamed tab reaches the
                # host now, not up to 0.7s later on the next roster tick.
                try:
                    publish_roster()
                except Exception:
                    pass
        time.sleep(0.1)


# ── session lifecycle ───────────────────────────────────────────────────────
def create_session():
    """Create the single tmux session the tabs live in (startup one-shot)."""
    _tmux_ok("new-session", "-d", "-s", TMUX_S, "-c", HOME)
    _tmux_ok("set-option", "-g", "allow-passthrough", "on")
    _tmux_ok("set-option", "-s", "set-clipboard", "on")
    # Wheel-scroll bridge. The attached client keeps the host surface in the
    # alternate screen, so ghostty has no scrollback of its own and would
    # fake arrow keys for wheel ticks (= shell history at a prompt). Instead
    # the host injects one of these private sequences per wheel line (see
    # TerminalSurfaceView.scrollWheel) and we scroll tmux history via
    # copy-mode. A pane running its own alt-screen app (vim, less) gets real
    # arrow keys — same split tmux's native wheel handling makes. Bound in
    # both copy-mode tables so vi mode-keys keeps scrolling. Re-run on every
    # daemon start, so a restart refreshes a live session's bindings.
    _tmux_ok("set-option", "-s", "user-keys[0]", "\x1b[1000001~")
    _tmux_ok("set-option", "-s", "user-keys[1]", "\x1b[1000002~")
    _tmux_ok("bind-key", "-n", "User0", "if", "-F", "#{alternate_on}",
             "send-keys Up", "copy-mode -e ; send-keys -X scroll-up")
    _tmux_ok("bind-key", "-n", "User1", "if", "-F", "#{alternate_on}",
             "send-keys Down")
    for table in ("copy-mode", "copy-mode-vi"):
        _tmux_ok("bind-key", "-T", table, "User0", "send-keys", "-X", "scroll-up")
        _tmux_ok("bind-key", "-T", table, "User1", "send-keys", "-X", "scroll-down")


def session_monitor_service():
    """Watch the tmux session; when it dies (user closed the last window, or the
    OS is rebooting) poweroff — VZ guestDidStop fires and the host decides
    relaunch (reboot marker) vs teardown. Mirrors the kitty foreground's
    post-exit `signal_reboot_if_pending; poweroff`."""
    seen = False
    while _RUNNING.is_set():
        if _has_session():
            seen = True
        elif seen:
            signal_reboot_if_pending()
            log("tabs", "session over — powering off")
            try:
                os.sync()
            except Exception:
                pass
            subprocess.run(["sudo", "poweroff"])
            _RUNNING.clear()
            return
        time.sleep(0.7)


# ─────────────────── §9 Session tasks (one-shot + long-lived) ───────────────
# Ported from xinitrcContent, keep-marked blocks only. Everything X-related
# (xset/xsetroot/openbox/spice/xrandr/LIBGL) is dropped.
DOCKER_PROXY_FRAGMENT = (
    "# Managed by Bromure Agentic Coding — rewritten on every launch.\n"
    "[Service]\n"
    'Environment="HTTP_PROXY=http://127.0.0.1:8080"\n'
    'Environment="HTTPS_PROXY=http://127.0.0.1:8080"\n'
    'Environment="NO_PROXY=localhost,127.0.0.1,::1"\n')


def _sudo(args, **kw):
    """subprocess.run(["sudo", *args]) with output silenced."""
    return subprocess.run(["sudo"] + list(args), stdout=_DEVNULL,
                          stderr=_DEVNULL, **kw)


def task_set_mtu():
    """Lower the primary NIC's MTU (VZ NAT reports 1500 but the real path can be
    smaller; PMTUD doesn't always recover). Default 1280, host-overridable via
    /mnt/bromure-meta/mtu."""
    mtu = "1280"
    try:
        with open(os.path.join(META, "mtu")) as f:
            digits = "".join(c for c in f.read() if c.isdigit())
        if digits:
            mtu = digits
    except OSError:
        pass
    if not mtu:
        mtu = "1280"
    nic = ""
    for line in _capture(["ip", "route", "show", "default"]).splitlines():
        if "default" in line:
            parts = line.split()
            if len(parts) >= 5:
                nic = parts[4]   # awk '/default/ {print $5; exit}'
            break
    if nic:
        _sudo(["ip", "link", "set", "dev", nic, "mtu", mtu])
        log("session", "set %s mtu %s" % (nic, mtu))


def task_install_ca():
    """Install the host's MITM CA into the system trust store so every TLS
    client in the VM trusts the forged per-host leaves the proxy presents."""
    pem = os.path.join(META, "bromure-ca.pem")
    if not os.access(pem, os.R_OK):
        return
    _sudo(["install", "-m", "0644", pem,
           "/usr/local/share/ca-certificates/bromure-ca.crt"])
    _sudo(["update-ca-certificates"])
    # node respects NODE_EXTRA_CA_CERTS pointing at the raw PEM.
    _sudo(["install", "-m", "0644", pem, "/etc/ssl/certs/bromure-ca.pem"])
    log("session", "installed MITM CA")


def task_apt_and_docker_proxy():
    """Drop stale bake-time apt proxy config; wire dockerd through the bridge
    (proxy env + freshly installed CA) and restart it."""
    stale = "/etc/apt/apt.conf.d/99-bromure-proxy"
    if os.path.isfile(stale):
        _sudo(["rm", "-f", stale])
        log("session", "removed stale bake-time apt proxy config")
    if not shutil.which("docker"):
        return
    _sudo(["mkdir", "-p", "/etc/systemd/system/docker.service.d"])
    try:
        subprocess.run(
            ["sudo", "tee",
             "/etc/systemd/system/docker.service.d/bromure-proxy.conf"],
            input=DOCKER_PROXY_FRAGMENT, text=True, stdout=_DEVNULL,
            stderr=_DEVNULL)
    except Exception:
        return
    _sudo(["systemctl", "daemon-reload"])
    if _sudo(["systemctl", "restart", "docker"]).returncode == 0:
        log("session", "docker restarted with bromure proxy + CA")
    else:
        log("session", "docker restart failed (non-fatal)")


def task_set_timezone():
    """Match macOS's timezone at session start (host writes /mnt/bromure-meta/tz)."""
    tzfile = os.path.join(META, "tz")
    if not os.access(tzfile, os.R_OK):
        return
    try:
        with open(tzfile) as f:
            tzid = f.readline().strip()
    except OSError:
        return
    if not tzid:
        return
    if not os.path.exists("/usr/share/zoneinfo/" + tzid):
        return
    if _sudo(["timedatectl", "set-timezone", tzid]).returncode != 0:
        _sudo(["ln", "-sf", "/usr/share/zoneinfo/" + tzid, "/etc/localtime"])
    os.environ["TZ"] = tzid
    log("session", "timezone set to " + tzid)


def task_folder_shares():
    """Materialize per-profile folder shares as ~/<basename> symlinks. Each
    /mnt/bromure-meta/shares.txt entry is "<slot-index> <basename>"; the slot is
    mounted at /mnt/bromure-share-<N>. Sweep stale share symlinks first."""
    home = os.path.expanduser("~")
    # Sweep any top-level symlink pointing at a share slot (precise: only
    # /mnt/bromure-share-* targets, like the shell's `find -lname`).
    try:
        for entry in os.listdir(home):
            full = os.path.join(home, entry)
            if os.path.islink(full):
                try:
                    tgt = os.readlink(full)
                except OSError:
                    continue
                if tgt.startswith("/mnt/bromure-share-"):
                    try:
                        os.unlink(full)
                    except OSError:
                        pass
    except OSError:
        pass
    sharesfile = os.path.join(META, "shares.txt")
    if not os.access(sharesfile, os.R_OK):
        return
    try:
        with open(sharesfile) as f:
            lines = f.read().splitlines()
    except OSError:
        return
    for line in lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        idx, name = parts[0], parts[1]
        if not idx or not name:
            continue
        src = "/mnt/bromure-share-" + idx
        dst = os.path.join(home, name)
        if os.path.isdir(src) and not os.path.exists(dst):
            try:
                os.symlink(src, dst)
                log("session", "symlinked ~/%s → %s" % (name, src))
            except OSError:
                log("session", "FAILED ln -s for ~/%s" % name)


def task_reapply_binfmt():
    """Re-apply cross-arch emulation if enabled in a prior session. binfmt_misc
    registrations are wiped on reboot; the tonistiigi/binfmt image is cached, so
    re-running is fast + offline. Runs after dockerd is up so it never delays
    the session (one-shot background thread, not supervised)."""
    marker = os.path.join(os.path.expanduser("~"), ".bromure-binfmt-enabled")
    if not os.path.isfile(marker) or not shutil.which("docker"):
        return
    for _ in range(30):
        if subprocess.run(["docker", "info"], stdout=_DEVNULL,
                          stderr=_DEVNULL).returncode == 0:
            break
        time.sleep(1)
    if subprocess.run(
            ["docker", "run", "--privileged", "--rm", "tonistiigi/binfmt",
             "--install", "all"], stdout=_DEVNULL,
            stderr=_DEVNULL).returncode == 0:
        log("session", "re-applied binfmt emulation")


def resume_watcher_service():
    """Resume-time clock resync: VZ freezes CLOCK_REALTIME during
    saveMachineState, so on resume the wall clock lags until timesyncd notices.
    The host writes the current Unix ts into /mnt/bromure-meta/.resume-signal
    right after vm.resume(); on change we set the clock. Polling (not inotify):
    virtiofs doesn't reliably deliver inotify for host-side writes. Absorbs both
    the old root systemd watcher and the spice respawner (spice is gone)."""
    signal_path = os.path.join(META, ".resume-signal")
    # Skip whatever stale value is present at start — only react to *changes*.
    last = ""
    try:
        with open(signal_path) as f:
            last = f.read().strip()
    except OSError:
        pass
    while _RUNNING.is_set():
        ts = ""
        try:
            with open(signal_path) as f:
                ts = f.read().strip()
        except OSError:
            ts = ""
        if ts and ts != last:
            if ts.isdigit():
                _sudo(["date", "-u", "-s", "@" + ts])
                log("resume", "clock set (target ts=%s)" % ts)
            else:
                log("resume", "signal not numeric: %r" % ts)
            last = ts
        time.sleep(2)


def ip_reporter_service():
    """Every 5s write the primary IPv4 to the outbox (host surfaces it)."""
    ippath = os.path.join(OUTBOX, "ip.txt")
    while _RUNNING.is_set():
        out = _capture(["hostname", "-I"])
        ip = out.split()[0] if out.split() else ""
        if ip:
            try:
                with open(ippath, "w") as f:
                    f.write(ip + "\n")
            except OSError:
                pass
        time.sleep(5)


# ─────────────────────────────── §10 main() ────────────────────────────────
def _on_signal(signum, frame):
    """Stop the world. Registered ONLY on the main thread (signal.signal is
    main-thread-only) — never inside an absorbed service."""
    _RUNNING.clear()


def _run_once(name, fn):
    """Run a one-shot startup task; log and swallow any failure (non-fatal)."""
    try:
        fn()
    except Exception:
        log("session", "one-shot '%s' failed:\n%s"
            % (name, traceback.format_exc()))


def main():
    # 1. Parse env / basic setup.
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    compute_self_hash()
    log("agentd", "starting (pid %d, python %s, self %s)"
        % (os.getpid(), sys.version.split()[0],
           (SELF_HASH[:8] if SELF_HASH else "?")))

    # Truncate the vm-bridge log on each run (the original bridge did this).
    try:
        open(BRIDGE_LOG_PATH, "w").close()
    except OSError:
        pass

    # 2. One-shot session tasks (each isolated; a failure never aborts boot).
    _run_once("mtu", task_set_mtu)
    _run_once("ca", task_install_ca)
    _run_once("docker-proxy", task_apt_and_docker_proxy)
    _run_once("timezone", task_set_timezone)
    _run_once("folder-shares", task_folder_shares)
    _run_once("session", create_session)

    # One-shot background jobs (fire-and-forget, not supervised).
    threading.Thread(target=task_reapply_binfmt, daemon=True).start()

    # 3. Supervised services — each isolated so one crash never kills the process.
    services = [
        ("shell", shell_agent_service),
        ("http-proxy", bridge_http_proxy_service),
        ("ssh-agent", bridge_ssh_agent_service),
        ("aws-creds", bridge_aws_creds_service),
        ("llm-engine", bridge_llm_engine_service),
        ("claude-token", claude_token_service),
        ("codex-token", codex_token_service),
        ("loopback-relay", loopback_relay_service),
        ("roster", roster_loop_service),
        ("vmstat", vmstat_loop_service),
        ("ports", ports_loop_service),
        ("docker", docker_loop_service),
        ("command", command_loop_service),
        ("resume", resume_watcher_service),
        ("ip", ip_reporter_service),
        ("session-monitor", session_monitor_service),
        ("upgrade", upgrade_watcher),
    ]
    for name, fn in services:
        start_service(name, fn)

    log("agentd", "%d services started; supervising" % len(services))

    # 4. Supervise forever (daemon threads die with the process on exit).
    while _RUNNING.is_set():
        time.sleep(1)

    log("agentd", "shutting down")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception:
        log("agentd", "fatal:\n" + traceback.format_exc())
        raise
