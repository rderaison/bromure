#!/usr/bin/env python3
"""Correlate queued host pointer packets with event-time guest screen coordinates.

Usage: python3 tools/gpu/check-stress-pointer.py gpu-browser-live.log
This checks transport coordinates, not the visual target of a retained image.
"""
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
windows = re.findall(r'Test window id: (\d+)', text)
assert len(windows) == 4, windows
bridges = {}
packets = {}
events = {}
for line in text.splitlines():
    match = re.search(r'\[GPU pointer\] window=(\d+) bridge=(ObjectIdentifier\([^)]*\)) buttons=1', line)
    if match:
        bridges[match[1]] = match[2]
    match = re.search(r'\[GPU pointer packet\] bridge=(ObjectIdentifier\([^)]*\)).* json=(\{.*\})', line)
    if match:
        packet = json.loads(match[2])
        if packet['buttons'] == 1:
            packets.setdefault(match[1], []).append(packet)
    if 'BROMURE_STRESS ' in line and '"kind": "host-click-pass"' in line:
        cleaned = re.sub(r'\[VM \d+\] ', '', line)
        payload, _ = json.JSONDecoder().raw_decode(cleaned.split('BROMURE_STRESS ', 1)[1])
        events[payload['vm']] = payload['clicks']

for vm, window in enumerate(windows, 1):
    sent = packets[bridges[window]]
    received = events[vm]
    assert len(sent) == len(received) == 3, (vm, len(sent), len(received))
    errors = []
    for packet, event in zip(sent, received):
        # The receiver rounds normalized coordinates to the uinput ABS range.
        # DOM screen coordinates and screen dimensions are both CSS pixels.
        expected_x = round(packet['x'] * 65535) / 65535 * event['screenWidth']
        expected_y = round(packet['y'] * 65535) / 65535 * event['screenHeight']
        dx, dy = event['screenX'] - expected_x, event['screenY'] - expected_y
        assert abs(dx) <= 3 and abs(dy) <= 3, (vm, packet, event, dx, dy)
        errors.append({'x': dx, 'y': dy, 'dpr': event['dpr']})
    print(json.dumps({'vm': vm, 'window': window, 'screenCoordinateErrors': errors}))
print('BROMURE_SCREEN_POINTER_PASS')
