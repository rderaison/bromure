#!/usr/bin/env python3
"""Phased private-image acceptance; never creates/closes windows or injects input.

Run `serve --seconds 900` in background as chrome, then `prepare --state FILE`.
Host performs production input/tab/window operations between the check-* phases.
Cookie verification after an actual browser restart requires --after-restart;
without that flag, every check requires the exact original browser PID/starttime.
This is a diagnostic fixture, not installed in production images.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import uuid

sys.path.insert(0, '/usr/local/bin')
try:
    from shared_windows import cdp_call
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts'))
    from shared_windows import cdp_call

PORT = 8766
ORIGIN = 'http://127.0.0.1:' + str(PORT)
HTML = b'''<!doctype html><meta charset=utf-8><title>Bromure shared profile fixture</title>
<style>body{margin:0;background:#25814b;height:2500px}input{position:fixed;left:20px;top:20px;width:70%;height:50px}</style>
<input id=entry autocomplete=off><script>
window.fixtureEvents=[];
for(const type of ['pointerdown','pointerup','click','keydown','keyup','wheel'])
addEventListener(type,e=>{if(fixtureEvents.length<512)fixtureEvents.push({type,key:e.key||null,x:e.clientX,y:e.clientY,t:performance.now()})},true);
</script>'''


def get(path):
    with urllib.request.urlopen('http://127.0.0.1:9222/' + path, timeout=3) as r:
        return json.load(r)


def processes():
    rows = []
    for directory in Path('/proc').glob('[0-9]*'):
        try:
            if directory.joinpath('exe').resolve().name not in ('chrome', 'chromium'):
                continue
            command = directory.joinpath('cmdline').read_bytes().decode(errors='replace').split('\0')
            if any('--type=' in arg for arg in command):
                continue
            stat = directory.joinpath('stat').read_text().rsplit(')', 1)[1].split()
            profile = next((arg.split('=', 1)[1] for arg in command if arg.startswith('--user-data-dir=')), None)
            rows.append(dict(pid=int(directory.name), startTicks=int(stat[19]), command=command, profile=profile))
        except OSError:
            continue
    assert len(rows) == 1, rows
    return rows[0]


def pages():
    browser = get('json/version')['webSocketDebuggerUrl']
    rows = []
    for page in get('json/list'):
        if page['type'] == 'page':
            wid = cdp_call(browser, 'Browser.getWindowForTarget', {'targetId': page['id']})['windowId']
            rows.append(dict(page, windowId=wid))
    return rows


def evaluate(page, expression):
    reply = cdp_call(page['webSocketDebuggerUrl'], 'Runtime.evaluate',
                     {'expression': expression, 'returnByValue': True})
    assert 'exceptionDetails' not in reply, reply
    return reply['result'].get('value')


def navigate(page, token):
    url = ORIGIN + '/fixture/' + token
    reply = cdp_call(page['webSocketDebuggerUrl'], 'Page.navigate', {'url': url})
    assert not reply.get('errorText'), reply
    deadline = time.monotonic() + 10
    while True:
        if evaluate(page, 'location.href === ' + json.dumps(url) + ' && document.readyState === "complete" && !!document.querySelector("#entry")'):
            return
        assert time.monotonic() < deadline, 'fixture navigation deadline'
        time.sleep(.05)


def cookie_check(page, state):
    result = evaluate(page, '({cookie:document.cookie, storage:localStorage.getItem("bromureSharedFixture")})')
    assert ('bromureSharedFixture=' + state['token']) in result['cookie'].split('; '), result
    assert result['storage'] == state['token'], result
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['serve', 'prepare', 'check-input', 'check-new-tab', 'check-closed', 'check-cookie'])
    parser.add_argument('--state', default='/tmp/bromure-shared-lifecycle.json')
    parser.add_argument('--seconds', type=int, default=900)
    parser.add_argument('--window', type=int)
    parser.add_argument('--expected', help='JSON map of browser windowId to exact input string')
    parser.add_argument('--after-restart', action='store_true')
    args = parser.parse_args()
    if args.phase == 'serve':
        assert 1 <= args.seconds <= 3600
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if not self.path.startswith('/fixture/'):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(HTML)))
                self.end_headers()
                self.wfile.write(HTML)
            def log_message(self, *unused):
                pass
        class Server(http.server.HTTPServer):
            def get_request(self):
                client, address = super().get_request()
                client.settimeout(1)
                return client, address
        with Server(('127.0.0.1', PORT), Handler) as server:
            server.timeout = .5
            print('BROMURE_SHARED_FIXTURE_READY ' + ORIGIN, flush=True)
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                server.handle_request()
        return
    state_path = Path(args.state)
    current, records = processes(), pages()
    if args.phase == 'prepare':
        assert len(records) == 2 and len({r['windowId'] for r in records}) == 2, records
        state = dict(token=uuid.uuid4().hex, browser=current, pages=records)
        for page in records:
            navigate(page, state['token'])
        token = json.dumps(state['token'])
        evaluate(records[0], 'document.cookie="bromureSharedFixture="+' + token + '+"; Max-Age=86400; Path=/; SameSite=Lax";localStorage.setItem("bromureSharedFixture",' + token + ');true')
        for page in records:
            cookie_check(page, state)
        fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream)
        result = dict(browser=current, windows=[dict(windowId=p['windowId'], targetId=p['id']) for p in records], cookieShared=True)
    else:
        state = json.loads(state_path.read_text())
        if args.after_restart:
            assert args.phase == 'check-cookie', 'restart mode only verifies persistence'
            assert current['profile'] and current['profile'] == state['browser']['profile'], current
            assert (current['pid'], current['startTicks']) != (state['browser']['pid'], state['browser']['startTicks']), 'browser did not restart'
        else:
            assert current == state['browser'], (current, state['browser'])
        selected = [p for p in records if args.window is None or p['windowId'] == args.window]
        result = dict(browser=current, windows=sorted({p['windowId'] for p in records}))
        if args.phase == 'check-input':
            expected = json.loads(args.expected or '{}')
            assert expected and set(expected) == {str(p['windowId']) for p in records}, 'supply every current window to detect cross-window input'
            evidence = []
            for page in records:
                value = evaluate(page, '({value:document.querySelector("#entry").value,events:fixtureEvents,scrollY,focused:document.hasFocus()})')
                assert value['value'] == expected[str(page['windowId'])], value
                kinds = [event['type'] for event in value['events']]
                for kind in ('pointerdown', 'pointerup', 'click', 'keydown', 'keyup', 'wheel'):
                    assert kind in kinds, (kind, value)
                assert value['scrollY'] > 0, value
                evidence.append(dict(windowId=page['windowId'], **value))
            result['input'] = evidence
        elif args.phase == 'check-new-tab':
            assert args.window is not None
            old = {p['id']: p['windowId'] for p in state['pages']}
            assert all(any(p['id'] == tid and p['windowId'] == wid for p in records) for tid, wid in old.items()), 'existing tab disappeared or changed window'
            added = [p for p in records if p['id'] not in old]
            assert len(added) == 1 and added[0]['windowId'] == args.window, added
            navigate(added[0], state['token'])
            cookie_check(added[0], state)
            result['newTarget'] = added[0]['id']
        elif args.phase == 'check-closed':
            assert args.window in {p['windowId'] for p in state['pages']}, 'window was not in initial fixture'
            assert args.window is not None and not selected and records, 'closed window remains or entire browser lost'
            assert all(any(p['id'] == old['id'] and p['windowId'] == old['windowId'] for p in records)
                       for old in state['pages'] if old['windowId'] != args.window), 'surviving original window lost'
        elif args.phase == 'check-cookie':
            assert selected
            for page in selected:
                navigate(page, state['token'])
                cookie_check(page, state)
            result['cookiePersistentAfterRestart'] = args.after_restart
    print('BROMURE_SHARED_LIFECYCLE_PASS ' + json.dumps(dict(phase=args.phase, **result)), flush=True)


if __name__ == '__main__':
    main()
