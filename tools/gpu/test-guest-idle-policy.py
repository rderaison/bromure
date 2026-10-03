#!/usr/bin/env python3
"""Real X short-idle regression. Default: isolated Xvfb.

--live-display deliberately blanks the current private-test display, then applies
the exact patched /home/chrome/.xinitrc policy (override BROMURE_XINITRC).
Run as chrome with DISPLAY/XAUTHORITY set; do not run on a working user desktop.
Requires libxss1 (libXss.so.1), now explicitly installed by the image builder.
"""
import ctypes as C
import os
from pathlib import Path
import select
import shutil
import sys
import subprocess
import time
import unittest

LIVE = '--live-display' in sys.argv
if LIVE:
    sys.argv.remove('--live-display')
SCRIPT = (Path(os.environ.get('BROMURE_XINITRC', '/home/chrome/.xinitrc')) if LIVE else
          Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts/xinitrc')


@unittest.skipUnless((LIVE or shutil.which('Xvfb')) and shutil.which('xset'), 'requires Xvfb and xset')
class IdleTests(unittest.TestCase):
    def test_short_timeout_blanks_then_startup_policy_disables_and_resets_it(self):
        if LIVE:
            display = os.environ['DISPLAY']
        else:
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
        env = dict(os.environ, DISPLAY=display, LC_ALL='C')
        policy = SCRIPT.read_text().split('# BROMURE_IDLE_POLICY_BEGIN\n', 1)[1].split('# BROMURE_IDLE_POLICY_END', 1)[0]
        # Even a failed test on the private VM must not leave a 1-second timer.
        self.addCleanup(subprocess.run, ['sh', '-c', policy], env=env, timeout=3, check=True)
        def command(*args):
            return subprocess.run(args, env=env, capture_output=True, text=True, timeout=3, check=True).stdout
        initial = command('xset', 'q')
        print('BROMURE_IDLE_BEFORE ' + repr(initial), flush=True)
        if not LIVE:
            self.assertRegex(initial, r'timeout:\s+600')  # Stock Ubuntu X server defaults.
        x, ss = C.CDLL('libX11.so.6'), C.CDLL('libXss.so.1')
        x.XOpenDisplay.argtypes, x.XOpenDisplay.restype = [C.c_char_p], C.c_void_p
        x.XDefaultRootWindow.argtypes, x.XDefaultRootWindow.restype = [C.c_void_p], C.c_ulong
        x.XCloseDisplay.argtypes = [C.c_void_p]
        class Info(C.Structure):
            _fields_ = [('window', C.c_ulong), ('state', C.c_int), ('kind', C.c_int),
                        ('til_or_since', C.c_ulong), ('idle', C.c_ulong), ('eventMask', C.c_ulong)]
        ss.XScreenSaverQueryInfo.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(Info)]
        d = x.XOpenDisplay(display.encode())
        self.addCleanup(x.XCloseDisplay, d)
        def state():
            info = Info()
            self.assertTrue(ss.XScreenSaverQueryInfo(d, x.XDefaultRootWindow(d), C.byref(info)))
            return info.state
        command('xset', 's', '1', '1')
        command('xset', 's', 'reset')
        deadline = time.monotonic() + 4
        while state() != 1 and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertEqual(state(), 1, 'short timeout did not activate screensaver')
        for _ in range(2):
            subprocess.run(['sh', '-c', policy], env=env, timeout=3, check=True)
        current = command('xset', 'q')
        print('BROMURE_IDLE_AFTER ' + repr(current), flush=True)
        self.assertRegex(current, r'timeout:\s+0')
        self.assertNotIn('DPMS is Enabled', current)
        self.assertIn('prefer blanking:  no', current)
        self.assertIn(state(), (0, 3))  # ScreenSaverOff or ScreenSaverDisabled.
        time.sleep(2)
        self.assertIn(state(), (0, 3))
        print('BROMURE_IDLE_POLICY_PASS ' + ('live guest display' if LIVE else 'Xvfb; no hardware DPMS extension'), flush=True)


if __name__ == '__main__':
    unittest.main()
