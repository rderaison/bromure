#!/usr/bin/python3 -u
"""Guest helpers for opt-in windows within ONE Chromium profile and VM.

The host supplies complete physical-pixel output layouts. This module never
chooses a profile, starts Chromium, or shares a browser between profile VMs.
"""
import re
from pathlib import Path
from collections import OrderedDict
import json
import os
import socket
import subprocess
import threading
import time
import uuid
import sys
import base64
import hashlib
import struct
from urllib.parse import urlparse

MAX_SCANOUTS = 16
MAX_AXIS = 8192
MAX_ROOT_PIXELS = 33554432
MAX_OUTPUT_PIXELS = 33554432
SAFE_INTEGER = (1 << 53) - 1
MAX_FRAME = 65536
PORT = 5832
CHROME_PAGES = {'newtab', 'new-tab-page', 'history', 'bookmarks', 'downloads',
                'settings', 'gpu', 'version', 'policy'}


def navigation_url(value):
    """Explicit navigation policy for the opt-in controller/tab commands.

    The legacy tab agent has a favicon scheme filter, not a navigation
    allow-list. Do not silently apply this experimental policy to old VMs.
    """
    if (not isinstance(value, str) or not value or len(value.encode('utf-8')) > 8192 or
            value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise ValueError('invalid navigation URL')
    parsed = urlparse(value)
    if parsed.scheme in ('http', 'https'):
        if not parsed.hostname or any(char.isspace() for char in parsed.hostname) or '\\' in parsed.netloc:
            raise ValueError('invalid web URL host')
        parsed.port  # Validate the port before Chromium receives the URL.
        return value
    if parsed.scheme == 'about' and parsed.path == 'blank' and not parsed.netloc:
        return value
    if (parsed.scheme == 'chrome' and parsed.hostname in CHROME_PAGES and
            parsed.username is None and parsed.password is None and parsed.port is None):
        return value
    raise ValueError('unsupported navigation URL scheme or browser page')


def cdp_call(ws_url, method, params, timeout=3):
    """Small control RPC with a wall deadline, including upgrade/fragments."""
    url = urlparse(ws_url)
    if url.scheme != 'ws' or url.hostname != '127.0.0.1' or url.port != 9222 or url.query or url.fragment:
        raise ValueError('unexpected browser CDP endpoint')
    if not re.fullmatch(r'/devtools/(?:browser|page)/[A-Za-z0-9-]+', url.path):
        raise ValueError('unexpected browser CDP path')
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        def remaining():
            value = deadline - time.monotonic()
            if value <= 0:
                raise TimeoutError('CDP control deadline exceeded')
            sock.settimeout(value)

        def timed_io(operation, *args):
            remaining()
            try:
                return operation(*args)
            except socket.timeout as error:
                # Python 3.9 uses a distinct socket.timeout exception;
                # normalize it without extending the original wall deadline.
                raise TimeoutError('CDP control deadline exceeded') from error

        def read(count):
            data = bytearray()
            while len(data) < count:
                part = timed_io(sock.recv, count - len(data))
                if not part:
                    raise ConnectionError('CDP closed')
                data.extend(part)
            return bytes(data)

        def send(data, opcode=1):
            if len(data) > MAX_FRAME:
                raise ValueError('CDP control payload too large')
            mask = os.urandom(4)
            if len(data) < 126:
                prefix = bytes((0x80 | opcode, 0x80 | len(data)))
            elif len(data) < 65536:
                prefix = bytes((0x80 | opcode, 0xFE)) + struct.pack('>H', len(data))
            else:
                prefix = bytes((0x80 | opcode, 0xFF)) + struct.pack('>Q', len(data))
            timed_io(sock.sendall, prefix + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

        timed_io(sock.connect, ('127.0.0.1', 9222))
        key = base64.b64encode(os.urandom(16)).decode()
        timed_io(sock.sendall, (f'GET {url.path} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\n'
                      'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                      f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            if len(header) >= 8192:
                raise ValueError('CDP upgrade header too large')
            header.extend(read(1))
        lines = header.decode('ascii').split('\r\n')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        headers = {key.lower(): value.strip() for key, value in
                   (line.split(':', 1) for line in lines[1:] if ':' in line)}
        if lines[0].split()[:2] != ['HTTP/1.1', '101'] or headers.get('sec-websocket-accept') != accept:
            raise ConnectionError('CDP websocket upgrade rejected')
        send(json.dumps({'id': 1, 'method': method, 'params': params}).encode())
        chunks = bytearray()
        for _ in range(64):
            first, second = read(2)
            size = second & 127
            if size == 126:
                size = struct.unpack('>H', read(2))[0]
            elif size == 127:
                size = struct.unpack('>Q', read(8))[0]
            if second & 128 or size + len(chunks) > MAX_FRAME:
                raise ValueError('invalid/oversized CDP control frame')
            payload, opcode = read(size), first & 15
            if opcode == 8:
                raise ConnectionError('CDP websocket closed')
            if opcode == 9:
                if size > 125:
                    raise ValueError('oversized CDP ping')
                send(payload, 10)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1):
                raise ValueError('unexpected CDP opcode')
            chunks.extend(payload)
            if first & 128:
                response = json.loads(chunks)
                chunks.clear()
                if not isinstance(response, dict):
                    raise ValueError('invalid CDP response')
                if response.get('id') == 1:
                    if 'error' in response:
                        raise RuntimeError('CDP ' + method + ': ' + str(response['error'])[:256])
                    return response.get('result')
        raise TimeoutError('CDP control response missing')


def integer(value, low, high, field):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'invalid {field}')
    return value


def enabled(cmdline):
    values = [word.partition('=')[2] for word in cmdline.split()
              if word.startswith('bromure.shared_windows=')]
    if not values:
        return False
    if values != ['16']:
        raise ValueError('shared windows require exactly bromure.shared_windows=16')
    if any(word.startswith('bromure.experimental_multigpu=') for word in cmdline.split()):
        raise ValueError('shared windows and independent X screens are mutually exclusive')
    return True


def validate_topology(value, max_root_pixels=MAX_ROOT_PIXELS):
    """Validate before any RandR/browser side effect; missing outputs are off."""
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_SCANOUTS:
        raise ValueError('topology requires 1 through 16 entries')
    rows, scanouts, outputs, windows = [], set(), set(), set()
    fields = {'scanout', 'output', 'x', 'y', 'width', 'height', 'enabled', 'windowId'}
    for item in value:
        if not isinstance(item, dict) or item.keys() - fields:
            raise ValueError('invalid topology fields')
        index = integer(item.get('scanout'), 0, MAX_SCANOUTS - 1, 'scanout')
        output = item.get('output')
        if not isinstance(output, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', output):
            raise ValueError('invalid RandR output')
        if index in scanouts or output in outputs:
            raise ValueError('duplicate scanout or output')
        scanouts.add(index)
        outputs.add(output)
        if type(item.get('enabled')) is not bool:
            raise ValueError('invalid enabled')
        row = dict(item)
        if 'windowId' in row:
            wid = integer(row['windowId'], 1, SAFE_INTEGER, 'windowId')
            if wid in windows:
                raise ValueError('window assigned to multiple outputs')
            windows.add(wid)
        if row['enabled']:
            for axis in ('x', 'y'):
                integer(row.get(axis), 0, MAX_AXIS - 1, axis)
            for axis in ('width', 'height'):
                integer(row.get(axis), 64, MAX_AXIS, axis)
            if row['width'] % 8:
                raise ValueError('output width must be a multiple of 8')
            if row['width'] * row['height'] > MAX_OUTPUT_PIXELS:
                raise ValueError('output pixel budget exceeded')
            if row['x'] + row['width'] > MAX_AXIS or row['y'] + row['height'] > MAX_AXIS:
                raise ValueError('root axis budget exceeded')
        rows.append(row)
    active = [row for row in rows if row['enabled']]
    if not active:
        raise ValueError('at least one output must remain enabled')
    for i, first in enumerate(active):
        for second in active[i + 1:]:
            if (first['x'] < second['x'] + second['width'] and
                    second['x'] < first['x'] + first['width'] and
                    first['y'] < second['y'] + second['height'] and
                    second['y'] < first['y'] + first['height']):
                raise ValueError('overlapping outputs')
    root = {'width': max(row['x'] + row['width'] for row in active),
            'height': max(row['y'] + row['height'] for row in active)}
    if root['width'] * root['height'] > max_root_pixels:
        raise ValueError('root pixel budget exceeded')
    return sorted(rows, key=lambda row: row['scanout']), root


def group_targets(targets, window_for_target):
    """Map targets through CDP browser window IDs, never title/XID guesses.

    A disappeared/unresolved target is excluded rather than assigned to a
    different window. Callers reconcile again on the next observation.
    """
    groups, target_windows = {}, {}
    for target in targets:
        tid = target.get('id')
        if not isinstance(tid, str) or not re.fullmatch(r'[A-Za-z0-9-]+', tid):
            continue
        result = window_for_target(tid)
        if not isinstance(result, dict):
            continue
        wid = result.get('windowId')
        if type(wid) is not int or not 1 <= wid <= SAFE_INTEGER:
            continue
        groups.setdefault(wid, []).append(target)
        target_windows[tid] = wid
    return groups, target_windows


def active_by_window(groups, visibility, previous):
    """One active tab per window; visibility of other windows is unrelated."""
    active = {}
    for wid, targets in groups.items():
        ids = [target['id'] for target in targets]
        visible = [tid for tid in ids if visibility.get(tid) == 'visible']
        candidates = visible or ids
        if candidates:
            old = previous.get(wid)
            active[wid] = old if old in candidates else candidates[0]
    return active


def parse_randr(text):
    outputs, current = {}, None
    for line in text.splitlines():
        header = re.match(r'^(\S+) (connected|disconnected)\b(.*)', line)
        if header:
            name, status, rest = header.groups()
            geometry = re.search(r'\b(\d+)x(\d+)\+(\d+)\+(\d+)\b', rest)
            current = {'output': name, 'connected': status == 'connected', 'modes': [], 'rect': None}
            if geometry:
                width, height, x, y = map(int, geometry.groups())
                current['rect'] = dict(x=x, y=y, width=width, height=height)
            outputs[name] = current
        elif current is not None:
            connector = re.match(r'\s+CONNECTOR_ID:\s+(\d+)\s*$', line)
            mode = re.match(r'\s+(\d+x\d+\S*)\s+([\d.].*)$', line)
            if connector:
                current['connectorId'] = int(connector[1])
            elif mode:
                current['modes'].append(mode[1])
    return outputs


def discover_outputs(randr_text, sysfs=Path('/sys/class/drm')):
    """Match Xorg CONNECTOR_ID to one VirGL card's fixed scanout connectors.

    Xorg 21.1.12 modesetting drmmode_output_create_resources publishes the
    DRM object ID. Linux 6.8 virtgpu_modeset_init creates virtual connectors
    in scanout order. Their numeric type IDs need not start at one: the
    built-in VZ GPU can have allocated Virtual-1 before this custom GPU.
    """
    cards = []
    for card in sysfs.glob('card*'):
        if not re.fullmatch(r'card\d+', card.name):
            continue
        device = (card / 'device').resolve()
        for path in (device / 'features', *device.glob('virtio*/features')):
            try:
                bits = path.read_text().strip()
            except OSError:
                continue
            if len(bits) >= 32 and bits[0] == '1' and set(bits) <= {'0', '1'}:
                cards.append(card)
                break
    if len(cards) != 1:
        raise ValueError('shared windows require exactly one negotiated VirGL card')
    card = cards[0]
    connectors = []
    for path in sysfs.glob(card.name + '-Virtual-*'):
        suffix = path.name[len(card.name + '-Virtual-'):]
        if suffix.isascii() and suffix.isdigit():
            connectors.append((int(suffix), int((path / 'connector_id').read_text().strip())))
    connectors.sort()
    if not 2 <= len(connectors) <= MAX_SCANOUTS or len({cid for _, cid in connectors}) != len(connectors):
        raise ValueError('expected two through sixteen distinct scanout connectors')
    randr = parse_randr(randr_text)
    result = []
    for index, (suffix, connector) in enumerate(connectors):
        # DRM object IDs are per-device, so the inactive built-in GPU may
        # expose the same ID. The primary modesetting output's type suffix
        # must also match the verified custom-card sysfs connector.
        matches = [value for value in randr.values() if value.get('connectorId') == connector
                   and value['output'] == f'Virtual-{suffix}']
        if len(matches) != 1:
            raise ValueError(f'ambiguous or absent RandR connector {connector}')
        result.append(dict(matches[0], scanout=index, card='/dev/dri/' + card.name))
    return result


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON field')
        result[key] = value
    return result


def run_command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, LC_ALL='C'))
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr[:512]}')
    if len(result.stdout) > MAX_FRAME:
        raise ValueError('command output exceeds bound')
    return result.stdout


