#!/usr/bin/env python3
"""Actual X input-focus ancestry and active-client checks, without Chromium."""
import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts/shared_windows.py'


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('Xvfb'), 'requires Linux Xvfb')
class FocusTests(unittest.TestCase):
    def test_actual_focused_child_active_client_and_browser_pid(self):
        with tempfile.TemporaryDirectory() as temp:
            # Test-owned executable name exercises /proc identity checking; this
            # is an X client fixture, not a Chromium integration claim.
            executable = Path(temp) / 'chrome'
            shutil.copyfile(shutil.which('sleep'), executable)
            executable.chmod(0o700)
            process = subprocess.Popen([str(executable), '30'])
            self.addCleanup(process.wait)
            self.addCleanup(process.terminate)
            readfd, writefd = os.pipe()
            server = subprocess.Popen(['Xvfb', '-displayfd', str(writefd), '-screen', '0', '640x480x24',
                                       '-nolisten', 'tcp', '-noreset'], pass_fds=(writefd,),
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(writefd)
            self.addCleanup(server.wait)
            self.addCleanup(server.terminate)
            self.addCleanup(os.close, readfd)
            self.assertTrue(select.select([readfd], [], [], 5)[0])
            display = ':' + os.read(readfd, 32).decode().strip()
            x = C.CDLL('libX11.so.6')
            P, W = C.c_void_p, C.c_ulong
            for name, result, args in (
                ('XOpenDisplay', P, [C.c_char_p]), ('XCloseDisplay', C.c_int, [P]),
                ('XDefaultRootWindow', W, [P]), ('XInternAtom', W, [P, C.c_char_p, C.c_int]),
                ('XCreateSimpleWindow', W, [P, W, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_uint, W, W]),
                ('XMapWindow', C.c_int, [P, W]), ('XSetInputFocus', C.c_int, [P, W, C.c_int, W]),
                ('XChangeProperty', C.c_int, [P, W, W, W, C.c_int, C.c_int, P, C.c_int]),
                ('XSync', C.c_int, [P, C.c_int]),
            ):
                fn = getattr(x, name)
                fn.restype, fn.argtypes = result, args
            d = x.XOpenDisplay(display.encode())
            self.assertTrue(d)
            self.addCleanup(x.XCloseDisplay, d)
            root = x.XDefaultRootWindow(d)
            client = x.XCreateSimpleWindow(d, root, 0, 0, 200, 200, 0, 0, 0)
            child = x.XCreateSimpleWindow(d, client, 0, 0, 100, 100, 0, 0, 0)
            other = x.XCreateSimpleWindow(d, root, 300, 0, 100, 100, 0, 0, 0)
            for window in (client, child, other):
                x.XMapWindow(d, window)
            def prop(window, name, kind, value):
                data = W(value)
                x.XChangeProperty(d, window, x.XInternAtom(d, name.encode(), False),
                                  x.XInternAtom(d, kind.encode(), False), 32, 0, C.byref(data), 1)
            def probe():
                x.XSync(d, False)
                result = subprocess.run([sys.executable, str(MODULE), 'probe-focus'],
                                        env=dict(os.environ, DISPLAY=display), capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)
            prop(root, '_NET_ACTIVE_WINDOW', 'WINDOW', client)
            prop(client, '_NET_WM_PID', 'CARDINAL', process.pid)
            x.XSetInputFocus(d, child, 1, 0)
            observed = probe()
            self.assertEqual((observed['xFocus'], observed['xWindow'], observed['browserPID']),
                             (child, client, process.pid))
            self.assertGreater(observed['browserStartTicks'], 0)
            x.XSetInputFocus(d, other, 1, 0)
            self.assertIsNone(probe())
            x.XSetInputFocus(d, child, 1, 0)
            prop(client, '_NET_WM_PID', 'CARDINAL', os.getpid())  # Python is not a browser.
            self.assertIsNone(probe())


if __name__ == '__main__':
    unittest.main()
