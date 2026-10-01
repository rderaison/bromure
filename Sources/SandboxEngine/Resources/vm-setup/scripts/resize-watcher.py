#!/usr/bin/python3 -u
"""Follow preferred RandR modes without polling xrandr while idle.

RandR notifications trigger updates, coalesced to at most 30 per second.
A cheap config-file stat also notices claim-time backend/refresh preferences.
Only active outputs are eligible: a connected but inactive VZ output must
never be enabled by the custom-GPU resize path.
"""

import ctypes as C
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import sys
import time

CONFIG = Path("/tmp/bromure/chrome-env")
INTERVAL = 1 / 30


class XEvent(C.Union):
    _fields_ = [("type", C.c_int), ("pad", C.c_long * 24)]


class RandREvents:
    def __init__(self):
        self.x = C.CDLL("libX11.so.6")
        self.rr = C.CDLL("libXrandr.so.2")
        for name, result, args in (
            ("XOpenDisplay", C.c_void_p, [C.c_char_p]),
            ("XDefaultRootWindow", C.c_ulong, [C.c_void_p]),
            ("XConnectionNumber", C.c_int, [C.c_void_p]),
            ("XPending", C.c_int, [C.c_void_p]),
            ("XNextEvent", C.c_int, [C.c_void_p, C.POINTER(XEvent)]),
            ("XFlush", C.c_int, [C.c_void_p]),
            ("XCloseDisplay", C.c_int, [C.c_void_p]),
        ):
            function = getattr(self.x, name)
            function.restype, function.argtypes = result, args
        self.rr.XRRQueryExtension.argtypes = [C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.rr.XRRQueryExtension.restype = C.c_int
        self.rr.XRRQueryVersion.argtypes = [C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.rr.XRRQueryVersion.restype = C.c_int
        self.rr.XRRSelectInput.argtypes = [C.c_void_p, C.c_ulong, C.c_int]
        self.rr.XRRSelectInput.restype = None
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            raise OSError("Cannot open X display")
        try:
            event, error, major, minor = C.c_int(), C.c_int(), C.c_int(1), C.c_int(4)
            if not self.rr.XRRQueryExtension(self.display, C.byref(event), C.byref(error)):
                raise OSError("RandR extension unavailable")
            if not self.rr.XRRQueryVersion(self.display, C.byref(major), C.byref(minor)) or (major.value, minor.value) < (1, 2):
                raise OSError("RandR 1.2 required")
            self.event_base = event.value
            # Screen, CRTC, output and output-property changes; also resource
            # changes on 1.4+ (new preferred modes without a connection change).
            mask = 0x0F | (0x40 if (major.value, minor.value) >= (1, 4) else 0)
            self.rr.XRRSelectInput(self.display, self.x.XDefaultRootWindow(self.display), mask)
            self.x.XFlush(self.display)
            self.fd = self.x.XConnectionNumber(self.display)
        except BaseException:
            self.close()
            raise

    def wait(self, timeout):
        if not self.x.XPending(self.display) and not select.select([self.fd], [], [], timeout)[0]:
            return False
        changed = False
        event = XEvent()
        # Bound draining so an event storm cannot starve the resize scheduler.
        for _ in range(256):
            if not self.x.XPending(self.display):
                break
            self.x.XNextEvent(self.display, C.byref(event))
            changed |= event.type in (self.event_base, self.event_base + 1)
        return changed

    def close(self):
        if self.display:
            self.x.XCloseDisplay(self.display)
            self.display = None


def settings(path=CONFIG):
    values = {}
    try:
        for line in path.read_text().splitlines():
            try:
                parts = shlex.split(line, comments=True)
            except ValueError:
                continue
            if parts and parts[0] == "export":
                parts = parts[1:]
            if len(parts) == 1 and "=" in parts[0]:
                key, value = parts[0].split("=", 1)
                if key in ("GRAPHICS_BACKEND", "DISPLAY_HZ"):
                    values[key] = value
    except OSError:
        pass
    raw_hz = values.get("DISPLAY_HZ", "60")
    hz = min(1000, max(60, int(raw_hz))) if raw_hz.isascii() and raw_hz.isdigit() and len(raw_hz) <= 4 else 60
    return values.get("GRAPHICS_BACKEND") == "virgl", hz


def parse_outputs(text):
    outputs, current = [], None
    for line in text.splitlines():
        match = re.match(r"^(\S+) (connected|disconnected)\b(.*)", line)
        if match:
            name, status, rest = match.groups()
            geometry = re.search(r"\b(\d+)x(\d+)([+-]\d+)([+-]\d+)", rest)
            current = {"name": name, "primary": "primary" in rest.split(),
                       "geometry": tuple(map(int, geometry.groups())) if geometry else None,
                       "modes": [], "preferred": None, "current": None}
            if status == "connected":
                outputs.append(current)
            else:
                current = None
        elif current is not None:
            match = re.match(r"^\s+(\d+x\d+\S*)\s+([\d.].*)$", line)
            if match:
                name, rates = match.groups()
                current["modes"].append(name)
                if "+" in rates and current["preferred"] is None:
                    current["preferred"] = name
                if "*" in rates:
                    current["current"] = name
    return outputs


def select_output(outputs, previous, virgl):
    active = [output for output in outputs if output["geometry"]]
    known = next((output for output in active if output["name"] == previous), None)
    if known:
        return known
    if len(active) == 1:
        return active[0]
    if virgl:
        return None  # Don't guess which GPU owns multiple active outputs.
    return next((output for output in active if output["primary"]), active[0] if active else None)


def command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=3,
                                env=dict(os.environ, LC_ALL="C"))
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


class ResizeController:
    def __init__(self, run=command, configuration=settings):
        self.run, self.configuration = run, configuration
        self.output = None
        self.owned_modes = set()
        self.failed_hz = set()

    def update(self):
        rc, text = self.run(["xrandr", "--query"])
        if rc:
            return
        virgl, hz = self.configuration()
        outputs = parse_outputs(text)
        output = select_output(outputs, self.output, virgl)
        if not output or not output["modes"]:
            return
        self.output = output["name"]
        preferred = output["preferred"] or output["modes"][0]
        dimensions = re.match(r"^(\d+)x(\d+)", preferred)
        if not dimensions:
            return
        width, height = map(int, dimensions.groups())
        if not (0 < width <= 8192 and 0 < height <= 8192):
            return
        mode = preferred
        high = f"{width}x{height}_{hz}.00"
        failed_key = (self.output, width, height, hz)
        if hz > 60 and failed_key not in self.failed_hz:
            if high in output["modes"]:
                mode = high
            else:
                rc, modeline = self.run(["gtf", str(width), str(height), str(hz)])
                line = next((line.strip()[9:] for line in modeline.splitlines()
                             if line.strip().startswith("Modeline ")), "")
                fields = shlex.split(line)
                if not rc and fields and fields[0] == high:
                    created = self.run(["xrandr", "--newmode", *fields])[0] == 0
                    if self.run(["xrandr", "--addmode", self.output, high])[0] == 0:
                        mode = high
                        if created:
                            self.owned_modes.add((self.output, high))
                    elif created:
                        self.run(["xrandr", "--rmmode", high])
                if mode != high:
                    self.failed_hz.add(failed_key)
        if len(self.failed_hz) > 128:
            self.failed_hz = {failed_key}
        geometry = output["geometry"]
        reposition = virgl and (not output["primary"] or geometry[2:] != (0, 0))
        single_active = sum(item["geometry"] is not None for item in outputs) == 1
        screen = re.search(r"^Screen \d+:.*\bcurrent (\d+) x (\d+)", text, re.MULTILINE)
        resize_root = virgl and single_active and screen and tuple(map(int, screen.groups())) != (width, height)
        if output["current"] == mode and geometry[:2] == (width, height) and not reposition and not resize_root:
            return
        args = ["xrandr", "--output", self.output, "--mode", mode]
        if virgl:
            args += ["--primary", "--pos", "0x0"]
            if single_active:
                args += ["--fb", f"{width}x{height}"]
        if self.run(args)[0]:
            if mode == preferred:
                return
            self.failed_hz.add(failed_key)
            args[4] = preferred
            if self.run(args)[0]:
                return
            mode = preferred
        # Retire only modes this process created; never remove distro/host modes.
        for owner, old_mode in tuple(self.owned_modes):
            if (owner, old_mode) != (self.output, mode):
                if self.run(["xrandr", "--delmode", owner, old_mode])[0] == 0:
                    self.run(["xrandr", "--rmmode", old_mode])
                    self.owned_modes.discard((owner, old_mode))


def config_signature():
    try:
        stat = CONFIG.stat()
        return stat.st_ino, stat.st_mtime_ns, stat.st_size
    except OSError:
        return None


def watch(events, controller, clock=time.monotonic, signature=config_signature):
    dirty, next_update, last_signature = True, 0.0, signature()
    while True:
        now = clock()
        if dirty and now >= next_update:
            controller.update()
            dirty = False
            next_update = clock() + INTERVAL
        timeout = max(0, next_update - clock()) if dirty else 1.0
        if events.wait(timeout):
            dirty = True
        current = signature()
        if current != last_signature:
            last_signature, dirty = current, True


def main():
    events = RandREvents()
    try:
        watch(events, ResizeController())
    finally:
        events.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyboardInterrupt) as error:
        print(f"resize-watcher: {error}", file=sys.stderr)
