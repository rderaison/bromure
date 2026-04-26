#!/usr/bin/python3 -u
"""Bromure scroll agent — injects host trackpad/mouse scroll events as
X11 Button4/Button5 clicks via xdotool.

Listens on vsock port 5008. The host's `ScrollBridge` writes one
line per coalesced batch:

    up <n>\n      # scroll up N ticks   → Button4
    down <n>\n    # scroll down N ticks → Button5

xdotool's `click --repeat N` issues the click N times in rapid
succession, which is what kitty / openbox / X11 expect for line-by-
line scrollback navigation.
"""

import os
import socket
import subprocess
import sys

VSOCK_PORT = 5008


def click(button, repeat):
    if button not in ("4", "5"):
        return
    if repeat < 1 or repeat > 200:
        return
    env = dict(os.environ, DISPLAY=":0")
    try:
        subprocess.run(
            ["xdotool", "click", "--repeat", str(repeat), button],
            env=env, capture_output=True, timeout=2,
        )
    except Exception as e:
        print(f"scroll-agent: xdotool failed: {e}", file=sys.stderr)


def handle_line(line):
    parts = line.strip().split()
    if len(parts) != 2:
        return
    direction, count = parts
    try:
        n = int(count)
    except ValueError:
        return
    if direction == "up":
        click("4", n)
    elif direction == "down":
        click("5", n)


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
                    data = conn.recv(64)
                    if data:
                        handle_line(data.decode("utf-8", errors="ignore"))
                finally:
                    conn.close()
        except Exception as e:
            print(f"scroll-agent: error: {e}", file=sys.stderr)
            import time
            time.sleep(1)


if __name__ == "__main__":
    main()
