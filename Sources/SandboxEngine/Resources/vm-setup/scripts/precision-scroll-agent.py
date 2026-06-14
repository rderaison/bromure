#!/usr/bin/python3 -u
"""Bromure precision-scroll agent — runs inside the guest VM as root.

macOS trackpads report pixel-precise scroll deltas with momentum, but
VZ's virtual USB digitizer only carries discrete wheel clicks — every
two-finger scroll lands in the guest as coarse +/-1 notches and feels
nothing like native scrolling. This agent restores the native feel:
the host intercepts NSEvent's precise deltas (see PrecisionScrollVMView
/ ScrollBridge) and streams them here over vsock; we re-emit them as
REL_WHEEL_HI_RES events through a uinput virtual device, which
libinput / Xorg / Chromium treat exactly like a high-resolution wheel.

Wire format (host -> guest, newline-delimited JSON):
    {"dx": <float host px>, "dy": <float host px>}

Direction: the matching xorg conf (20-bromure-scroll.conf) forces this
device's libinput NaturalScrolling off so its behaviour is fixed
regardless of the global scrolling pref; the agent then negates dy so
macOS natural-scroll deltas reproduce native page direction. See the
serve() loop for the measured sign convention.

Calibration: SCROLL_V120_PER_PX (from chrome-env, default 1.0)
converts host points to hi-res wheel units — 120 units = one notch.
The default targets ~1 host point = 1 guest CSS px. Override via
vm.chromeEnvExtra (e.g. SCROLL_V120_PER_PX=1.2 for faster scrolling).

Threat model: the listener is vsock-only (reachable from the host
process, never from the network or guest userspace without root).
Payload floats are clamped; only wheel axes are ever injected — no
keys, no pointer motion, no buttons.

Started from inittab (root — /dev/uinput requires it).
"""

import fcntl
import json
import os
import socket
import struct
import subprocess
import sys
import time

VSOCK_PORT = 5820

# uinput ioctls (generic _IOC layout, identical on arm64/x86_64)
UI_SET_EVBIT = 0x40045564   # _IOW('U', 100, int)
UI_SET_KEYBIT = 0x40045565  # _IOW('U', 101, int)
UI_SET_RELBIT = 0x40045566  # _IOW('U', 102, int)
UI_DEV_SETUP = 0x405C5503   # _IOW('U', 3, struct uinput_setup[92])
UI_DEV_CREATE = 0x00005501  # _IO('U', 1)

EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
REL_X, REL_Y = 0x00, 0x01
REL_HWHEEL, REL_WHEEL = 0x06, 0x08
REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 0x0B, 0x0C
BTN_LEFT = 0x110
BUS_VIRTUAL = 0x06

# Hi-res wheel units per host point, calibrated empirically: one notch
# is 120 hi-res units and Chromium + libinput net out to ~119 CSS px of
# scroll per notch on this stack (measured: 100 pt input -> 225 px at
# the old 120/53 factor, i.e. 2.25x too fast). 1.0 yields ~1 host point
# = 1 guest CSS px, which matches native macOS trackpad feel. Holds
# across display scales because Chromium divides the device-pixel scroll
# by the device-scale-factor, so CSS-px-per-notch stays ~constant.
DEFAULT_V120_PER_PX = 1.0

# Hard bound per message — a runaway host can't queue absurd jumps.
MAX_PX_PER_EVENT = 4000.0


def log(msg):
    print(f"scroll-agent: {msg}", file=sys.stderr, flush=True)


