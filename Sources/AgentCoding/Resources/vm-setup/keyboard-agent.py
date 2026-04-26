#!/usr/bin/python3 -u
"""Bromure keyboard agent — listens for keyboard layout changes from the host.

Runs inside the guest VM. The host connects to vsock port 5006 and sends the
new layout specification. The agent validates it against a strict allowlist
of characters and applies it with setxkbmap.
"""

import os
import re
import socket
import subprocess
import sys

VSOCK_PORT = 5006

# Only allow XKB layout names: letters, digits, dash, underscore, colon (for variant),
# parentheses (for legacy "ch(fr)" format). Max 32 characters.
VALID_LAYOUT = re.compile(r'^[a-zA-Z0-9_:()-]{1,32}$')


KEY_REPEAT_PATH = "/mnt/bromure-meta/key_repeat"


def reapply_key_repeat(env):
    """Re-apply xset r rate after a setxkbmap call.

    setxkbmap rebuilds the X keymap, which resets autorepeat to the
    X server's compile-time defaults (660 ms / 25 Hz on Xorg). Without
    this re-apply, the rate xinitrc sets at boot is silently undone
    the first time the host pushes a layout via KeyboardBridge.
    """
    try:
        with open(KEY_REPEAT_PATH) as f:
            kr = f.read().strip()
    except OSError:
        return
    parts = kr.split()
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        return
    delay, rate = parts
    try:
        subprocess.run(["xset", "r", "rate", delay, rate],
                       env=env, capture_output=True, timeout=2)
    except Exception:
        pass


def apply_layout(layout_spec):
    """Apply a keyboard layout using setxkbmap.

    Formats:
      "us", "fr"         -> setxkbmap <layout>
      "ch:fr"            -> setxkbmap -layout ch -variant fr
    """
    if not VALID_LAYOUT.match(layout_spec):
        print(f"keyboard-agent: rejected invalid layout: {layout_spec!r}", file=sys.stderr)
        return

    env = dict(os.environ, DISPLAY=":0")
    try:
        if ":" in layout_spec:
            layout, variant = layout_spec.split(":", 1)
            cmd = ["setxkbmap", "-layout", layout, "-variant", variant]
        else:
            cmd = ["setxkbmap", layout_spec]
        subprocess.run(cmd, env=env, capture_output=True, timeout=5)
        # Re-apply autorepeat — setxkbmap clobbered it.
        reapply_key_repeat(env)
        print(f"keyboard-agent: layout set to {layout_spec}", file=sys.stderr)
    except Exception as e:
        print(f"keyboard-agent: failed: {e}", file=sys.stderr)


def main():
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
            s.listen(1)

            while True:
                conn, _ = s.accept()
                try:
                    data = conn.recv(256)
                    layout = data.decode("utf-8").strip()
                    if layout:
                        apply_layout(layout)
                finally:
                    conn.close()
        except Exception as e:
            print(f"keyboard-agent: error: {e}", file=sys.stderr)
            import time
            time.sleep(1)


if __name__ == "__main__":
    main()
