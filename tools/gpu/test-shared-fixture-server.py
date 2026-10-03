#!/usr/bin/env python3
"""Real-socket checks for the diagnostic HTTP fixture's bounded concurrency."""
import http.client
import importlib.util
from pathlib import Path
import queue
import socket
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('fixture', Path(__file__).with_name('guest-shared-window-lifecycle.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class FixtureTests(unittest.TestCase):
    def test_flattened_profile_is_exact_uuid_mount_or_fails(self):
        path = '/home/chrome/.C3D89033-06A4-4321-B9C3-603F2E1246EE'
        self.assertEqual(fixture.profile_directory(['/usr/lib/chromium/chromium --user-agent=two words --user-data-dir=' + path + ' --no-first-run', '']),
                         (path, 'flattened'))
        self.assertEqual(fixture.profile_directory(['/usr/lib/chromium/chromium', '--user-data-dir=' + path, '']), (path, 'argv'))
        self.assertEqual(fixture.profile_directory(['chromium --no-first-run', '']), (None, 'flattened'))
        for value in ('/tmp/unknown', '"' + path + '"', path + '/suffix', path + ' --user-data-dir=' + path):
            with self.subTest(value=value), self.assertRaises((ValueError, AssertionError)):
                fixture.profile_directory(['chromium --user-data-dir=' + value])

    def start_server(self, limit=16, sequential=False):
        ready = queue.Queue()
        class Handler(fixture.FixtureHandler):
            def setup(self):
                super().setup()
                ready.put(True)
        if sequential:
            class Server(fixture.http.server.HTTPServer):
                def get_request(self):
                    client, address = super().get_request()
                    client.settimeout(1)
                    return client, address
        else:
            class Server(fixture.FixtureServer):
                max_clients = limit
        server = Server(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        thread.start()
        def cleanup():
            server.shutdown()
            server.server_close()
            thread.join(2)
            self.assertFalse(thread.is_alive())
        self.addCleanup(cleanup)
        return server, ready

    def idle(self, server, ready):
        client = socket.create_connection(server.server_address, timeout=.5)
        self.addCleanup(client.close)
        ready.get(timeout=.5)
        return client

    def test_idle_preconnects_do_not_delay_fixture(self):
        server, ready = self.start_server()
        for _ in range(8):
            self.idle(server, ready)
        conn = http.client.HTTPConnection(*server.server_address, timeout=.5)
        self.addCleanup(conn.close)
        start = time.monotonic()
        conn.request('GET', '/fixture/test')
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), fixture.HTML)
        self.assertLess(time.monotonic() - start, .5)

    def test_previous_serial_server_blocks_behind_idle_socket(self):
        server, ready = self.start_server(sequential=True)
        idle = self.idle(server, ready)
        conn = http.client.HTTPConnection(*server.server_address, timeout=.08)
        self.addCleanup(conn.close)
        conn.request('GET', '/fixture/test')
        with self.assertRaises(socket.timeout):
            conn.getresponse()
        # Release both sockets before server cleanup.
        conn.close()
        idle.close()

    def test_worker_cap_rejects_excess_and_idle_timeout_releases_slots(self):
        server, ready = self.start_server(limit=2)
        first = self.idle(server, ready)
        second = self.idle(server, ready)
        extra = socket.create_connection(server.server_address, timeout=.5)
        self.addCleanup(extra.close)
        self.assertEqual(extra.recv(1), b'')
        first.settimeout(1.5)
        second.settimeout(1.5)
        self.assertEqual(first.recv(1), b'')
        self.assertEqual(second.recv(1), b'')
        # Acquiring both permits waits for the workers' finally clauses.
        self.assertTrue(server.slots.acquire(timeout=.5))
        self.assertTrue(server.slots.acquire(timeout=.5))
        server.slots.release()
        server.slots.release()
        conn = http.client.HTTPConnection(*server.server_address, timeout=.5)
        self.addCleanup(conn.close)
        conn.request('GET', '/fixture/recovered')
        self.assertEqual(conn.getresponse().read(), fixture.HTML)

if __name__ == '__main__':
    unittest.main()
