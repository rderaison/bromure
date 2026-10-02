#!/usr/bin/env python3
"""Side-effect-free layout and browser-window routing regressions."""
import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
import socket
import threading
import hashlib
import base64
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts/shared_windows.py'
spec = importlib.util.spec_from_file_location('shared_windows', PATH)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def output(index, x, y=0, width=1920, height=1252):
    return dict(scanout=index, output=f'Virtual-{index + 1}', x=x, y=y,
                width=width, height=height, enabled=True)


class Tests(unittest.TestCase):
    def test_explicit_opt_in_and_profile_experiment_exclusion(self):
        self.assertFalse(shared.enabled('quiet ro'))
        self.assertTrue(shared.enabled('quiet bromure.shared_windows=16 ro'))
        for args in ('bromure.shared_windows=2', 'bromure.shared_windows=16 bromure.shared_windows=16',
                     'bromure.shared_windows=16 bromure.experimental_multigpu=2'):
            with self.assertRaises(ValueError):
                shared.enabled(args)

    def test_two_outputs_and_sixteen_packed(self):
        rows, root = shared.validate_topology([output(1, 1920), output(0, 0)])
        self.assertEqual(root, dict(width=3840, height=1252))
        self.assertEqual([r['scanout'] for r in rows], [0, 1])
        rows, root = shared.validate_topology([
            output(i, (i % 4) * 1920, (i // 4) * 1080, height=1080) for i in range(16)])
        self.assertEqual(root, dict(width=7680, height=4320))

    def test_budget_uses_bounding_rectangle_including_gaps(self):
        for rows in ([output(0, 8192)], [output(0, 0, width=8192, height=8192)],
                     [output(0, 0, width=64, height=64), output(1, 8128, 8128, 64, 64)]):
            with self.assertRaises(ValueError):
                shared.validate_topology(rows)

    def test_bad_layouts_reject_without_mutation(self):
        for rows in ([], [output(0, 0), output(1, 100)], [output(0, 0), output(0, 1920)],
                     [output(16, 0)], [output(True, 0)], [output(0, 0, width=1921)],
                     [output(0, 0) | {'profileId': 'other'}],
                     [output(0, 0) | {'enabled': False}],
                     [output(0, 0) | {'windowId': 2}, output(1, 1920) | {'windowId': 2}]):
            original = repr(rows)
            with self.assertRaises(ValueError):
                shared.validate_topology(rows)
            self.assertEqual(repr(rows), original)

    def test_grouping_same_titles_and_multiple_visible_tabs(self):
        targets = [dict(id=tid, title='identical') for tid in ('a', 'b', 'c', 'gone')]
        mapping = {'a': {'windowId': 10}, 'b': {'windowId': 10}, 'c': {'windowId': 20}}
        groups, ids = shared.group_targets(targets, mapping.get)
        self.assertEqual(ids, dict(a=10, b=10, c=20))
        self.assertEqual(shared.active_by_window(groups, dict(a='hidden', b='visible', c='visible'), {10:'a'}),
                         {10:'b', 20:'c'})
        # Moving a tab to another browser window changes its group.
        mapping['b'] = {'windowId': 20}
        groups, ids = shared.group_targets(targets, mapping.get)
        self.assertEqual(ids['b'], 20)
        self.assertEqual(shared.active_by_window(groups, {}, {20:'c'}), {10:'a', 20:'c'})

    def test_scanout_identity_uses_custom_card_ids_and_numeric_order(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, bits in (('card0', '0'), ('card1', '1')):
                (root / name / 'device').mkdir(parents=True)
                (root / name / 'device/features').write_text(bits + '0' * 63)
            text = 'Virtual-1-1 connected\n\tCONNECTOR_ID: 100\n'
            # The built-in GPU owns type ID1; custom scanout0 starts at2.
            for index in range(16):
                path = root / f'card1-Virtual-{index + 2}'
                path.mkdir()
                (path / 'connector_id').write_text(str(100 + index))
                text += (f'Virtual-{index + 2} connected 1920x1252+{index * 1920}+0\n'
                         f'\tCONNECTOR_ID: {100 + index}\n   1920x1252 60.00*+\n')
            rows = shared.discover_outputs(text, root)
            self.assertEqual(rows[0]['output'], 'Virtual-2')
            self.assertEqual(rows[8]['output'], 'Virtual-10')
            self.assertEqual(rows[-1]['scanout'], 15)
            self.assertTrue(all(row['card'] == '/dev/dri/card1' for row in rows))
            with self.assertRaisesRegex(ValueError, 'absent'):
                shared.discover_outputs(text.replace('CONNECTOR_ID: 100', 'CONNECTOR_ID: 999'), root)
            (root / 'card0/device/features').write_text('1' + '0' * 63)
            with self.assertRaisesRegex(ValueError, 'exactly one'):
                shared.discover_outputs(text, root)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'card1/device').mkdir(parents=True)
        (self.root / 'card1/device/features').write_text('1' + '0' * 63)
        for index in range(2):
            path = self.root / f'card1-Virtual-{index + 2}'
            path.mkdir()
            (path / 'connector_id').write_text(str(100 + index))
        self.rects = {0: dict(x=0, y=0, width=1920, height=1252), 1: None}
        self.targets = {'a': 10}
        self.bounds = {10: dict(left=0, top=0, width=960, height=626, windowState='normal')}
        self.focused = 10
        self.calls, self.mutations = [], []
        self.fail_bounds = False
        self.controller = shared.Controller(lambda: [dict(id=t) for t in self.targets], self.call,
                                            runner=self.command, sysfs=self.root)

    def command(self, args):
        if '--query' in args:
            lines = []
            for index in range(2):
                rect = self.rects[index]
                geometry = (f" {rect['width']}x{rect['height']}+{rect['x']}+{rect['y']}" if rect else '')
                lines.append(f'Virtual-{index + 2} connected{geometry}\n\tCONNECTOR_ID: {100 + index}\n   1920x1252 60.00*+')
            return '\n'.join(lines)
        self.mutations.append(args)
        for index in range(2):
            offset = args.index(f'Virtual-{index + 2}')
            if args[offset + 1] == '--off':
                self.rects[index] = None
            else:
                width, height = map(int, args[offset + 2].split('x'))
                x, y = map(int, args[offset + 4].split('x'))
                self.rects[index] = dict(x=x, y=y, width=width, height=height)
        return ''

    def call(self, method, params):
        self.calls.append((method, params))
        if method == 'Browser.getWindowForTarget':
            wid = self.targets[params['targetId']]
            return dict(windowId=wid, bounds=self.bounds[wid])
        if method == 'Browser.getWindowBounds':
            return dict(bounds=self.bounds[params['windowId']])
        if method == 'Browser.setWindowBounds':
            if self.fail_bounds:
                raise RuntimeError('placement unavailable')
            self.bounds[params['windowId']].update(params['bounds'])
            return {}
        if method == 'Target.activateTarget':
            self.focused = self.targets[params['targetId']]
            return {}
        if method == 'Target.createTarget':
            if params['newWindow']:
                wid = max(self.bounds) + 10
                self.bounds[wid] = dict(left=0, top=0, width=500, height=300)
            else:
                wid = self.focused
            tid = 'new-' + str(len(self.calls))
            self.targets[tid] = wid
            return dict(targetId=tid)
        if method == 'Target.closeTarget':
            self.targets.pop(params['targetId'])
            return dict(success=True)
        raise AssertionError(method)

    def layout(self, count=2):
        return [output(i, i * 1920) | {'output': f'Virtual-{i + 2}'} for i in range(count)]

    def attach(self):
        reply = self.controller.handle(dict(id=1, cmd='list', expectedScanouts=2))
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['outputs'][0]['output'], 'Virtual-2')
        layout = self.layout(1)
        layout[0]['windowId'] = 10
        reply = self.controller.handle(dict(id=2, cmd='attachPrimary', scanout=0, topology=layout))
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['windowId'], 10)
        self.assertEqual(reply['targetId'], 'a')

    def test_single_browser_create_focus_new_tab_close_and_idempotence(self):
        self.attach()
        request = dict(id=3, cmd='create', scanout=1, topology=self.layout())
        reply = self.controller.handle(request)
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['windowId'], 20)
        before = len(self.calls)
        self.assertEqual(reply, self.controller.handle(request))
        self.assertEqual(len(self.calls), before)
        for rid, wid in ((4, 10), (5, 20), (6, 10)):
            self.assertTrue(self.controller.handle(dict(id=rid, cmd='focus', windowId=wid))['ok'])
            self.assertEqual(self.focused, wid)
        tid = self.controller.new_tab(20, 'about:blank')
        self.assertEqual(self.targets[tid], 20)
        self.assertTrue(self.controller.handle(dict(id=7, cmd='close', windowId=20, topology=self.layout(1)))['ok'])
        self.assertEqual(self.targets, {'a': 10})
        self.assertFalse(any(method == 'Browser.close' for method, _ in self.calls))

    def test_invalid_topology_never_modesets_or_creates_browser_window(self):
        self.attach()
        before_modes, before_targets = len(self.mutations), dict(self.targets)
        bad = self.layout()
        bad[1]['x'] = 100
        reply = self.controller.handle(dict(id=3, cmd='create', scanout=1, topology=bad))
        self.assertFalse(reply['ok'])
        self.assertEqual(len(self.mutations), before_modes)
        self.assertEqual(self.targets, before_targets)
        self.assertFalse(self.controller.handle(dict(id=4, cmd='list', expectedScanouts=16))['ok'])
        with self.assertRaises(ValueError):
            self.controller.handle(dict(id=3, cmd='list'))

    def test_partial_failure_reports_actual_geometry_and_created_window(self):
        self.attach()
        # Fail the new window placement after RandR succeeds; preserve actual
        # output geometry and ownership instead of claiming rollback/success.
        original = self.controller.place
        self.controller.place = lambda wid, row: (original(wid, row) if wid == 10 else
                                                  (_ for _ in ()).throw(RuntimeError('placement unavailable')))
        reply = self.controller.handle(dict(id=3, cmd='create', scanout=1, topology=self.layout()))
        self.assertFalse(reply['ok'])
        self.assertTrue(reply['stateComplete'])
        self.assertEqual(reply['root']['width'], 3840)
        self.assertEqual({w['windowId'] for w in reply['windows']}, {10, 20})

    def test_wire_fragmentation_peer_gate_duplicates_and_size_bound(self):
        class Stream:
            def __init__(self, chunks):
                self.chunks = iter(chunks)
                self.sent = []
            def recv(self, size):
                return next(self.chunks, b'')
            def sendall(self, data):
                self.sent.append(json.loads(data))
        stream = Stream([b'{"id":1,"cmd":"list",', b'"expectedScanouts":2}\n'])
        self.controller.serve_connection(stream, (2, 10))
        self.assertTrue(stream.sent[0]['ok'])
        untrusted = Stream([b'not JSON\n'])
        self.controller.serve_connection(untrusted, (5, 10))
        self.assertEqual(untrusted.sent, [])
        for chunks in ([b'{"id":2,"id":3,"cmd":"list"}\n'], [b'x' * (shared.MAX_FRAME + 1)]):
            with self.assertRaises(ValueError):
                self.controller.serve_connection(Stream(chunks), (2, 10))


class CDPTests(unittest.TestCase):
    def socket(self):
        client, server = socket.socketpair()
        self.addCleanup(server.close)
        self.addCleanup(client.close)

        class Connected:
            def __enter__(self): return self
            def __exit__(self, *_): client.close()
            def __getattr__(self, name): return getattr(client, name)
            def connect(self, address): pass
        return Connected(), server

    def test_real_fragmented_rpc_and_explicit_cdp_error(self):
        for result in ({'result': {'windowId': 10}}, {'error': {'code': -1, 'message': 'refused'}}):
            with self.subTest(result=result):
                client, server = self.socket()

                def serve():
                    server.settimeout(2)
                    header = bytearray()
                    while not header.endswith(b'\r\n\r\n'):
                        header.extend(server.recv(1))
                    key = next(line.split(b':', 1)[1].strip() for line in header.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:'))
                    accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                    server.sendall(b'HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
                    server.recv(4096)
                    data = json.dumps({'id': 1, **result}).encode()
                    server.sendall(bytes((1, 5)) + data[:5] + bytes((128, len(data) - 5)) + data[5:])

                thread = threading.Thread(target=serve)
                thread.start()
                with patch.object(shared.socket, 'socket', return_value=client):
                    if 'error' in result:
                        with self.assertRaisesRegex(RuntimeError, 'refused'):
                            shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {})
                    else:
                        self.assertEqual(shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {}), result['result'])
                thread.join(timeout=2)
                self.assertFalse(thread.is_alive())

    def test_upgrade_has_wall_deadline_and_endpoint_is_local(self):
        client, server = self.socket()
        with patch.object(shared.socket, 'socket', return_value=client):
            with self.assertRaises(TimeoutError):
                shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {}, timeout=.02)
        with self.assertRaises(ValueError):
            shared.cdp_call('ws://example.com:9222/devtools/browser/test', 'Browser.getWindowForTarget', {})


if __name__ == '__main__':
    unittest.main()
