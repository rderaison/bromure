#!/usr/bin/env python3
"""Terminal owner shutdown: identity, bounded exit, no mutation replay."""
import importlib.util
from pathlib import Path
import json
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[2]/'Sources/SandboxEngine/Resources/vm-setup/scripts/shared_windows.py'
spec = importlib.util.spec_from_file_location('shared_shutdown', SOURCE)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


class Tests(unittest.TestCase):
    def test_endpoint_discovery_bounds_slow_response_and_rejects_nonobject(self):
        # Actual loopback socket verifies the wall timer stops a trickle which
        # would continually reset a normal per-read socket timeout.
        for trickle in (False, True):
            server = socket.socket()
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(('127.0.0.1', 9222));server.listen(1);server.settimeout(1)
            stop = threading.Event()
            def respond():
                try:
                    client, _ = server.accept()
                    with client:
                        client.settimeout(1)
                        client.recv(4096)
                        if not trickle:
                            client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]')
                        else:
                            client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n')
                            while not stop.wait(.01):
                                client.sendall(b' ')
                except OSError:
                    pass
            worker = threading.Thread(target=respond)
            worker.start()
            started = time.monotonic()
            try:
                with self.assertRaises(TimeoutError if trickle else RuntimeError):
                    shared.shutdown_endpoint(timeout=.15)
                self.assertLess(time.monotonic()-started, .7)
            finally:
                stop.set();server.close();worker.join(2)
                self.assertFalse(worker.is_alive())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = dict(pid=123, startTicks=456, bootId='96000ff9-fd63-4c46-ab0f-94afd7453635')
        self.methods = []
        self.alive = True
        self.close_error = None
        self.exit_on_close = True
        self.normal = Mock(side_effect=AssertionError('no normal CDP/snapshot on shutdown'))
        self.endpoint = Mock(return_value='ws://127.0.0.1:9222/devtools/browser/pinned')
        self.identify = Mock(return_value=self.identity)
        self.controller = shared.Controller(self.normal, self.normal, runner=self.normal,
            quit_endpoint=self.endpoint, quit_rpc=self.rpc, identify_browser=self.identify,
            browser_running=lambda identity: self.alive, shutdown_dir=self.root)

    def rpc(self, endpoint, method, params, timeout):
        self.assertEqual(endpoint, self.endpoint.return_value)
        self.assertEqual(params, {})
        self.assertLessEqual(timeout, 3)
        self.methods.append(method)
        if method == 'SystemInfo.getProcessInfo':
            return {'processInfo': [{'type': 'browser', 'id': 123}, {'type': 'GPU', 'id': 124}]}
        self.assertEqual(method, 'Browser.close')
        self.assertEqual(json.loads((self.root/'shared-shutdown-requested').read_text())['browser'], self.identity)
        self.alive = not self.exit_on_close
        if self.close_error:
            raise self.close_error
        return {}

    def test_exit_ack_epoch_and_no_replay_or_post_snapshot(self):
        self.controller.focused_window = 10
        self.controller.focus_evidence = {'old': True}
        reply = self.controller.handle({'id': 1, 'cmd': 'shutdown'})
        self.assertTrue(reply['ok'] and reply['shutdownRequested'] and reply['exited'])
        self.assertTrue(reply['closeAcknowledged'] and reply['terminal'])
        self.assertFalse(reply['stateComplete'])
        self.assertEqual(reply['browser'], self.identity)
        self.assertEqual(reply['epoch'], self.controller.epoch)
        self.assertIsNone(self.controller.focused_window)
        self.assertIsNone(self.controller.focus_evidence)
        self.assertEqual(reply, self.controller.handle({'id': 1, 'cmd': 'shutdown'}))
        second = self.controller.handle({'id': 2, 'cmd': 'shutdown'})
        self.assertEqual(second['browser'], self.identity)
        self.assertEqual(self.methods, ['SystemInfo.getProcessInfo', 'Browser.close'])
        self.assertTrue(self.controller.handle({'id': 3, 'cmd': 'list'})['exited'])
        self.assertFalse(self.controller.handle({'id': 4, 'cmd': 'focus', 'windowId': 10})['ok'])
        with self.assertRaises(RuntimeError):
            self.controller.new_tab(123, 'about:blank')
        self.normal.assert_not_called()

    def test_lost_close_ack_observes_exit_without_reissuing(self):
        self.close_error = ConnectionError('browser closed socket')
        reply = self.controller.handle({'id': 1, 'cmd': 'shutdown'})
        self.assertTrue(reply['ok'] and reply['exited'])
        self.assertFalse(reply['closeAcknowledged'])
        self.assertIn('closed socket', reply['closeError'])
        self.controller.handle({'id': 2, 'cmd': 'shutdown'})
        self.assertEqual(self.methods.count('Browser.close'), 1)

    def test_exit_timeout_is_not_flush_evidence_and_never_replays(self):
        self.exit_on_close = False
        clock = [100.0]
        def sleep(seconds):
            clock[0] += seconds
        with patch.object(shared.time, 'monotonic', lambda: clock[0]), patch.object(shared.time, 'sleep', sleep):
            reply = self.controller.handle({'id': 1, 'cmd': 'shutdown'})
        self.assertFalse(reply['ok'] or reply['exited'])
        self.assertTrue(reply['closeAcknowledged'])
        self.assertAlmostEqual(clock[0], 108.0)
        self.controller.handle({'id': 2, 'cmd': 'shutdown'})
        self.assertEqual(self.methods.count('Browser.close'), 1)
        self.alive = False
        reconciled = self.controller.handle({'id': 3, 'cmd': 'list'})
        self.assertTrue(reconciled['exited'])
        self.assertIn('deadline', reconciled['initialObservationError'])

    def test_failed_identity_and_extra_fields_do_not_close(self):
        for fields in ({'windowId': 1}, {'topology': []}, {'expectedScanouts': 2}, {'rootPixelLimit': 33554432}):
            reply = self.controller.handle(dict(id=self.controller.last_id+1, cmd='shutdown', **fields))
            self.assertFalse(reply['ok'])
        self.assertEqual(self.methods, [])
        self.identify.side_effect = RuntimeError('not a browser')
        reply = self.controller.handle({'id': 10, 'cmd': 'shutdown'})
        self.assertFalse(reply['ok'] or reply['terminal'])
        self.assertEqual(self.methods, ['SystemInfo.getProcessInfo'])
        self.assertFalse((self.root/'shared-shutdown-requested').exists())

    def test_multiple_browsers_do_not_close(self):
        self.controller.quit_rpc = Mock(return_value={'processInfo': [
            {'type': 'browser', 'id': 123}, {'type': 'browser', 'id': 999}]})
        reply = self.controller.handle({'id': 1, 'cmd': 'shutdown'})
        self.assertFalse(reply['ok'])
        self.identify.assert_not_called()
        self.assertEqual(self.controller.quit_rpc.call_count, 1)

    def test_process_identity_handles_flattened_child_pid_reuse_and_zombie(self):
        process = self.root/'123'
        process.mkdir()
        exe = self.root/'chromium'
        exe.touch()
        (process/'exe').symlink_to(exe)
        boot = self.root/'sys/kernel/random'
        boot.mkdir(parents=True)
        (boot/'boot_id').write_text(self.identity['bootId'])
        def stat(start=456, state='S'):
            (process/'stat').write_text('123 (chromium name) ' + ' '.join([state]+['0']*18+[str(start)]))
        stat()
        (process/'cmdline').write_bytes(b'/usr/lib/chromium/chromium --user-data-dir=/home/chrome/.UUID\0\0')
        self.assertEqual(shared.browser_identity(123, self.root), self.identity)
        self.assertTrue(shared.browser_alive(self.identity, self.root))
        (process/'cmdline').write_bytes(b'/proc/self/exe --type=gpu-process --foo=bar\0')
        with self.assertRaises(RuntimeError):
            shared.browser_identity(123, self.root)
        stat(start=457)
        self.assertFalse(shared.browser_alive(self.identity, self.root))
        stat(state='Z')
        self.assertFalse(shared.browser_alive(self.identity, self.root))
        (process/'stat').write_text('broken')
        with self.assertRaises(ValueError):
            shared.browser_alive(self.identity, self.root)
        (process/'stat').unlink()
        self.assertFalse(shared.browser_alive(self.identity, self.root))

    def test_reply_delivery_marker_only_after_send(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close);self.addCleanup(right.close)
        left.settimeout(1);right.settimeout(1)
        request = json.dumps({'id': 1, 'cmd': 'shutdown'}).encode()+b'\n'
        right.sendall(request);right.shutdown(socket.SHUT_WR)
        self.controller.serve_connection(left, (getattr(socket, 'VMADDR_CID_HOST', 2), 1234))
        reply = json.loads(right.recv(65536))
        self.assertTrue(reply['exited'])
        self.assertTrue((self.root/'shared-shutdown-replied').exists())

    def test_shared_quick_exit_suppresses_relaunch_and_wait_is_bounded(self):
        source = SOURCE.with_name('xinitrc').read_text()
        block = source[source.index('    # Explicit shared-owner quit'):source.index('    now_ts=$(date +%s)')]
        block = block.replace('/tmp/bromure/', str(self.root)+'/')
        for shared_mode, requested, replied, wanted_calls, wanted_waits in (
            ('1', True, False, 1, 20), ('1', True, True, 1, 0),
            ('0', True, False, 2, 0), ('1', False, False, 2, 0)):
            for name, present in [('requested', requested), ('replied', replied)]:
                path = self.root/('shared-shutdown-'+name)
                if present:path.touch()
                else:path.unlink(missing_ok=True)
            script = 'sleep() { echo wait; }; _SHARED_WINDOWS='+shared_mode+';\nfor attempt in 1 2; do\necho launch\n'+block+'\ndone'
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=1, check=True)
            self.assertEqual(result.stdout.splitlines().count('launch'), wanted_calls)
            self.assertEqual(result.stdout.splitlines().count('wait'), wanted_waits)


if __name__ == '__main__':
    unittest.main()
