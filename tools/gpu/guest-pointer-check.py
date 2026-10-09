#!/usr/bin/env python3
"""Assert host-generated clicks before and after resize in gpu-browser.

Run with --native-chrome --input-check --resize-check --seconds 55. Requires the rebuilt
image's pointer service; deliberately does not inject CDP mouse events.
"""
import json
import os
import runpy
import subprocess
import time
import urllib.request

call = runpy.run_path('/usr/local/bin/tab-agent.py')['cdp_ws_call']
with urllib.request.urlopen('http://127.0.0.1:9222/json/list', timeout=5) as response:
    pages = [p for p in json.load(response) if p['type'] == 'page']
ws = pages[-1]['webSocketDebuggerUrl']
call(ws, 'Page.bringToFront')
call(ws, 'Page.navigate', {'url': 'data:text/html,<button style="position:fixed;inset:0">Host click target</button>'})
time.sleep(1)
call(ws, 'Runtime.evaluate', {'expression': """
window.hostEvents = [];
['pointermove', 'mousedown', 'mouseup', 'click'].forEach(type =>
    window.addEventListener(type, e => window.hostEvents.push({
        type: e.type, x: e.clientX, y: e.clientY, button: e.button,
        width: innerWidth, height: innerHeight
    }), true)); true
""", 'returnByValue': True})
print('BROMURE_HOST_INPUT_READY', flush=True)
for _ in range(27):
    time.sleep(1)
    result = call(ws, 'Runtime.evaluate', {
        'expression': 'JSON.stringify(window.hostEvents)', 'returnByValue': True})
    events = json.loads(result['result']['value'])
    print('BROMURE_HOST_EVENTS ' + json.dumps(events), flush=True)
clicks = [event for event in events if event['type'] == 'click']
assert len(clicks) >= 2, events
assert all(any(e['type'] == kind for e in events)
           for kind in ('pointermove', 'mousedown', 'mouseup')), events
assert clicks[0]['width'] != clicks[-1]['width'], clicks
for click in clicks:
    assert abs(click['x'] - click['width'] / 2) <= 3, click
    assert abs(click['y'] - click['height'] / 2) <= 3, click
print('BROMURE_HOST_POINTER_PASS ' + json.dumps(clicks), flush=True)
print(subprocess.run(['xrandr', '--query'], capture_output=True, text=True,
      env={**os.environ, 'DISPLAY': ':0', 'XAUTHORITY': '/home/chrome/.Xauthority'}).stdout,
      flush=True)