def x_focus_snapshot():
    """Read real X focus; run in a subprocess to bound even a hung X server.

    No activation, grabs, property writes or focus changes. The focused child
    must descend from the WM's active Chromium client, owned by its browser PID.
    """
    import ctypes as C
    x = C.CDLL('libX11.so.6')
    W, P = C.c_ulong, C.c_void_p
    for name, result, args in (
        ('XOpenDisplay', P, [C.c_char_p]), ('XCloseDisplay', C.c_int, [P]),
        ('XDefaultRootWindow', W, [P]), ('XInternAtom', W, [P, C.c_char_p, C.c_int]),
        ('XGetInputFocus', C.c_int, [P, C.POINTER(W), C.POINTER(C.c_int)]),
        ('XQueryTree', C.c_int, [P, W, C.POINTER(W), C.POINTER(W), C.POINTER(C.POINTER(W)), C.POINTER(C.c_uint)]),
        ('XGetWindowProperty', C.c_int, [P, W, W, C.c_long, C.c_long, C.c_int, W,
                                       C.POINTER(W), C.POINTER(C.c_int), C.POINTER(W), C.POINTER(W), C.POINTER(P)]),
        ('XFree', C.c_int, [P]),
    ):
        fn = getattr(x, name)
        fn.restype, fn.argtypes = result, args
    display = x.XOpenDisplay(None)
    if not display:
        raise RuntimeError('X display unavailable')
    try:
        def cardinal(window, name, kind):
            actual, fmt, count, remaining, data = W(), C.c_int(), W(), W(), P()
            atom = x.XInternAtom(display, name.encode(), True)
            expected = x.XInternAtom(display, kind.encode(), True)
            if not atom or not expected:
                return None
            status = x.XGetWindowProperty(display, window, atom, 0, 1, False, expected,
                                          C.byref(actual), C.byref(fmt), C.byref(count), C.byref(remaining), C.byref(data))
            try:
                if status or actual.value != expected or fmt.value != 32 or count.value != 1 or remaining.value:
                    return None
                return C.cast(data, C.POINTER(W))[0]
            finally:
                if data:
                    x.XFree(data)
        active = cardinal(x.XDefaultRootWindow(display), '_NET_ACTIVE_WINDOW', 'WINDOW')
        focused, revert = W(), C.c_int()
        x.XGetInputFocus(display, C.byref(focused), C.byref(revert))
        current, ancestors = focused.value, []
        for _ in range(64):
            if current in (0, 1) or current in ancestors:
                break
            ancestors.append(current)
            if current == active:
                pid = cardinal(current, '_NET_WM_PID', 'CARDINAL')
                if not pid:
                    break
                path = Path('/proc') / str(pid)
                command = path.joinpath('cmdline').read_bytes().split(b'\0')
                if path.joinpath('exe').resolve().name not in ('chromium', 'chrome') or any(a.startswith(b'--type=') for a in command):
                    break
                start = path.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]
                return dict(xWindow=active, xFocus=focused.value, browserPID=pid, browserStartTicks=int(start))
            root, parent, children, count = W(), W(), C.POINTER(W)(), C.c_uint()
            if not x.XQueryTree(display, current, C.byref(root), C.byref(parent), C.byref(children), C.byref(count)):
                break
            if children:
                x.XFree(children)
            current = parent.value
        return None
    finally:
        x.XCloseDisplay(display)


