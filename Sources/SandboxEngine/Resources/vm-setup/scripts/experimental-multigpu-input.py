#!/usr/bin/python3 -u
"""Experimental host-only screen-local XTEST pointer/focus/wheel, vsock5830.

Required: display(0..screen_count-1), x/y(normalized), buttons(left1/right2/middle4).
Optional: focus(bool), wheelX/wheelY(pixels, positive right/down, max2048).
One ordered connection controls all X screens; legacy5821 stays unchanged.
"""
import argparse
import ctypes as C
import json
import math
import signal
import socket
import sys

PORT = 5830
MAX_LINE = 1024
BUTTONS = (1, 3, 2)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate field')
        result[key] = value
    return result


def parse(line, screen_count=2):
    if type(screen_count) is not int or not 2 <= screen_count <= 16:
        raise ValueError('invalid screen count')
    if len(line) > MAX_LINE:
        raise ValueError('oversized input')
    value = json.loads(line, object_pairs_hook=unique)
    required = {'display', 'x', 'y', 'buttons'}
    if not isinstance(value, dict) or not required <= value.keys() or \
            value.keys() - (required | {'focus', 'wheelX', 'wheelY'}):
        raise ValueError('invalid input fields')
    if type(value['display']) is not int or not 0 <= value['display'] < screen_count:
        raise ValueError('invalid screen')
    if type(value['buttons']) is not int or not 0 <= value['buttons'] <= 7:
        raise ValueError('invalid buttons')
    if type(value.get('focus', False)) is not bool:
        raise ValueError('invalid focus')
    for field in ('x', 'y', 'wheelX', 'wheelY'):
        number = value.get(field, 0)
        if type(number) not in (int, float):
            raise ValueError('invalid coordinate')
        try:
            number = float(number)
        except OverflowError as error:
            raise ValueError('overflow coordinate') from error
        if not math.isfinite(number):
            raise ValueError('nonfinite coordinate')
        if field.startswith('wheel') and abs(number) > 2048:
            raise ValueError('wheel exceeds bound')
        value[field] = max(0., min(1., number)) if field in ('x', 'y') else number
    value.setdefault('focus', False)
    return value


class ClassHint(C.Structure):
    _fields_ = [('name', C.c_void_p), ('klass', C.c_void_p)]


class WindowAttributes(C.Structure):
    _fields_ = [(name, C.c_int) for name in ('x', 'y', 'width', 'height', 'border', 'depth')] + [
        ('visual', C.c_void_p), ('root', C.c_ulong), ('klass', C.c_int),
        ('bit_gravity', C.c_int), ('win_gravity', C.c_int), ('backing_store', C.c_int),
        ('backing_planes', C.c_ulong), ('backing_pixel', C.c_ulong), ('save_under', C.c_int),
        ('colormap', C.c_ulong), ('map_installed', C.c_int), ('map_state', C.c_int),
        ('all_events', C.c_long), ('your_events', C.c_long), ('do_not_propagate', C.c_long),
        ('override_redirect', C.c_int), ('screen', C.c_void_p)]