def create_uinput_device():
    """Create the virtual high-resolution wheel device.

    Declared as a full mouse (buttons + X/Y + wheels) so udev tags it
    ID_INPUT_MOUSE and libinput picks it up as a pointer — but only
    wheel events are ever emitted.
    """
    subprocess.run(["modprobe", "uinput"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    for code in (REL_X, REL_Y, REL_WHEEL, REL_HWHEEL,
                 REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES):
        fcntl.ioctl(fd, UI_SET_RELBIT, code)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)

    # struct uinput_setup: input_id {bus, vendor, product, version} +
    # name[80] + ff_effects_max(u32)
    name = b"Bromure Precision Scroll"
    setup = struct.pack("<HHHH80sI", BUS_VIRTUAL, 0x1D6B, 0x0105, 1,
                        name.ljust(80, b"\0"), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    log("uinput device created")
    return fd


def emit(fd, etype, code, value):
    # struct input_event (64-bit): timeval(16) + type(2) + code(2) + value(4)
    os.write(fd, struct.pack("<qqHHi", 0, 0, etype, code, value))


class WheelAxis:
    """Accumulates fractional hi-res units and legacy detents for one axis."""

    def __init__(self, hi_code, lo_code):
        self.hi_code = hi_code
        self.lo_code = lo_code
        self.hi_acc = 0.0   # fractional hi-res units not yet emitted
        self.lo_acc = 0     # hi-res units emitted since last legacy click

    def push(self, fd, v120_float):
        self.hi_acc += v120_float
        units = int(self.hi_acc)
        if units == 0:
            return False
        self.hi_acc -= units
        emit(fd, EV_REL, self.hi_code, units)
        # Legacy detent every 120 hi-res units for consumers that don't
        # speak hi-res. libinput dedups against the hi-res stream.
        self.lo_acc += units
        clicks = int(self.lo_acc / 120)
        if clicks != 0:
            self.lo_acc -= clicks * 120
            emit(fd, EV_REL, self.lo_code, clicks)
        return True


def serve(fd):
    v120_per_px = DEFAULT_V120_PER_PX
    env_factor = os.environ.get("SCROLL_V120_PER_PX", "")
    try:
        if env_factor:
            v120_per_px = max(0.1, min(20.0, float(env_factor)))
    except ValueError:
        pass
    log(f"v120_per_px={v120_per_px:.4f}")

    vertical = WheelAxis(REL_WHEEL_HI_RES, REL_WHEEL)
    horizontal = WheelAxis(REL_HWHEEL_HI_RES, REL_HWHEEL)

    srv = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    srv.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    srv.listen(1)
    log(f"listening on vsock :{VSOCK_PORT}")

    while True:
        conn, _ = srv.accept()
        log("host connected")
        buf = b""
        try:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        msg = json.loads(line)
                        dx = float(msg.get("dx", 0.0))
                        dy = float(msg.get("dy", 0.0))
                    except (ValueError, TypeError):
                        continue
                    dx = max(-MAX_PX_PER_EVENT, min(MAX_PX_PER_EVENT, dx))
                    dy = max(-MAX_PX_PER_EVENT, min(MAX_PX_PER_EVENT, dy))
                    # Direction (measured on this libinput + Chromium stack
                    # with the device's NaturalScrolling forced off):
                    #   positive REL_WHEEL_HI_RES  -> page scrolls DOWN.
                    #   positive REL_HWHEEL_HI_RES -> page scrolls RIGHT.
                    # macOS scrollingDeltaY needs negating to match native
                    # feel; scrollingDeltaX maps directly (its sign already
                    # matches REL_HWHEEL). The two axes do NOT share a sign —
                    # negating dx inverts left/right.
                    wrote = vertical.push(fd, -dy * v120_per_px)
                    wrote |= horizontal.push(fd, dx * v120_per_px)
                    if wrote:
                        emit(fd, EV_SYN, SYN_REPORT, 0)
        except OSError as e:
            log(f"connection error: {e}")
        finally:
            try:
                conn.close()
            except OSError:
                pass
            log("host disconnected")


def main():
    while True:
        try:
            fd = create_uinput_device()
            break
        except OSError as e:
            log(f"uinput unavailable ({e}); retrying in 5s")
            time.sleep(5)
    # Give udev/X a beat to enumerate the device before traffic arrives.
    time.sleep(0.5)
    serve(fd)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
