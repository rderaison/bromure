#!/usr/bin/env python3
"""Topology/wire/session tests plus real two-screen Xvfb pointer/focus tests."""
import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts'


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


session = load('experimental-multigpu')
wire = load('experimental-multigpu-input')


class Tests(unittest.TestCase):
    def test_topology_excludes_builtin_and_pins_pci_not_card_order(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            drm = root / 'class/drm'
            drm.mkdir(parents=True)
            for card, render, pci, virgl in ((0, 128, '0000:00:09.0', False),
                                            (9, 134, '0000:00:0d.0', True),
                                            (2, 131, '0000:00:0e.0', True)):
                device = root / 'devices' / pci / f'virtio{card}'
                device.mkdir(parents=True)
                (device / 'features').write_text(('1' if virgl else '0') + '0' * 63)
                for name in (f'card{card}', f'renderD{render}'):
                    node = drm / name
                    node.mkdir()
                    (node / 'device').symlink_to(device)
            devices = session.discover(drm)
            self.assertEqual([d['card'] for d in devices], ['/dev/dri/card9', '/dev/dri/card2'])
            self.assertEqual(devices[1]['render'], '/dev/dri/renderD131')
            text = session.xorg_config(devices)
            self.assertIn('BusID "PCI:0@0:13:0"', text)
            self.assertIn('Option "Xinerama" "false"', text)
            self.assertNotIn('/dev/dri/card0', text)
            (root / 'devices/0000:00:0e.0/virtio2/features').write_text('0' * 64)
            with self.assertRaisesRegex(ValueError, 'exactly two'):
                session.discover(drm)

    def test_distinct_browser_profiles_ports_and_render_nodes(self):
        values = dict(EXTRA_FLAGS='--user-data-dir=/persistent --remote-debugging-port 9222 '
                      '--render-node-override=/dev/dri/renderD128 --hardware-video-device-path=/wrong '
                      '--proxy-server=http://127.0.0.1:3128 --use-angle=gl',
                      CHROME_UA='Agent with spaces', DISPLAY_SCALE='2')
        device = dict(index=1, display=':0.1', cdpPort=9223, render='/dev/dri/renderD130')
        command = session.browser_command(values, device, Path('/tmp/test-profiles'))
        self.assertIn('--user-data-dir=/tmp/test-profiles/screen-1', command)
        self.assertIn('--remote-debugging-port=9223', command)
        self.assertIn('--render-node-override=/dev/dri/renderD130', command)
        self.assertIn('--hardware-video-device-path=/dev/dri/renderD130', command)
        self.assertIn('--user-agent=Agent with spaces', command)
        self.assertIn('--proxy-server=http://127.0.0.1:3128', command)
        self.assertFalse(any('persistent' in arg or '/wrong' in arg for arg in command))
        self.assertEqual(session.screen_environment(values, device)['DISPLAY'], ':0.1')

    def test_wire_validation_and_bounds(self):
        base = dict(display=1, x=.25, y=.75, buttons=3)
        parsed = wire.parse(json.dumps(base))
        self.assertFalse(parsed['focus'])
        self.assertEqual(parsed['wheelX'], 0)
        for change in ({'display': True}, {'display': 2}, {'buttons': 8}, {'buttons': False},
                       {'x': float('nan')}, {'wheelY': 2049}, {'focus': 1}, {'unknown': 1}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                wire.parse(json.dumps(base | change))
        with self.assertRaises(ValueError):
            wire.parse('{"display":0,"display":1,"x":0,"y":0,"buttons":0}')
        self.assertEqual(wire.parse(json.dumps(base | {'x': -1, 'y': 2}))['x'], 0)

    def test_fragmented_stream_and_failure_release(self):
        class Injector:
            def __init__(self):
                self.values = []
                self.releases = 0
            def update(self, value):
                self.values.append(value)
            def release(self):
                self.releases += 1
        class Stream:
            chunks = iter([b'{"display":0,"x":0.', b'5,"y":0.5,"buttons":1}\n', b'bad\n'])
            def recv(self, size):
                return next(self.chunks, b'')
        injector = Injector()
        with self.assertRaises(ValueError):
            wire.connection(Stream(), injector)
        self.assertEqual(len(injector.values), 1)
        self.assertEqual(injector.releases, 1)

    @unittest.skipUnless(shutil.which('Xvfb'), 'requires Xvfb')
    def test_live_two_roots_pointer_buttons_focus_and_keyboard(self):
        with tempfile.TemporaryDirectory() as temp:
            # Xvfb allocates an unused display atomically via -displayfd.
            readfd, writefd = os.pipe()
            server = subprocess.Popen(['Xvfb', '-displayfd', str(writefd),
                                       '-screen', '0', '640x480x24', '-screen', '1', '800x600x24',
                                       '-nolisten', 'tcp', '-noreset'], pass_fds=(writefd,),
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(writefd)
            injector = None
            try:
                import select
                self.assertTrue(select.select([readfd], [], [], 5)[0], 'Xvfb startup timeout')
                display = b':' + os.read(readfd, 32).strip()
                injector = wire.XInput(display)
                x, d = injector.x, injector.display
                for name, result, args in (
                    ('XCreateSimpleWindow', C.c_ulong, [C.c_void_p, C.c_ulong, C.c_int,
                        C.c_int, C.c_uint, C.c_uint, C.c_uint, C.c_ulong, C.c_ulong]),
                    ('XMapWindow', C.c_int, [C.c_void_p, C.c_ulong]),
                    ('XSetClassHint', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(wire.ClassHint)]),
                    ('XGetInputFocus', C.c_int, [C.c_void_p, C.POINTER(C.c_ulong), C.POINTER(C.c_int)]),
                    ('XSelectInput', C.c_int, [C.c_void_p, C.c_ulong, C.c_long]),
                    ('XPending', C.c_int, [C.c_void_p]),
                    ('XNextEvent', C.c_int, [C.c_void_p, C.c_void_p]),
                    ('XQueryPointer', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                        C.POINTER(C.c_ulong), *([C.POINTER(C.c_int)] * 4), C.POINTER(C.c_uint)]),
                ):
                    fn = getattr(x, name)
                    fn.restype, fn.argtypes = result, args
                windows = []
                for i, root in enumerate(injector.roots):
                    w, h = injector.dimensions(root)
                    window = x.XCreateSimpleWindow(d, root, 0, 0, w, h, 0, 0, 0)
                    name, klass = C.create_string_buffer(b'chromium'), C.create_string_buffer(b'Chromium')
                    hint = wire.ClassHint(C.cast(name, C.c_void_p), C.cast(klass, C.c_void_p))
                    x.XSetClassHint(d, window, C.byref(hint))
                    x.XSelectInput(d, window, 1 | 2 | 4 | 8)  # key/button press/release
                    x.XMapWindow(d, window)
                    windows.append(window)
                x.XSync(d, False)
                for screen in (0, 1, 0, 1):
                    injector.update(wire.parse(json.dumps(dict(
                        display=screen, x=.25, y=.75, buttons=1, focus=True))))
                    focus, revert = C.c_ulong(), C.c_int()
                    x.XGetInputFocus(d, C.byref(focus), C.byref(revert))
                    self.assertEqual(focus.value, windows[screen])
                    root, child, mask = C.c_ulong(), C.c_ulong(), C.c_uint()
                    coords = [C.c_int() for _ in range(4)]
                    self.assertTrue(x.XQueryPointer(d, injector.roots[screen], C.byref(root),
                                    C.byref(child), *map(C.byref, coords), C.byref(mask)),
                                    f'screen={screen}, root={root.value}, roots={injector.roots}, coords={[p.value for p in coords]}')
                    width, height = injector.dimensions(injector.roots[screen])
                    self.assertEqual((coords[0].value, coords[1].value), (width // 4, height * 3 // 4))
                    self.assertTrue(mask.value & 256)
                    # The shared keyboard's core focus is the selected screen's window.
                    injector.xt.XTestFakeKeyEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
                    injector.xt.XTestFakeKeyEvent(d, 38, True, 0)
                    injector.xt.XTestFakeKeyEvent(d, 38, False, 0)
                    injector.release()
                x.XSync(d, False)
                event_types = []
                while x.XPending(d):
                    event = (C.c_long * 24)()
                    x.XNextEvent(d, C.byref(event))
                    event_types.append(C.cast(event, C.POINTER(C.c_int))[0])
                self.assertEqual(event_types.count(2), 4)  # KeyPress
                self.assertEqual(event_types.count(3), 4)  # KeyRelease
                self.assertEqual(event_types.count(4), 4)  # ButtonPress
                self.assertEqual(event_types.count(5), 4)  # ButtonRelease
            finally:
                os.close(readfd)
                if injector:
                    injector.close()
                server.terminate()
                server.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