class XInput:
    def __init__(self, display=b':0', expected_count=2):
        if type(expected_count) is not int or not 2 <= expected_count <= 16:
            raise ValueError('expected screen count must be 2 through 16')
        self.x = C.CDLL('libX11.so.6')
        self.xt = C.CDLL('libXtst.so.6')
        for name, result, args in (
            ('XOpenDisplay', C.c_void_p, [C.c_char_p]),
            ('XCloseDisplay', C.c_int, [C.c_void_p]),
            ('XScreenCount', C.c_int, [C.c_void_p]),
            ('XRootWindow', C.c_ulong, [C.c_void_p, C.c_int]),
            ('XGetGeometry', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                C.POINTER(C.c_int), C.POINTER(C.c_int), *([C.POINTER(C.c_uint)] * 4)]),
            ('XQueryTree', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)), C.POINTER(C.c_uint)]),
            ('XGetClassHint', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(ClassHint)]),
            ('XGetWindowAttributes', C.c_int, [C.c_void_p, C.c_ulong, C.POINTER(WindowAttributes)]),
            ('XRaiseWindow', C.c_int, [C.c_void_p, C.c_ulong]),
            ('XSetInputFocus', C.c_int, [C.c_void_p, C.c_ulong, C.c_int, C.c_ulong]),
            ('XWarpPointer', C.c_int, [C.c_void_p, C.c_ulong, C.c_ulong,
                C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_int, C.c_int]),
            ('XSync', C.c_int, [C.c_void_p, C.c_int]),
            ('XFree', C.c_int, [C.c_void_p]),
            ('XSetErrorHandler', C.c_void_p, [C.c_void_p]),
        ):
            function = getattr(self.x, name)
            function.restype, function.argtypes = result, args
        # Window destruction during tree traversal is expected; the default
        # Xlib handler would terminate the process instead of returning errors.
        self.error_handler = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)(lambda *_: 0)
        self.previous_error_handler = self.x.XSetErrorHandler(self.error_handler)
        self.xt.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
        self.xt.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.display = self.x.XOpenDisplay(display)
        self.screen_count = self.x.XScreenCount(self.display) if self.display else 0
        if self.screen_count != expected_count:
            if self.display:
                self.x.XCloseDisplay(self.display)
            self.x.XSetErrorHandler(self.previous_error_handler)
            raise OSError(f'expected {expected_count} X screens, found {self.screen_count}')
        self.roots = [self.x.XRootWindow(self.display, i) for i in range(self.screen_count)]
        self.buttons = 0
        self.screen = None
        self.wheels = [[0., 0.] for _ in range(self.screen_count)]

    def dimensions(self, window):
        root, x, y = C.c_ulong(), C.c_int(), C.c_int()
        width, height, border, depth = [C.c_uint() for _ in range(4)]
        if not self.x.XGetGeometry(self.display, window, C.byref(root), C.byref(x), C.byref(y),
                                  C.byref(width), C.byref(height), C.byref(border), C.byref(depth)):
            raise OSError('cannot query root geometry')
        if not 0 < width.value <= 32768 or not 0 < height.value <= 32768:
            raise ValueError('invalid root dimensions')
        return width.value, height.value

    def chrome_window(self, screen):
        # Openbox reparents clients. Traverse topmost-first, depth/node bounded,
        # only under the selected root; never focus the other screen's client.
        pending = [(self.roots[screen], 0)]
        for _ in range(512):
            if not pending:
                break
            window, depth = pending.pop()
            hint = ClassHint()
            if self.x.XGetClassHint(self.display, window, C.byref(hint)):
                names = []
                for ptr in (hint.name, hint.klass):
                    if ptr:
                        names.append(C.string_at(ptr).lower())
                        self.x.XFree(ptr)
                if any(b'chromium' in name or b'google-chrome' in name for name in names):
                    attributes = WindowAttributes()
                    if self.x.XGetWindowAttributes(self.display, window, C.byref(attributes)) and \
                            attributes.map_state == 2 and attributes.root == self.roots[screen]:
                        return window
            if depth >= 4:
                continue
            root, parent, count = C.c_ulong(), C.c_ulong(), C.c_uint()
            children = C.POINTER(C.c_ulong)()
            if self.x.XQueryTree(self.display, window, C.byref(root), C.byref(parent),
                                C.byref(children), C.byref(count)):
                try:
                    pending.extend((children[i], depth + 1) for i in range(min(count.value, 256)))
                finally:
                    if children:
                        self.x.XFree(children)
        return None

    def focus(self, screen):
        window = self.chrome_window(screen)
        if window:
            self.x.XRaiseWindow(self.display, window)
            self.x.XSetInputFocus(self.display, window, 1, 0)  # RevertToPointerRoot, CurrentTime

    def button(self, number, down):
        if not self.xt.XTestFakeButtonEvent(self.display, number, down, 0):
            raise OSError('XTEST button rejected')

    def update(self, value):
        screen, buttons = value['display'], value['buttons']
        changed_screen = self.screen != screen
        if changed_screen:
            self.release()
        self.screen = screen
        width, height = self.dimensions(self.roots[screen])
        x = min(width - 1, round(value['x'] * width))
        y = min(height - 1, round(value['y'] * height))
        if changed_screen:
            # XTEST alone can retain the previous root on multi-screen Xorg.
            # Explicitly enter this root before sending screen-local motion.
            self.x.XWarpPointer(self.display, 0, self.roots[screen], 0, 0, 0, 0, x, y)
        if not self.xt.XTestFakeMotionEvent(self.display, screen, x, y, 0):
            raise OSError('XTEST motion rejected')
        if value['focus'] or buttons & ~self.buttons:
            self.focus(screen)
        old = self.buttons
        self.buttons = buttons
        for bit, number in enumerate(BUTTONS):
            if (old ^ buttons) & (1 << bit):
                self.button(number, bool(buttons & (1 << bit)))
        for axis, field, negative, positive in ((0, 'wheelX', 6, 7), (1, 'wheelY', 4, 5)):
            self.wheels[screen][axis] += value[field]
            steps = math.trunc(self.wheels[screen][axis] / 120)
            self.wheels[screen][axis] -= steps * 120
            for _ in range(abs(steps)):
                number = positive if steps > 0 else negative
                self.button(number, True)
                self.button(number, False)
        self.x.XSync(self.display, False)

    def release(self):
        for bit, number in enumerate(BUTTONS):
            if self.buttons & (1 << bit):
                self.button(number, False)
        self.buttons = 0
        self.x.XSync(self.display, False)

    def close(self):
        try:
            self.release()
        finally:
            self.x.XCloseDisplay(self.display)
            self.x.XSetErrorHandler(self.previous_error_handler)


def connection(sock, injector):
    pending = bytearray()
    try:
        while True:
            part = sock.recv(MAX_LINE + 1)
            if not part:
                return
            pending.extend(part)
            while b'\n' in pending:
                line, _, rest = pending.partition(b'\n')
                pending = bytearray(rest)
                injector.update(parse(line, injector.screen_count))
            if len(pending) > MAX_LINE:
                raise ValueError('oversized input')
    finally:
        injector.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screen-count', type=int, choices=range(2, 17), default=2)
    args = parser.parse_args()
    def terminate(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    injector = XInput(expected_count=args.screen_count)
    try:
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as server:
            server.bind((socket.VMADDR_CID_ANY, PORT))
            server.listen(1)
            print('BROMURE_MULTIGPU_INPUT_READY', flush=True)
            while True:
                sock, address = server.accept()
                with sock:
                    if address[0] != getattr(socket, 'VMADDR_CID_HOST', 2):
                        continue
                    try:
                        connection(sock, injector)
                    except (OSError, ValueError, RecursionError) as error:
                        print('multigpu input disconnected: ' + str(error), file=sys.stderr)
    finally:
        injector.close()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
