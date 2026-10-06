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
import subprocess
import os
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts/shared_windows.py'
spec = importlib.util.spec_from_file_location('shared_windows', PATH)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def output(index, x, y=0, width=1920, height=1252):
    return dict(scanout=index, output=f'Virtual-{index + 1}', x=x, y=y,
                width=width, height=height, enabled=True)


class Tests(unittest.TestCase):
    def test_shared_boot_starts_internal_cdp_without_enabling_external_automation(self):
        source = PATH.with_name('xinitrc').read_text()
        # Execute the actual startup block with only its process launcher stubbed.
        block = source.split('# Internal CDP is also needed', 1)[1].split('if [ "$NATIVE_CHROME"', 1)[0]
        block = '# Internal CDP is also needed' + block
        block = block.replace('/usr/local/bin/resilient-launch.sh', 'launch')
        for automation, shared_mode, lan, expected in (
            ('0', '0', '1', []), ('', '0', '', []),
            ('0', '1', '1', ['cdp-agent.py']), ('', '1', '', ['cdp-agent.py']),
            ('1', '0', '0', ['cdp-agent.py']),
            ('1', '0', '1', ['cdp-agent.py', 'cdp-lan-forwarder.py']),
            ('1', '1', '1', ['cdp-agent.py', 'cdp-lan-forwarder.py']),
        ):
            with self.subTest(automation=automation, shared=shared_mode, lan=lan):
                script = 'launch() { printf "%s\\n" "$1"; };\n' + block + '\nwait\nprintf "AUTOMATION=%s\\n" "$AUTOMATION"\n'
                result = subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=3,
                                        env=dict(os.environ, AUTOMATION=automation,
                                                 _SHARED_WINDOWS=shared_mode, CDP_LAN_ACCESS=lan), check=True)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[-1], 'AUTOMATION=' + automation)
                self.assertEqual(sorted(Path(line).name for line in lines[:-1]), sorted(expected))

    def test_navigation_policy(self):
        for url in ('about:blank', 'about:blank#section', 'https://example.com/a%20b',
                    'http://127.0.0.1:8080/', 'http://[::1]:8080/', 'chrome://history/',
                    'chrome://bookmarks/', 'chrome://gpu', 'chrome://newtab/'):
            self.assertEqual(shared.navigation_url(url), url)
        for url in ('javascript:alert(1)', 'data:text/html,test', 'file:///etc/passwd',
                    'chrome://crash/', 'chrome-untrusted://new-tab-page/', 'https://',
                    'https://example.com:invalid/', 'https://exa mple.com/',
                    'java\nscript:alert(1)', ' https://example.com', 'about:config',
                    'https://example.com/' + 'x' * 8192, None, 42):
            with self.subTest(url=str(url)[:60]), self.assertRaises(ValueError):
                shared.navigation_url(url)
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

    def test_expanded_root_preserves_output_and_axis_limits(self):
        layout = [output(0, 0, width=4096, height=8192),
                  output(1, 4096, width=4096, height=8192)]
        with self.assertRaisesRegex(ValueError, 'root pixel'):
            shared.validate_topology(layout)
        _, root = shared.validate_topology(layout, shared.NEGOTIATED_ROOT_PIXELS)
        self.assertEqual(root, dict(width=8192, height=8192))
        for rows in ([output(0, 0, width=8192, height=8192)],
                     [output(0, 8191, width=64, height=64)]):
            with self.assertRaises(ValueError):
                shared.validate_topology(rows, shared.NEGOTIATED_ROOT_PIXELS)
        for limit in (True, None, '67108864', 67108864.0, 33554433, 67108865):
            with self.assertRaises(ValueError):
                shared.validate_topology(layout, limit)

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
        self.controller = shared.Controller(lambda: [dict(id=t, webSocketDebuggerUrl=f'ws://127.0.0.1:9222/devtools/page/{t}')
                                                      for t in self.targets], self.call,
                                            runner=self.command, sysfs=self.root,
                                            focus_observer=lambda target, timeout: {'xWindow': 50, 'browserPID': 123},
                                            page_call=self.page_call)

    def page_call(self, url, method, params, timeout):
        self.assertEqual(method, 'Page.bringToFront')
        self.assertEqual(params, {})
        self.assertLessEqual(timeout, 3)
        tid = url.rsplit('/', 1)[1]
        self.focused = self.targets[tid]
        self.calls.append((method, {'targetId': tid}))
        return {}

    def command(self, args):
        if '--query' in args:
            lines = []
            for index in range(2):
                rect = self.rects[index]
                geometry = (f" {rect['width']}x{rect['height']}+{rect['x']}+{rect['y']}" if rect else '')
                lines.append(f'Virtual-{index + 2} connected{geometry}\n\tCONNECTOR_ID: {100 + index}\n   1920x1252 60.00*+\n   4096x8192 60.00')
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
        if method == 'SystemInfo.getProcessInfo':
            return {'processInfo': [{'type': 'browser', 'id': 123}]}
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
        self.assertEqual(reply['shutdownProtocolVersion'], 1)
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

    def test_root_limit_negotiation_is_immutable_and_defaults_to_32(self):
        self.attach()
        self.assertEqual(self.controller.root_pixel_limit, shared.MAX_ROOT_PIXELS)
        before = len(self.mutations)
        response = self.controller.handle(dict(id=3, cmd='list', rootPixelLimit=67108864))
        self.assertFalse(response['ok'])
        self.assertEqual(response['rootPixelLimit'], 33554432)
        self.assertEqual(len(self.mutations), before)
        self.assertTrue(self.controller.handle(dict(id=4, cmd='list', rootPixelLimit=33554432))['ok'])
        big = [output(i, i*4096, width=4096, height=8192) | {'output': f'Virtual-{i+2}'} for i in range(2)]
        for rid, fields in enumerate((dict(cmd='create', scanout=1),
                                      dict(cmd='resize', scanout=0, windowId=10),
                                      dict(cmd='attachPrimary', scanout=1),
                                      dict(cmd='close', windowId=10)), 5):
            reply = self.controller.handle(dict(id=rid, topology=big, **fields))
            self.assertFalse(reply['ok'], reply)
            self.assertIn('root pixel budget', reply['error'])
        self.assertEqual(len(self.mutations), before)
        self.assertEqual(self.targets, {'a':10})

    def test_opt_in_64_applies_to_all_topology_mutations_and_replay(self):
        request = dict(id=1, cmd='list', expectedScanouts=2, rootPixelLimit=67108864)
        reply = self.controller.handle(request)
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['rootPixelLimit'], 67108864)
        self.assertEqual(self.controller.handle(request), reply)
        layout = [output(i, i*4096, width=4096, height=8192) | {'output': f'Virtual-{i+2}'} for i in range(2)]
        for rid, fields in ((2, dict(cmd='attachPrimary', scanout=0)),
                            (3, dict(cmd='create', scanout=1)),
                            (4, dict(cmd='resize', scanout=1, windowId=20))):
            reply = self.controller.handle(dict(id=rid, topology=layout, **fields))
            self.assertTrue(reply['ok'], reply)
            self.assertEqual(reply['root'], dict(width=8192, height=8192))
        self.assertFalse(self.controller.handle(dict(id=5, cmd='list', rootPixelLimit=33554432))['ok'])
        # Preserve a64MiPixel bounding box including a gap after closing output1.
        remaining = [dict(layout[0], x=4096)]
        reply = self.controller.handle(dict(id=6, cmd='close', windowId=20, topology=remaining))
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['rootPixelLimit'], 67108864)
        self.assertEqual(reply['root'], dict(width=8192, height=8192))
        self.assertEqual(self.targets, {'a':10})

    def test_bad_initial_root_negotiation_does_not_pin_other_fields(self):
        for rid, limit in enumerate((True, '67108864', 67108864.0, 0, 67108865), 1):
            reply = self.controller.handle(dict(id=rid, cmd='list', expectedScanouts=2, rootPixelLimit=limit))
            self.assertFalse(reply['ok'])
            self.assertIsNone(self.controller.expected_scanouts)
            self.assertIsNone(self.controller.root_pixel_limit)
        reply = self.controller.handle(dict(id=6, cmd='attachPrimary', expectedScanouts=2,
                                            rootPixelLimit=67108864, scanout=0, topology=self.layout(1)))
        self.assertFalse(reply['ok'])
        self.assertIsNone(self.controller.expected_scanouts)
        self.assertEqual(self.mutations, [])
        reply = self.controller.handle(dict(id=7, cmd='list', expectedScanouts=2, rootPixelLimit=67108864))
        self.assertTrue(reply['ok'], reply)

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

    def test_focus_ack_requires_observation_and_failure_clears_cached_focus(self):
        self.attach()
        evidence = {'xWindow': 51, 'xFocus': 52, 'browserPID': 123, 'browserStartTicks': 42}
        observer = unittest.mock.Mock(side_effect=[dict(evidence, browserPID=999), evidence])
        self.controller.focus_observer = observer
        before = len(self.calls)
        reply = self.controller.handle(dict(id=3, cmd='focus', windowId=10))
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(reply['focusEvidence'], evidence)
        self.assertEqual(observer.call_count, 2)
        focus_calls = [(method, params) for method, params in self.calls[before:]
                       if method in ('Target.activateTarget', 'Page.bringToFront', 'SystemInfo.getProcessInfo')]
        self.assertEqual(focus_calls, [('Target.activateTarget', {'targetId': 'a'}),
                                      ('Page.bringToFront', {'targetId': 'a'}),
                                      ('SystemInfo.getProcessInfo', {})])
        self.controller.focus_observer = unittest.mock.Mock(side_effect=TimeoutError('X focus stalled'))
        reply = self.controller.handle(dict(id=4, cmd='focus', windowId=10))
        self.assertFalse(reply['ok'])
        self.assertIsNone(self.controller.focused_window)
        self.assertIsNone(self.controller.focus_evidence)
        before = len(self.calls)
        with self.assertRaises(TimeoutError):
            self.controller.new_tab(10, 'about:blank')
        self.assertFalse(any(method == 'Target.createTarget' for method, _ in self.calls[before:]))

    def test_placement_observes_restore_before_numeric_bounds(self):
        pending = [False]
        reads = [0]
        self.bounds[10]['windowState'] = 'maximized'
        original = self.controller.browser_call
        def delayed(method, params):
            if method == 'Browser.setWindowBounds':
                if 'windowState' in params['bounds']:
                    pending[0] = True
                    return {}
                self.assertEqual(self.bounds[10]['windowState'], 'normal')
            if method == 'Browser.getWindowBounds' and pending[0]:
                reads[0] += 1
                if reads[0] == 2:
                    self.bounds[10]['windowState'] = 'normal'
            return original(method, params)
        self.controller.browser_call = delayed
        self.controller.place(10, self.layout(1)[0])
        self.assertGreaterEqual(reads[0], 2)
        self.assertEqual(self.bounds[10]['height'], 626)

    def test_close_reconciles_disappeared_target_without_replaying_close(self):
        self.attach()
        created = self.controller.handle(dict(id=3, cmd='create', scanout=1, topology=self.layout()))
        self.assertTrue(created['ok'], created)
        original = self.controller.browser_call
        stale = []
        live_list = self.controller.list_targets
        def call(method, params):
            if method == 'Target.closeTarget':
                stale.extend(live_list())
            if method == 'Browser.getWindowForTarget' and params['targetId'] not in self.targets:
                raise shared.CDPError(method, dict(code=-32000, message='No target with given id'))
            return original(method, params)
        def listing():
            if stale:
                result = list(stale)
                stale.clear()
                return result
            return live_list()
        self.controller.browser_call = call
        self.controller.list_targets = listing
        reply = self.controller.handle(dict(id=4, cmd='close', windowId=10))
        self.assertTrue(reply['ok'], reply)
        self.assertTrue(reply['stateComplete'])
        self.assertEqual([w['windowId'] for w in reply['windows']], [created['windowId']])
        self.assertEqual(sum(method == 'Target.closeTarget' for method, _ in self.calls), 1)

    def test_unresolved_and_unrelated_lookup_errors_preserve_cached_ownership(self):
        self.attach()
        old_groups, old_bindings = dict(self.controller.groups), dict(self.controller.bindings)
        for message, attempts in (('No target with given id', 3), ('Permission denied', 1)):
            failing = unittest.mock.Mock(side_effect=shared.CDPError(
                'Browser.getWindowForTarget', dict(code=-32000, message=message)))
            self.controller.browser_call = failing
            with self.assertRaises(RuntimeError):
                self.controller.refresh()
            self.assertEqual(failing.call_count, attempts)
            self.assertEqual(self.controller.groups, old_groups)
            self.assertEqual(self.controller.bindings, old_bindings)

    def test_target_added_during_snapshot_is_mapped_before_commit(self):
        self.attach()
        original = self.controller.browser_call
        added = [False]
        def call(method, params):
            if method == 'Browser.getWindowForTarget' and not added[0]:
                added[0] = True
                self.targets['b'] = 20
                self.bounds[20] = dict(self.bounds[10])
            return original(method, params)
        self.controller.browser_call = call
        groups, mapping = self.controller.refresh()
        self.assertEqual(mapping, {'a': 10, 'b': 20})
        self.assertEqual(set(groups), {10, 20})

    def test_restore_timeout_does_not_send_geometry_and_reports_evidence(self):
        self.controller.browser_call = unittest.mock.Mock(return_value={'bounds': {'windowState': 'maximized'}})
        with patch.object(shared.time, 'monotonic', side_effect=[0, 4]):
            with self.assertRaisesRegex(RuntimeError, '"phase": "restore"') as failure:
                self.controller.place(10, self.layout(1)[0])
        self.assertIn('"requested":', str(failure.exception))
        self.assertIn('"observed":', str(failure.exception))
        sets = [call.args[1]['bounds'] for call in self.controller.browser_call.call_args_list
                if call.args[0] == 'Browser.setWindowBounds']
        self.assertEqual(sets, [{'windowState': 'normal'}])

    def test_page_focus_failure_blocks_ack_and_new_tab(self):
        self.attach()
        observer = unittest.mock.Mock()
        self.controller.focus_observer = observer
        self.controller.page_call = unittest.mock.Mock(side_effect=TimeoutError('page focus stalled'))
        reply = self.controller.handle(dict(id=3, cmd='focus', windowId=10))
        self.assertFalse(reply['ok'])
        self.assertIsNone(self.controller.focused_window)
        self.assertIsNone(self.controller.focus_evidence)
        observer.assert_not_called()
        before = len(self.calls)
        with self.assertRaises(TimeoutError):
            self.controller.new_tab(10, 'about:blank')
        self.assertFalse(any(method == 'Target.createTarget' for method, _ in self.calls[before:]))

    def test_focus_probe_checks_document_and_bounds_x_subprocess(self):
        target = {'webSocketDebuggerUrl': 'ws://127.0.0.1:9222/devtools/page/a'}
        with patch.object(shared, 'cdp_call', return_value={'result': {'value': False}}), \
                patch.object(shared.subprocess, 'run') as probe:
            self.assertIsNone(shared.confirm_focus(target, .1))
            probe.assert_not_called()
        with patch.object(shared, 'cdp_call', return_value={'result': {'value': True}}), \
                patch.object(shared.subprocess, 'run', side_effect=subprocess.TimeoutExpired('X', .1)) as probe:
            with self.assertRaises(subprocess.TimeoutExpired):
                shared.confirm_focus(target, .1)
            self.assertLessEqual(probe.call_args.kwargs['timeout'], .1)

    def test_invalid_url_precedes_layout_and_browser_mutation(self):
        self.attach()
        before_modes, before_calls = len(self.mutations), len(self.calls)
        reply = self.controller.handle(dict(id=3, cmd='create', scanout=1,
                                            topology=self.layout(), url='javascript:alert(1)'))
        self.assertFalse(reply['ok'])
        self.assertEqual(len(self.mutations), before_modes)
        self.assertFalse(any(method == 'Target.createTarget' for method, _ in self.calls[before_calls:]))
        before_calls = len(self.calls)
        with self.assertRaises(ValueError):
            self.controller.new_tab(10, 'file:///etc/passwd')
        self.assertEqual(len(self.calls), before_calls)

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
    def test_legacy_socket_timeout_normalized_for_all_io(self):
        class LegacyTimeout(OSError):
            pass

        for stage in ('connect', 'sendall', 'recv'):
            class TimedOutSocket:
                def __enter__(self): return self
                def __exit__(self, *_): pass
                def settimeout(self, value): pass
                def __getattr__(self, name):
                    def operation(*args):
                        if name == stage:
                            raise LegacyTimeout('timed out')
                    return operation

            with self.subTest(stage=stage), \
                    patch.object(shared.socket, 'socket', return_value=TimedOutSocket()), \
                    patch.object(shared.socket, 'timeout', LegacyTimeout):
                with self.assertRaises(TimeoutError) as raised:
                    shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {})
                self.assertIsInstance(raised.exception.__cause__, LegacyTimeout)

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
        for result in ({'result': {'windowId': 10}}, {'error': {'code': -1, 'message': 'refused'}},
                       {'error': {'code': -32000, 'message': 'No target with given id'}}):
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
                        with self.assertRaises(shared.CDPError) as raised:
                            shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {})
                        self.assertEqual(raised.exception.code, result['error']['code'])
                        self.assertEqual(raised.exception.message, result['error']['message'])
                        self.assertEqual(raised.exception.method, 'Browser.getWindowForTarget')
                    else:
                        self.assertEqual(shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {}), result['result'])
                thread.join(timeout=2)
                self.assertFalse(thread.is_alive())

    def test_worker_domain_is_enabled_on_same_connection_before_start(self):
        for denied in (False, True):
            with self.subTest(denied=denied):
                client, server = self.socket()
                methods, failures = [], []
                def read_exact(count):
                    data = bytearray()
                    while len(data) < count:
                        part = server.recv(count - len(data))
                        if not part: raise ConnectionError('client closed')
                        data.extend(part)
                    return bytes(data)
                def read_json():
                    first, second = read_exact(2)
                    size = second & 127
                    if size == 126: size = int.from_bytes(read_exact(2), 'big')
                    mask = read_exact(4)
                    raw = read_exact(size)
                    return json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(raw)))
                def answer(value):
                    data = json.dumps(value).encode()
                    server.sendall(bytes((129, len(data))) + data)
                def serve():
                    try:
                        server.settimeout(2)
                        header = bytearray()
                        while not header.endswith(b'\r\n\r\n'): header.extend(read_exact(1))
                        key = next(line.split(b':', 1)[1].strip() for line in header.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:'))
                        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                        server.sendall(b'HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
                        methods.append(read_json())
                        if denied:
                            answer({'id': 0, 'error': {'code': -1, 'message': 'denied'}})
                        else:
                            answer({'id': 0, 'result': {}})
                            methods.append(read_json())
                            answer({'id': 1, 'result': {}})
                    except Exception as error: failures.append(error)
                thread = threading.Thread(target=serve); thread.start()
                with patch.object(shared.socket, 'socket', return_value=client):
                    if denied:
                        with self.assertRaises(shared.CDPError) as failure:
                            shared.cdp_call('ws://127.0.0.1:9222/devtools/page/test', 'ServiceWorker.startWorker', {'scopeURL': 'chrome-extension://test/'})
                        self.assertEqual(failure.exception.method, 'ServiceWorker.enable')
                    else:
                        self.assertEqual(shared.cdp_call('ws://127.0.0.1:9222/devtools/page/test', 'ServiceWorker.startWorker', {'scopeURL': 'chrome-extension://test/'}), {})
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive()); self.assertEqual(failures, [])
                self.assertEqual([item['method'] for item in methods], ['ServiceWorker.enable'] if denied else ['ServiceWorker.enable', 'ServiceWorker.startWorker'])

    def test_upgrade_has_wall_deadline_and_endpoint_is_local(self):
        client, server = self.socket()
        with patch.object(shared.socket, 'socket', return_value=client):
            with self.assertRaises(TimeoutError):
                shared.cdp_call('ws://127.0.0.1:9222/devtools/browser/test', 'Browser.getWindowForTarget', {}, timeout=.02)
        with self.assertRaises(ValueError):
            shared.cdp_call('ws://example.com:9222/devtools/browser/test', 'Browser.getWindowForTarget', {})


class TabDetachTests(unittest.TestCase):
    attach = ControllerTests.attach
    layout = ControllerTests.layout
    command = ControllerTests.command

    def setUp(self):
        ControllerTests.setUp(self)
        self.extension_mutations = 0
        self.worker_available = True
        self.fail_after_move = False
        self.attach()
        self.targets = {'A' * 32: 10, 'B' * 32: 10}

    def call(self, method, params):
        if method == 'Target.getTargets':
            return {'targetInfos': [dict(type='service_worker', targetId='C' * 32,
                    url='chrome-extension://dllblhgbnjchoipknlflefkgfjlblkmf/background.js')] if self.worker_available else []}
        return ControllerTests.call(self, method, params)

    def page_call(self, url, method, params, timeout):
        if method == 'ServiceWorker.startWorker':
            self.assertEqual(params['scopeURL'], 'chrome-extension://dllblhgbnjchoipknlflefkgfjlblkmf/')
            self.worker_available = True
            return {}
        if method != 'Runtime.evaluate':
            return ControllerTests.page_call(self, url, method, params, timeout)
        self.assertEqual(url, 'ws://127.0.0.1:9222/devtools/page/' + 'C' * 32)
        self.assertIn('chrome.windows.create({tabId: tab.id', params['expression'])
        self.assertIn('tab.windowId !== 10', params['expression'])
        self.extension_mutations += 1
        self.targets['A' * 32] = 20
        self.bounds[20] = dict(left=0, top=0, width=500, height=300, windowState='normal')
        if self.fail_after_move:
            raise OSError('reply lost')
        return {'result': {'value': {'windowId': 20}}}

    def request(self, **updates):
        rows = self.layout()
        rows[0]['windowId'] = 10
        return dict(id=3, cmd='detach', windowId=10, targetId='A' * 32,
                    scanout=1, topology=rows, **updates)

    def test_detach_preserves_target_and_source_and_deduplicates(self):
        request = self.request()
        answer = self.controller.handle(request)
        self.assertTrue(answer['ok'], answer)
        self.assertEqual(answer['targetId'], 'A' * 32)
        self.assertEqual(answer['windowId'], 20)
        self.assertEqual(self.targets['B' * 32], 10)
        self.assertEqual(self.controller.bindings, {0: 10, 1: 20})
        self.assertEqual(self.controller.handle(request), answer)
        self.assertEqual(self.extension_mutations, 1)
        self.assertFalse(any(method in ('Target.createTarget', 'Target.closeTarget') for method, _ in self.calls))

    def test_lost_mutation_reply_observes_existing_target_without_replay(self):
        self.fail_after_move = True
        answer = self.controller.handle(self.request())
        self.assertTrue(answer['ok'], answer)
        self.assertEqual(self.extension_mutations, 1)

    def test_sleeping_worker_restarts_without_creating_page(self):
        self.worker_available = False
        answer = self.controller.handle(self.request())
        self.assertTrue(answer['ok'], answer)
        self.assertEqual(self.extension_mutations, 1)

    def test_invalid_detach_has_no_mutation(self):
        for change in ({'targetId': 'D' * 32}, {'targetId': 'bad'}, {'windowId': 20}, {'scanout': 0}):
            request = self.request(); request.update(change)
            before = len(self.mutations)
            answer = self.controller.handle(request)
            self.assertFalse(answer['ok'], answer)
            self.assertEqual(len(self.mutations), before)
            self.assertEqual(self.extension_mutations, 0)
            self.controller.last_id = 2
            self.controller.replies.clear()

    def test_last_tab_cannot_remove_source_owner(self):
        self.targets.pop('B' * 32)
        answer = self.controller.handle(self.request())
        self.assertFalse(answer['ok'], answer)
        self.assertEqual(self.extension_mutations, 0)


if __name__ == '__main__':
    unittest.main()
