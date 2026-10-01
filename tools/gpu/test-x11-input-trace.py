#!/usr/bin/env python3
"""Wire decoding tests plus optional real Xvfb/XTest isolation test.

Run: python3 tools/gpu/test-x11-input-trace.py
The live test injects only into its own Xvfb, never the current desktop.
"""

import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("guest-x11-input-trace.py")
spec = importlib.util.spec_from_file_location("trace", SCRIPT)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class DecoderTests(unittest.TestCase):
    def test_ordered_geometry_coordinates_and_endianness(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                rows = []
                stream = trace.Stream(123, 89, 131, rows.append)
                swapped = (endian == "<") != (sys.byteorder == "little")

                def packet(kind, *fields):
                    raw = bytearray(32)
                    raw[0] = kind
                    for fmt, offset, values in fields:
                        struct.pack_into(endian + fmt, raw, offset, *values)
                    return raw

                initial = packet(1, ("I", 8, (123,)), ("HH", 16, (1088, 752)))
                down = packet(4, ("B", 1, (1,)), ("I", 4, (0xFFFFFFF0,)),
                              ("hh", 20, (271, 319)))
                configure = packet(22, ("I", 8, (123,)), ("HH", 20, (1032, 716)))
                up = packet(5, ("B", 1, (1,)), ("I", 4, (4,)), ("hh", 20, (-1, 304)))
                stream.record(initial, swapped, client_id=42)
                stream.record(down, swapped)
                stream.record(configure, swapped, client_id=42)
                stream.record(up, swapped)
                self.assertEqual([r["ordinal"] for r in rows], [1, 2, 3, 4])
                self.assertEqual((rows[1]["root_width"], rows[1]["root_height"]), (1088, 752))
                self.assertEqual((rows[3]["root_width"], rows[3]["root_height"]), (1032, 716))
                self.assertEqual(rows[3]["geometry_ordinal"], 3)
                self.assertEqual(rows[1]["root_x"], 271)
                self.assertEqual(rows[3]["root_x"], -1)
                self.assertEqual(rows[3]["event_time_ms"], 4)  # Wrap preserved, never sorted by time.
                configure[0] |= 128
                struct.pack_into(endian + "HH", configure, 20, 9, 9)
                stream.record(configure, swapped, client_id=42)
                self.assertEqual(stream.geometry, (1032, 716))
                self.assertTrue(rows[-1]["sent_event"])

    def test_randr_output_dimensions_do_not_replace_root_dimensions(self):
        rows = []
        stream = trace.Stream(123, 89, 131, rows.append)
        stream.geometry = (5120, 2948)
        raw = bytearray(32)
        raw[0] = 90
        struct.pack_into("=HH", raw, 28, 1920, 1080)
        stream.record(raw, client_id=42)
        self.assertEqual(rows[0]["width"], 1920)
        self.assertEqual(rows[0]["root_width"], 5120)

    def test_truncated_protocol_fails_explicitly(self):
        stream = trace.Stream(123, 89, 131, lambda row: None)
        for raw in (b"\0" * 31, b"\x23\0\0\0\x01\0\0\0" + b"\0" * 24):
            with self.assertRaises(ValueError):
                stream.record(raw, swapped=sys.byteorder != "little")


@unittest.skipUnless(shutil.which("Xvfb") and shutil.which("xrandr"), "needs Xvfb and xrandr")
class LiveTests(unittest.TestCase):
    def test_real_buttons_resize_and_other_client_delivery(self):
        read_fd, write_fd = os.pipe()
        with tempfile.TemporaryFile() as server_log:
            server = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0",
                                       "1024x768x24", "-nolisten", "tcp"],
                                      pass_fds=(write_fd,), stdout=server_log, stderr=server_log)
            os.close(write_fd)
            observer = None
            display = None
            try:
                self.assertTrue(select.select([read_fd], [], [], 5)[0], "Xvfb did not start")
                display_name = ":" + os.read(read_fd, 64).decode().strip()
                env = {**os.environ, "DISPLAY": display_name}
                x, xt = C.CDLL("libX11.so.6"), C.CDLL("libXtst.so.6")
                P, U, I = C.c_void_p, C.c_ulong, C.c_int
                trace.bind(x, "XOpenDisplay", P, C.c_char_p)
                trace.bind(x, "XCloseDisplay", I, P)
                trace.bind(x, "XDefaultRootWindow", U, P)
                trace.bind(x, "XSelectInput", I, P, U, C.c_long)
                trace.bind(x, "XSync", I, P, I)
                trace.bind(x, "XPending", I, P)
                trace.bind(x, "XNextEvent", I, P, C.POINTER(trace.XEvent))
                trace.bind(xt, "XTestFakeMotionEvent", I, P, I, I, I, U)
                trace.bind(xt, "XTestFakeButtonEvent", I, P, C.c_uint, I, U)
                display = x.XOpenDisplay(display_name.encode())
                self.assertTrue(display)
                # Another client selects real core clicks. The observer must not steal them.
                x.XSelectInput(display, x.XDefaultRootWindow(display), (1 << 2) | (1 << 3))
                x.XSync(display, 0)
                with tempfile.TemporaryFile(mode="w+") as output:
                    observer = subprocess.Popen([sys.executable, str(SCRIPT), "--seconds", "3"],
                                                env=env, stdout=output, stderr=subprocess.PIPE, text=True)
                    # Wait for actual ready marker, not an assumed startup delay.
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        output.seek(0)
                        if '"event":"ready"' in output.read():
                            break
                        time.sleep(0.02)
                    else:
                        self.fail("observer never became ready")

                    def click(px, py):
                        xt.XTestFakeMotionEvent(display, 0, px, py, 0)
                        xt.XTestFakeButtonEvent(display, 1, 1, 0)
                        xt.XTestFakeButtonEvent(display, 1, 0, 0)
                        x.XSync(display, 0)

                    click(271, 319)
                    subprocess.run(["xrandr", "--output", "screen", "--off", "--fb", "800x600"],
                                   env=env, check=True, capture_output=True, timeout=3)
                    click(199, 249)
                    _, stderr = observer.communicate(timeout=9)
                    self.assertEqual(observer.returncode, 0, stderr)
                    output.seek(0)
                    rows = [json.loads(line) for line in output]
                self.assertEqual(rows[-1]["event"], "end")
                buttons = [r for r in rows if r["event"] == "core_button"]
                self.assertEqual([r["action"] for r in buttons], ["down", "up", "down", "up"])
                self.assertEqual([(r["root_x"], r["root_y"]) for r in buttons],
                                 [(271, 319)] * 2 + [(199, 249)] * 2)
                self.assertEqual([(r["root_width"], r["root_height"]) for r in buttons],
                                 [(1024, 768)] * 2 + [(800, 600)] * 2)
                self.assertTrue(any(r["event"] == "root_configure" for r in rows))
                self.assertTrue(any(r["event"] == "randr_screen" for r in rows))
                xi = [r for r in rows if r["event"] == "xi2_raw_button"]
                self.assertEqual([r["action"] for r in xi], ["down", "up", "down", "up"])
                self.assertTrue(all("ordinal" not in r and "root_width" not in r for r in xi))
                # Final button must arrive before shutdown flush, while otherwise idle.
                self.assertLess(buttons[-1]["monotonic_ns"] - xi[-1]["monotonic_ns"], 500_000_000)
                delivered = []
                event = trace.XEvent()
                while x.XPending(display):
                    x.XNextEvent(display, C.byref(event))
                    if event.type in (4, 5):
                        delivered.append(event.type)
                self.assertEqual(delivered, [4, 5, 4, 5])
            finally:
                os.close(read_fd)
                if observer and observer.poll() is None:
                    observer.kill()
                    observer.communicate(timeout=3)
                if display:
                    x.XCloseDisplay(display)
                server.terminate()
                server.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
