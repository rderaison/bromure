#!/usr/bin/python3 -u
"""Bromure shell agent — runs inside the guest VM.

Provides remote shell execution from the host over vsock port 5800.
Uses length-prefixed JSON protocol:
  Request:  [u32be len][{"cmd": "...", "timeout": 30}]
  Response: [u32be len][{"stdout": "...", "stderr": "...", "exit_code": 0}]

Interactive requests ({"interactive": true, "cols": N, "rows": N}) switch the
connection to the framed pty protocol (see below). Two flavors:
  - {"cmd": "..."} — run the command (or a login shell) on a fresh pty.
  - {"view": "<id>", "window": <idx>} — host terminal view: attach a tmux
    session *grouped* with `bromure` (shared windows, independent
    current-window) so N host views can show N different windows at once.
    The view session self-destroys on detach; the real windows are untouched.

Guest-initiated connection pool pattern (same as cdp-agent.py):
  1. Opens N vsock connections to the host proactively.
  2. When the host sends a command, this agent executes it.
  3. After each command, a replacement connection is opened.

Started from xinitrc whenever the script is staged in the meta share (always,
now that `exec` is a first-class CLI verb gated by the host's control socket).
"""

import errno
import fcntl
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
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


# Interactive PTY framing (both directions):
#   [1 byte type][4 byte BE length][payload]
#   type 0 = data (raw tty bytes), 1 = resize (payload: u16be cols, u16be rows),
#   2 = exit (guest→host; payload: i32be exit code), 3 = stdin EOF (host→guest).
FRAME_DATA = 0
FRAME_RESIZE = 1
FRAME_EXIT = 2
FRAME_EOF = 3


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
    independent current-window) — two clients on the same session would
    mirror one active window, which is exactly what a grid must not do.
    destroy-unattached reaps the view session when the host detaches; the
    grouped windows (the real tabs) are untouched. status goes off because
    the host draws its own chrome; allow-passthrough lets kitty-graphics
    escape tmux for hosts that render it.
    """
    name = "view-" + re.sub(r"[^A-Za-z0-9-]", "", str(view))[:32]
    if name == "view-":
        name = "view-" + os.urandom(4).hex()
    tmux = (
        "exec tmux"
        " set-option -g allow-passthrough on \\;"
        " set-option -s set-clipboard on \\;"
        " set-window-option -g aggressive-resize on \\;"
        " new-session -t bromure -s " + name + " \\;"
        " set-option destroy-unattached on \\;"
        " set-option status off \\;"
        # mouse OFF: tmux doesn't capture the mouse, so a plain drag is
        # ghostty's own native selection (macOS-like) and the wheel scrolls
        # native scrollback; tmux still forwards mouse to apps that request
        # it (Claude/vim). (Kept in sync with bromure-agentd, which is the
        # live daemon; this file is the pre-consolidation copy.)
        " set-option mouse off"
    )
    if window is not None:
        try:
            tmux += " \\; select-window -t :%d" % int(window)
        except (TypeError, ValueError):
            pass
    # The bromure session normally exists (the boot terminal creates it);
    # cover the race/headless case so the view never lands on an error.
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


def handle_connection(vsock_sock, replenish_fn):
    """Wait for a command from the host, execute it, return the result."""
    replenished = False
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

        # Interactive PTY session (`exec -it`, a tab attach running
        # `tmux attach`, or a host terminal view): allocate a pty, run the
        # command on it, and stream raw bytes framed over the vsock until
        # the child exits.
        if req.get("interactive"):
            # Replenish on claim, not on close: this connection is now held
            # for the life of the terminal session (possibly hours). Without
            # an immediate replacement, N concurrent host terminals would
            # drain the POOL_SIZE idle connections and starve exec/roster
            # traffic for the whole VM.
            replenished = True
            replenish_fn()
            _run_interactive(vsock_sock, req)
            return  # finally below closes the vsock

        # Source /mnt/bromure-meta/proxy.env before running so the
        # command sees HTTPS_PROXY + the per-language CA bundle
        # paths. .bashrc only sources proxy.env for interactive
        # shells (the `case $- in *i*) return` guard); the shell
        # subprocess.run() spawns below is non-interactive, so
        # without this prefix curl / pip / npm bypass the MITM
        # proxy entirely. That's what the section-10 e2e tests
        # were hitting — the supply-chain branch in HTTPProxy.swift
        # never saw the test traffic.
        wrapped = (
            "if [ -r /mnt/bromure-meta/proxy.env ]; then "
            "set -a; . /mnt/bromure-meta/proxy.env; set +a; "
            "fi; "
            + cmd
        )

        # Execute command
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
        if not replenished:
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
