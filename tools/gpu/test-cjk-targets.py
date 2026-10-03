#!/usr/bin/env python3
"""Shared-window input routing and bounded transport regressions."""
import importlib.util
import json
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts'
sys.path.insert(0, str(SCRIPTS))
import shared_windows
spec = importlib.util.spec_from_file_location('cjk_agent', SCRIPTS / 'cjk-input-agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

class TargetTests(unittest.TestCase):
    def setUp(self):
        self.cdp = agent.CDPClient(shared=True)
        self.pages = [dict(id=x, type='page', webSocketDebuggerUrl=f'ws://127.0.0.1:9222/devtools/page/{x}')
                      for x in ('first', 'second')]
        self.sockets = []
        def connection(*args):
            sock = Mock()
            self.sockets.append(sock)
            return sock
        self.patches = [patch.object(agent.CDPClient, 'get_json', side_effect=lambda path, deadline:
                             self.pages if path == '/json' else dict(webSocketDebuggerUrl='ws://127.0.0.1:9222/devtools/browser/owner')),
                        patch.object(shared_windows, 'cdp_call', return_value=dict(processInfo=[dict(type='browser', id=77)])),
                        patch.object(agent, 'ws_connect', side_effect=connection),
                        patch.object(agent, 'ws_send'),
                        patch.object(agent, 'ws_recv', return_value=json.dumps(dict(id=0, result=dict(result=dict(value=2))))),
                        patch.object(agent.threading, 'Thread')]
        self.mocks = [p.start() for p in self.patches]
        for p in self.patches:
            self.addCleanup(p.stop)

    def test_switch_reuses_exact_target_and_closes_previous(self):
        agent.handle_message(self.cdp, dict(type='commit', text='道', targetId='second'))
        self.assertEqual(self.mocks[2].call_args.args[0], self.pages[1]['webSocketDebuggerUrl'])
        first = self.cdp.sock
        agent.handle_message(self.cdp, dict(type='wheel', x=80, y=40, deltaY=2, targetId='second'))
        self.assertEqual(len(self.sockets), 1)
        sent = json.loads(self.mocks[3].call_args.args[1])
        self.assertEqual(sent['params']['x'], 40)
        self.assertEqual(sent['params']['y'], 20)
        agent.handle_message(self.cdp, dict(type='commit', text='a', targetId='first'))
        first.shutdown.assert_called_once_with(socket.SHUT_RDWR)
        first.close.assert_called_once()
        self.assertEqual(self.cdp.target_id, 'first')
        self.assertEqual(len(self.sockets), 2)

    def test_invalid_or_stale_target_never_falls_back(self):
        for target in (None, '', 4, True, '../first', 'a'*129, 'gone'):
            with self.subTest(target=target):
                self.cdp.select_target('first')
                before = self.mocks[3].call_count
                with self.assertRaises((ValueError, RuntimeError)):
                    agent.handle_message(self.cdp, dict(type='commit', text='wrong', targetId=target))
                self.assertIsNone(self.cdp.sock)
                self.assertEqual(self.mocks[3].call_count, before)

    def test_rejects_foreign_endpoint_and_ambiguous_browser(self):
        self.pages[1]['webSocketDebuggerUrl'] = 'ws://192.0.2.1:9222/devtools/page/second'
        with self.assertRaises(ValueError):
            self.cdp.select_target('second')
        self.mocks[2].assert_not_called()
        self.mocks[1].return_value = dict(processInfo=[dict(type='browser', id=1), dict(type='browser', id=2)])
        with self.assertRaises(ValueError):
            self.cdp.select_target('first')
        self.mocks[2].assert_not_called()

    def test_failed_probe_closes_connection_and_blocks_input(self):
        self.mocks[4].side_effect = socket.timeout('stalled')
        with self.assertRaises(socket.timeout):
            agent.handle_message(self.cdp, dict(type='commit', text='wrong', targetId='second'))
        self.assertIsNone(self.cdp.sock)
        messages = [json.loads(call.args[1]) for call in self.mocks[3].call_args_list]
        self.assertEqual([msg['method'] for msg in messages], ['Runtime.evaluate'])

    def test_legacy_keeps_first_page_without_target(self):
        self.cdp = agent.CDPClient()
        self.cdp.connect()
        agent.handle_message(self.cdp, dict(type='commit', text='legacy'))
        self.assertEqual(self.mocks[2].call_args.args[0], self.pages[0]['webSocketDebuggerUrl'])
        self.mocks[1].assert_not_called()

class DeadlineTests(unittest.TestCase):
    def test_partial_http_body_has_wall_deadline(self):
        server = socket.socket()
        self.addCleanup(server.close)
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        server.settimeout(1)
        done = threading.Event()
        def serve():
            with server.accept()[0] as conn:
                conn.settimeout(1)
                conn.recv(4096)
                conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n[')
                done.wait(.5)
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        started = time.monotonic()
        try:
            with patch.object(agent, 'CDP_PORT', server.getsockname()[1]):
                with self.assertRaises((TimeoutError, socket.timeout, agent.http.client.IncompleteRead)):
                    agent.CDPClient.get_json('/json', started + .08)
            self.assertLess(time.monotonic() - started, .5)
        finally:
            done.set()
            thread.join(1)

    def test_upgrade_timeout_closes_socket(self):
        left, right = socket.socketpair()
        self.addCleanup(right.close)
        proxy = Mock(wraps=left)
        proxy.connect = Mock()
        started = time.monotonic()
        with patch.object(agent.socket, 'socket', return_value=proxy):
            with self.assertRaises((TimeoutError, socket.timeout)):
                agent.ws_connect('ws://127.0.0.1:9222/devtools/page/a', started + .08)
        self.assertLess(time.monotonic() - started, .5)
        self.assertEqual(left.fileno(), -1)

    def test_partial_frame_respects_deadline(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        right.sendall(b'\x81\x10abc')
        started = time.monotonic()
        with self.assertRaises((TimeoutError, socket.timeout)):
            agent.ws_recv(left, started + .08)
        self.assertLess(time.monotonic() - started, .5)

if __name__ == '__main__':
    unittest.main()
