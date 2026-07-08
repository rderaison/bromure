#!/usr/bin/python3 -u
"""Bromure keyboard agent — applies host commands sent over vsock 5006.

Runs inside the guest VM. The host connects to vsock port 5006 and sends
one short message per connection:

  "clipboard-image"  — publish /mnt/bromure-meta/clipboard.png (just
                       written by the host's ClipboardImageBridge) as the
                       X11 CLIPBOARD selection via xclip, so Claude Code's
                       Ctrl+V image ingestion finds it.
  anything else      — a keyboard layout specification, validated against
                       a strict allowlist and applied with setxkbmap.
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

CLIPBOARD_IMAGE_PATH = "/mnt/bromure-meta/clipboard.png"


def load_clipboard_image():
    """Publish the host-pushed PNG on the X11 CLIPBOARD selection.

    xclip forks a child that owns the selection and serves image/png to
    any requestor (Claude Code reads it back with `xclip -o` on Ctrl+V),
    so run() returns immediately. The child exits on its own when the
    next grab — another xclip, or spice-vdagent syncing a host text
    copy — displaces it, which is also what keeps a stale image from
    shadowing newer text. Fails quietly on images that predate xclip
    (postinstall step not applied yet): the user just gets today's
    text-only paste behavior.
    """
    env = dict(os.environ, DISPLAY=":0")
    try:
        subprocess.run(
            ["xclip", "-selection", "clipboard", "-t", "image/png",
             "-i", CLIPBOARD_IMAGE_PATH],
            env=env, capture_output=True, timeout=5)
        print("keyboard-agent: clipboard image published", file=sys.stderr)
    except Exception as e:
        print(f"keyboard-agent: clipboard image failed: {e}", file=sys.stderr)


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
                    msg = data.decode("utf-8").strip()
                    print(f"keyboard-agent: received {msg!r}", file=sys.stderr)
                    if msg == "clipboard-image":
                        load_clipboard_image()
                    elif msg:
                        apply_layout(msg)
                finally:
                    conn.close()
        except Exception as e:
            print(f"keyboard-agent: error: {e}", file=sys.stderr)
            import time
            time.sleep(1)


if __name__ == "__main__":
    main()