def confirm_focus(target, timeout):
    """Independent Chromium document and X focus observations, within a deadline."""
    deadline = time.monotonic() + timeout
    result = cdp_call(target.get('webSocketDebuggerUrl', ''), 'Runtime.evaluate',
                      {'expression': 'document.hasFocus() && document.visibilityState === "visible"',
                       'returnByValue': True}, timeout=max(.001, deadline - time.monotonic()))
    if not isinstance(result, dict) or 'exceptionDetails' in result or result.get('result', {}).get('value') is not True:
        return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('focus observation deadline exceeded')
    probe = subprocess.run([sys.executable, str(Path(__file__).resolve()), 'probe-focus'],
                           capture_output=True, text=True, timeout=remaining)
    if probe.returncode:
        raise RuntimeError('X focus observation failed: ' + probe.stderr[:256])
    return json.loads(probe.stdout)


class Controller:
    def __init__(self, list_targets, browser_call, scale=2, runner=run_command,
                 sysfs=Path('/sys/class/drm'), focus_observer=confirm_focus):
        self.list_targets, self.browser_call = list_targets, browser_call
        self.scale = integer(scale, 1, 4, 'display scale')
        self.run, self.sysfs = runner, sysfs
        self.focus_observer = focus_observer
        self.focus_evidence = None
        self.lock = threading.RLock()
        self.epoch = str(uuid.uuid4())
        self.version = 0
        self.expected_scanouts = None
        self.bindings = {}  # scanout -> Chromium window ID
        self.active = {}
        self.focused_window = None
        self.groups, self.target_windows = {}, {}
        self.last_id = 0
        self.replies = OrderedDict()
        self.last_outputs = []

    def call(self, method, params):
        result = self.browser_call(method, params)
        if not isinstance(result, dict):
            raise RuntimeError('CDP call failed: ' + method)
        return result

    def refresh(self, targets=None):
        targets = self.list_targets() if targets is None else targets
        if not isinstance(targets, list) or len(targets) > 256:
            raise ValueError('browser target count exceeds bound')
        deadline = time.monotonic() + 8

        def lookup(tid):
            if time.monotonic() >= deadline:
                raise TimeoutError('window grouping deadline exceeded')
            return self.call('Browser.getWindowForTarget', {'targetId': tid})

        groups, target_windows = group_targets(targets, lookup)
        self.groups, self.target_windows = groups, target_windows
        self.bindings = {index: wid for index, wid in self.bindings.items() if wid in groups}
        return groups, target_windows

    def outputs(self):
        rows = discover_outputs(self.run(['xrandr', '--query', '--props']), self.sysfs)
        if self.expected_scanouts is None or len(rows) != self.expected_scanouts:
            raise ValueError('connector count does not match expectedScanouts')
        self.last_outputs = rows
        return rows

    def state(self, observe=True):
        if observe:
            self.refresh()
            self.outputs()
        windows = []
        for wid, targets in sorted(self.groups.items()):
            item = {'windowId': wid, 'targetIds': [t['id'] for t in targets]}
            index = next((i for i, value in self.bindings.items() if value == wid), None)
            if index is not None:
                output = next((row for row in self.last_outputs if row['scanout'] == index), {})
                item.update(scanout=index, output=output.get('output'), rect=output.get('rect'))
            windows.append(item)
        active = [row['rect'] for row in self.last_outputs if row.get('rect')]
        return {'epoch': self.epoch, 'topologyVersion': self.version, 'windows': windows,
                'outputs': self.last_outputs,
                'root': {'width': max((r['x'] + r['width'] for r in active), default=0),
                         'height': max((r['y'] + r['height'] for r in active), default=0)}}

    def place(self, wid, rect):
        if any(rect[key] % self.scale for key in ('x', 'y', 'width', 'height')):
            raise ValueError('physical geometry must align with common display scale')
        bounds = dict(left=rect['x'] // self.scale, top=rect['y'] // self.scale,
                      width=rect['width'] // self.scale, height=rect['height'] // self.scale)
        self.call('Browser.setWindowBounds', {'windowId': wid, 'bounds': {'windowState': 'normal'}})
        self.call('Browser.setWindowBounds', {'windowId': wid, 'bounds': bounds})
        deadline = time.monotonic() + 3
        while True:
            actual = self.call('Browser.getWindowBounds', {'windowId': wid}).get('bounds', {})
            if all(actual.get(key) == value for key, value in bounds.items()):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError('Chromium window bounds did not converge')
            time.sleep(.05)

    def apply_topology(self, topology, prospective=None):
        rows, root = validate_topology(topology)
        for row in rows:
            if row['enabled'] and any(row[k] % self.scale for k in ('x', 'y', 'width', 'height')):
                raise ValueError('topology must align with common display scale')
        outputs = self.outputs()
        by_index = {row['scanout']: row for row in outputs}
        for row in rows:
            if row['scanout'] not in by_index or row['output'] != by_index[row['scanout']]['output']:
                raise ValueError('scanout/output identity mismatch')
            owner = (prospective or {}).get(row['scanout'], self.bindings.get(row['scanout']))
            if 'windowId' in row and owner != row['windowId']:
                raise ValueError('topology cannot reassign a browser window')
        # Wait for host-published preferred modes before attempting a modeset.
        deadline = time.monotonic() + 5
        while True:
            modes = {}
            for row in rows:
                if row['enabled']:
                    output = by_index[row['scanout']]
                    prefix = f"{row['width']}x{row['height']}"
                    mode = next((m for m in output['modes'] if re.match(re.escape(prefix) + r'(?:$|_)', m)), None)
                    if output['connected'] and mode:
                        modes[row['scanout']] = mode
            if len(modes) == sum(row['enabled'] for row in rows):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('host scanout mode not available')
            time.sleep(.1)
            by_index = {row['scanout']: row for row in self.outputs()}
        args = ['xrandr', '--fb', f"{root['width']}x{root['height']}"]
        active = {row['scanout']: row for row in rows if row['enabled']}
        for output in outputs:
            row = active.get(output['scanout'])
            args += ['--output', output['output']]
            if row is None:
                args += ['--off']
            else:
                args += ['--mode', modes[row['scanout']], '--pos', f"{row['x']}x{row['y']}"]
                if row['scanout'] == min(active):
                    args += ['--primary']
        self.run(args)
        self.version += 1  # RandR changed even if a later browser operation fails.
        actual = {row['scanout']: row['rect'] for row in self.outputs()}
        for output in outputs:
            wanted = active.get(output['scanout'])
            expected = {k: wanted[k] for k in ('x', 'y', 'width', 'height')} if wanted else None
            if actual.get(output['scanout']) != expected:
                raise RuntimeError('RandR geometry differs from requested topology')
        for row in active.values():
            wid = self.bindings.get(row['scanout'])
            if wid is not None:
                self.place(wid, row)
        return active

    def focus(self, wid, tid=None):
        targets = self.groups.get(wid)
        if not targets:
            raise ValueError('unknown browser window')
        ids = [target['id'] for target in targets]
        tid = tid or self.active.get(wid)
        tid = tid if tid in ids else ids[0]
        self.focused_window, self.focus_evidence = None, None
        self.call('Target.activateTarget', {'targetId': tid})
        processes = self.call('SystemInfo.getProcessInfo', {}).get('processInfo', [])
        browser_pids = [item.get('id') for item in processes if item.get('type') == 'browser']
        if len(browser_pids) != 1:
            raise RuntimeError('cannot identify sole CDP browser process')
        deadline = time.monotonic() + 3
        target = next(target for target in targets if target['id'] == tid)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Chromium/X focus did not converge')
            evidence = self.focus_observer(target, remaining)
            if evidence and evidence.get('browserPID') == browser_pids[0]:
                self.focus_evidence = evidence
                break
            time.sleep(min(.025, max(0, deadline - time.monotonic())))
        self.active[wid] = tid
        self.focused_window = wid
        return tid

    def new_tab(self, wid, url):
        url = navigation_url(url)
        self.refresh()
        self.focus(wid)
        result = self.call('Target.createTarget', {'url': url, 'newWindow': False})
        tid = result.get('targetId')
        owner = self.call('Browser.getWindowForTarget', {'targetId': tid})
        if owner.get('windowId') != wid:
            # Keep the real result available for reconciliation, never invent
            # ownership or silently close a tab which the browser just made.
            self.refresh()
            raise RuntimeError('new tab opened in a different browser window')
        self.active[wid] = tid
        self.refresh()
        return tid

    def execute(self, request):
        cmd = request['cmd']
        if cmd == 'list':
            return {}
        self.refresh()
        wid = request.get('windowId')
        if cmd in ('attachPrimary', 'create', 'resize'):
            index = integer(request.get('scanout'), 0, 15, 'scanout')
            rows, _ = validate_topology(request.get('topology'))
            if not any(row['scanout'] == index and row['enabled'] for row in rows):
                raise ValueError('requested scanout must be enabled')
            url = navigation_url(request.get('url', 'about:blank'))
            if cmd == 'attachPrimary':
                if wid is None:
                    if len(self.groups) != 1:
                        raise ValueError('attachPrimary requires explicit windowId when multiple windows exist')
                    wid = next(iter(self.groups))
                if wid not in self.groups or wid in self.bindings.values() or index in self.bindings:
                    raise ValueError('window or output is already bound or unknown')
            elif cmd == 'create' and (index in self.bindings or wid is not None):
                raise ValueError('create requires an unused scanout and no existing windowId')
            elif cmd == 'resize' and self.bindings.get(index) != wid:
                raise ValueError('resize window/scanout mismatch')
            active = self.apply_topology(request.get('topology'),
                                         {index: wid} if cmd == 'attachPrimary' else None)
            if cmd == 'create':
                result = self.call('Target.createTarget', {'url': url, 'newWindow': True})
                tid = result.get('targetId')
                wid = self.call('Browser.getWindowForTarget', {'targetId': tid}).get('windowId')
                integer(wid, 1, SAFE_INTEGER, 'created windowId')
                if wid in self.groups or wid in self.bindings.values():
                    raise RuntimeError('browser did not create a distinct window')
                self.active[wid] = tid
            self.bindings[index] = wid
            if cmd == 'attachPrimary':
                self.active.setdefault(wid, self.groups[wid][0]['id'])
            self.place(wid, active[index])
            return {'windowId': wid, 'targetId': self.active.get(wid)}
        integer(wid, 1, SAFE_INTEGER, 'windowId')
        if wid not in self.groups:
            raise ValueError('unknown browser window')
        if cmd == 'focus':
            return {'windowId': wid, 'targetId': self.focus(wid), 'focusEvidence': self.focus_evidence}
        if cmd == 'close':
            if 'topology' in request:
                validate_topology(request['topology'])
            # Closing only this window's tabs never sends Browser.close.
            for target in list(self.groups[wid]):
                result = self.call('Target.closeTarget', {'targetId': target['id']})
                if not result.get('success'):
                    raise RuntimeError('browser refused tab close')
            self.refresh()
            if wid in self.groups:
                raise RuntimeError('window close pending or refused')
            if 'topology' in request:
                self.apply_topology(request['topology'])
            return {'closedWindowId': wid}
        raise ValueError('unknown command')

    def handle(self, request):
        if not isinstance(request, dict):
            raise ValueError('request must be an object')
        rid = integer(request.get('id'), 1, SAFE_INTEGER, 'request id')
        canonical = json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False)
        with self.lock:
            if rid in self.replies:
                original, reply = self.replies[rid]
                if canonical != original:
                    raise ValueError('request id reused with different contents')
                return reply
            if rid <= self.last_id:
                raise ValueError('stale request id; reconcile using list with a new id')
            self.last_id = rid
            try:
                common = {'id', 'cmd', 'expectedScanouts'}
                fields = {'list': set(), 'attachPrimary': {'scanout', 'windowId', 'topology'},
                          'create': {'scanout', 'url', 'topology'},
                          'resize': {'scanout', 'windowId', 'topology'},
                          'close': {'windowId', 'topology'}, 'focus': {'windowId'}}
                if not isinstance(request.get('cmd'), str) or request['cmd'] not in fields or request.keys() - (common | fields[request['cmd']]):
                    raise ValueError('invalid request fields or command')
                if 'expectedScanouts' in request:
                    count = integer(request['expectedScanouts'], 2, 16, 'expectedScanouts')
                    if self.expected_scanouts is not None and count != self.expected_scanouts:
                        raise ValueError('expectedScanouts is immutable during controller lifetime')
                    self.expected_scanouts = count
                if self.expected_scanouts is None:
                    raise ValueError('initial request must include expectedScanouts')
                if 'windowId' in request:
                    integer(request['windowId'], 1, SAFE_INTEGER, 'windowId')
                result = self.execute(request)
                reply = dict(self.state(), **result, id=rid, ok=True, stateComplete=True)
            except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                try:
                    state, complete = self.state(), True
                except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
                    state, complete = self.state(observe=False), False
                reply = dict(state, id=rid, ok=False, error=str(error)[:512], stateComplete=complete)
            self.replies[rid] = canonical, reply
            while len(self.replies) > 128:
                self.replies.popitem(last=False)
            return reply

    def serve_connection(self, sock, address):
        if address[0] != getattr(socket, 'VMADDR_CID_HOST', 2):
            return
        pending = bytearray()
        while True:
            part = sock.recv(MAX_FRAME + 1)
            if not part:
                return
            pending.extend(part)
            while b'\n' in pending:
                line, _, rest = pending.partition(b'\n')
                pending = bytearray(rest)
                if len(line) > MAX_FRAME:
                    raise ValueError('oversized request')
                request = json.loads(line, object_pairs_hook=unique_fields)
                reply = self.handle(request)
                encoded = json.dumps(reply, separators=(',', ':'), allow_nan=False).encode() + b'\n'
                if len(encoded) > MAX_FRAME:
                    raise ValueError('reply exceeds bound')
                sock.sendall(encoded)
            if len(pending) > MAX_FRAME:
                raise ValueError('oversized request')

    def serve(self):
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as server:
            server.bind((socket.VMADDR_CID_ANY, PORT))
            server.listen(1)
            print('BROMURE_SHARED_WINDOWS_READY ' + self.epoch, flush=True)
            while True:
                sock, address = server.accept()
                with sock:
                    sock.settimeout(30)
                    try:
                        self.serve_connection(sock, address)
                    except (ValueError, OSError, RecursionError) as error:
                        print('shared windows disconnected: ' + str(error), flush=True)


def prepare_window_manager(home=Path.home()):
    import xml.etree.ElementTree as ET
    namespace = 'http://openbox.org/3.4/rc'
    ET.register_namespace('', namespace)
    for name in ('rc.xml', 'rc-nativetabs.xml'):
        path = home / '.config/openbox' / name
        if not path.is_file():
            continue
        tree = ET.parse(path)
        for node in tree.findall(f'.//{{{namespace}}}maximized'):
            node.text = 'false'
        for node in tree.findall(f'.//{{{namespace}}}followMouse'):
            node.text = 'no'
        tree.write(path, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['probe-focus']:
        print(json.dumps(x_focus_snapshot()))
        raise SystemExit(0)
    if sys.argv[1:] != ['prepare-wm'] or not enabled(Path('/proc/cmdline').read_text()):
        raise SystemExit('shared_windows.py prepare-wm requires explicit boot opt-in')
    prepare_window_manager()
