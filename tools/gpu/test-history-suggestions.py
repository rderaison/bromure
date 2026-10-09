#!/usr/bin/env python3
"""Profile-local Chromium History reads through the real tab-agent handler."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts/tab-agent.py'
spec = importlib.util.spec_from_file_location('history_tab_agent', SOURCE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.profile = self.root / 'profile'
        self.path = self.profile / 'Default' / 'History'
        self.path.parent.mkdir(parents=True)
        env = patch.dict(os.environ, PROFILE_DIR=str(self.profile))
        env.start(); self.addCleanup(env.stop)
        self.db = sqlite3.connect(str(self.path))
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, '
                        'visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)')
        self.db.commit()

    def add(self, url, title='', visits=1, typed=0, last=1, hidden=0):
        self.db.execute('INSERT INTO urls(url,title,visit_count,typed_count,last_visit_time,hidden) '
                        'VALUES(?,?,?,?,?,?)', (url, title, visits, typed, last, hidden))
        self.db.commit()

    def query(self, text, **fields):
        link = Mock()
        agent.handle_cmd(dict(cmd='query_history', request_id='window2-query7', query=text, **fields), {}, link)
        link.send.assert_called_once()
        response = link.send.call_args[0][0]
        self.assertEqual(response['event'], 'history_suggestions')
        self.assertEqual(response['request_id'], 'window2-query7')
        return response

    def test_prefix_typed_recency_and_title_ranking_readonly(self):
        self.add('https://other.test/path', 'Example article', typed=100, last=999)
        self.add('https://example.test/recent', 'Recent', typed=1, last=20)
        self.add('https://example.test/typed', 'Typed', typed=2, last=10)
        self.add('https://example.test/hidden', hidden=1, typed=1000)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        result = self.query('EXAMPLE')
        self.assertEqual(result['status'], 'ok')
        self.assertEqual([x['title'] for x in result['items']], ['Typed', 'Recent', 'Example article'])
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertFalse((self.profile / 'bromure-history.db').exists())

    def test_literal_wildcards_sql_and_unicode(self):
        self.add('https://example.test/percent%_literal', 'Straße 日本')
        self.add('https://example.test/other')
        for term in ('%_', 'STRASSE', '日本'):
            self.assertEqual(len(self.query(term)['items']), 1)
        self.assertEqual(self.query("' OR 1=1 --")['items'], [])

    def test_wal_commits_visible_deletion_not_cached(self):
        self.db.execute('PRAGMA journal_mode=WAL')
        self.add('https://wal.test/live', 'Committed')
        self.assertEqual(len(self.query('wal.test')['items']), 1)
        self.db.execute('INSERT INTO urls(url,title,hidden) VALUES(?,?,0)', ('https://wal.test/uncommitted', 'Pending'))
        self.assertEqual(len(self.query('wal.test')['items']), 1)
        self.db.rollback()
        self.db.execute('DELETE FROM urls'); self.db.commit()
        self.assertEqual(self.query('wal.test')['items'], [])

    def test_profile_isolation_missing_db_does_not_create(self):
        self.add('https://secret.test/profile-one')
        other = self.root / 'other'
        other.mkdir()
        with patch.dict(os.environ, PROFILE_DIR=str(other)):
            reply = self.query('secret')
        self.assertEqual(reply['status'], 'unavailable')
        self.assertEqual(reply['items'], [])
        self.assertEqual(list(other.iterdir()), [])

    def test_locked_database_bounded_and_recovers(self):
        self.add('https://example.test')
        self.db.execute('BEGIN EXCLUSIVE')
        start = time.monotonic()
        reply = self.query('example')
        self.assertLess(time.monotonic() - start, .5)
        self.assertNotEqual(reply['status'], 'ok')
        self.assertEqual(reply['items'], [])
        self.db.rollback()
        self.assertEqual(len(self.query('example')['items']), 1)

    def test_large_database_query_budget(self):
        self.db.executemany('INSERT INTO urls(url,title,hidden) VALUES(?,?,0)',
                            (('https://large.test/' + str(i), 'x' * 100) for i in range(80000)))
        self.db.commit()
        start = time.monotonic()
        reply = self.query('does-not-exist')
        self.assertLess(time.monotonic() - start, .7)
        self.assertEqual(reply['items'], [])
        self.assertIn(reply['status'], ('ok', 'timeout', 'unavailable'))
        # Force the actual SQLite progress callback over its deadline; avoid
        # assuming any particular machine needs >100ms for the same database.
        with patch.object(agent.time, 'monotonic', side_effect=[0, 1, 1]):
            reply = self.query('does-not-exist')
        self.assertEqual(reply['status'], 'timeout')

    def test_validation_limits_and_response_bytes(self):
        for query, limit in [('x'*513, 8), ('x\n', 8), ([], 8), ('x', True), ('x', 11), ('x', 0)]:
            self.assertEqual(self.query(query, limit=limit)['status'], 'invalid')
        self.assertEqual(self.query(' ')['items'], [])
        for i in range(12):
            self.add('https://long.test/' + str(i) + '日'*7000, '本'*16000)
        reply = self.query('long', limit=10)
        self.assertLess(len(json.dumps(reply).encode()), 32768)

    def test_only_navigable_web_urls_without_credentials(self):
        for url in ['javascript:alert(1)', 'file:///secret', 'https://user:pass@example.test',
                    'https://example.test/\nheader', 'https://[invalid', 'http:///missing']:
            self.add(url, 'match')
        self.add('https://good.test/', 'match')
        # Malformed rows must not prevent a later valid result.
        result = self.query('match')
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['items'], [{'url': 'https://good.test/', 'title': 'match'}])


if __name__ == '__main__':
    unittest.main()
