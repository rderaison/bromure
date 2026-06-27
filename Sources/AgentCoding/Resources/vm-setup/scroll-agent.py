#!/usr/bin/python3 -u
"""Bromure scroll agent — scrolls the tmux scrollback in response to the
host's trackpad.

The terminal is kitty attached to a single tmux session ("bromure"), with
tmux's own mouse mode deliberately OFF so kitty keeps owning click-drag
selection + ⌘C. That means the wheel can't go through the normal mouse
path (kitty would translate it to arrow keys via `alternate_scroll`, which
just walks shell history). Instead the host consumes the wheel and streams
us coalesced line deltas; we drive tmux copy-mode directly via the CLI.

Listens on vsock port 5008. The host's `ScrollBridge` opens one persistent
connection and writes newline-delimited batches:

    up <n>\n      # scroll the scrollback up   N lines (into history)
    down <n>\n    # scroll the scrollback down N lines (toward live)

"up" enters copy-mode (with -e, so scrolling back to the bottom exits it
automatically) and scrolls back; "down" scrolls toward the live prompt and
is a no-op when not already in copy-mode. Everything targets the active
pane of the session, so it follows whichever tab is focused.
"""

import socket
import subprocess
import sys
import time

VSOCK_PORT = 5008
TMUX_SESSION = "bromure"


def _tmux(*args, capture=False):
    """Run a tmux command against the user's default server. The agent runs
    as the same user that owns the tmux server (both are the X session
    user), so the default socket resolves without TMUX set."""
    try:
        return subprocess.run(
            ["tmux", *args],
            capture_output=True, text=True, timeout=2,
        )
    except Exception as e:  # tmux missing / server down / timeout
        if not capture:
            print(f"scroll-agent: tmux {args[0] if args else ''} failed: {e}",
                  file=sys.stderr)
        return None


def _in_copy_mode():
    r = _tmux("display-message", "-p", "-t", TMUX_SESSION,
              "#{pane_in_mode}", capture=True)
    return bool(r) and r.returncode == 0 and r.stdout.strip() == "1"


def scroll(direction, n):
    n = max(1, min(n, 200))
    if direction == "up":
        # Enter copy-mode only if we're not already scrolling — re-entering
        # would not reset the position, but the extra call is wasteful, so
        # skip it when we know we're already in a mode.
        if not _in_copy_mode():
            _tmux("copy-mode", "-e", "-t", TMUX_SESSION)
        _tmux("send-keys", "-X", "-t", TMUX_SESSION, "-N", str(n), "scroll-up")
    elif direction == "down":
        # Only meaningful while in copy-mode; ignore otherwise so a stray
        # scroll-down at the live prompt does nothing.
        if _in_copy_mode():
            _tmux("send-keys", "-X", "-t", TMUX_SESSION, "-N", str(n), "scroll-down")


def handle_line(line):
    parts = line.split()
    if len(parts) != 2:
        return
    direction, count = parts
    if direction not in ("up", "down"):
        return
    try:
        n = int(count)
    except ValueError:
        return
    scroll(direction, n)


def serve_conn(conn):
    """Read newline-delimited scroll batches off one persistent connection
    until the host hangs up."""
    buf = b""
    while True:
        try:
            chunk = conn.recv(256)
        except OSError:
            break
        if not chunk:
            break  # host closed the connection
        buf += chunk
        # Cap buffering so a wedged/garbage stream can't grow unbounded.
        if len(buf) > 4096:
            buf = buf[-256:]
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            handle_line(raw.decode("utf-8", errors="ignore"))


def main():
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
            s.listen(8)
            while True:
                conn, _ = s.accept()
                try:
                    serve_conn(conn)
                finally:
                    conn.close()
        except Exception as e:
            print(f"scroll-agent: error: {e}", file=sys.stderr)
            time.sleep(1)


if __name__ == "__main__":
    main()
