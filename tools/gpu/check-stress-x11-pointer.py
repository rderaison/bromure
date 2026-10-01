#!/usr/bin/env python3
"""Correlate actual queued button snapshots with passive event-time X root data.

Usage: python3 check-stress-x11-pointer.py gpu-browser-live.log
Requires complete RECORD diagnostics. Checks transport coordinates and releases,
not the visual target in an older retained image.
"""
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
windows = re.findall(r'Test window id: (\d+)', text)
assert len(windows) == 4, windows
bridges, packets, records, ended, exited = {}, {}, {}, set(), set()
for line in text.splitlines():
    match = re.search(r'\[GPU pointer\] window=(\d+) bridge=(ObjectIdentifier\([^)]*\)) buttons=1', line)
    if match:
        bridges[match[1]] = match[2]
    for match in re.finditer(r'\[GPU pointer packet\] bridge=(ObjectIdentifier\([^)]*\)).*? json=(\{[^}]*\})', line):
        packets.setdefault(match[1], []).append(json.loads(match[2]))
    cleaned = re.sub(r'\[VM \d+\] ', '', line)
    for match in re.finditer('BROMURE_STRESS ', cleaned):
        candidate = cleaned[match.end():]
        if not re.match(r'\{"vm": \d+, "kind": "x11-(input|trace-exit)"', candidate):
            continue
        payload, _ = json.JSONDecoder().raw_decode(candidate)
        vm = payload['vm']
        if payload['kind'] == 'x11-input':
            if payload.get('stream') == 'record':
                records.setdefault(vm, []).append(payload)
            assert payload.get('event') != 'error', payload
            if payload.get('event') == 'end':
                assert payload.get('reason') == 'deadline', payload
                ended.add(vm)
        if payload['kind'] == 'x11-trace-exit':
            assert payload['code'] == 0, payload
            exited.add(vm)

for vm, window in enumerate(windows, 1):
    assert vm in ended and vm in exited, ('incomplete observer', vm)
    rows = records[vm]
    assert rows[0]['event'] == 'ready', rows[0]
    assert all(a['ordinal'] < b['ordinal'] for a, b in zip(rows, rows[1:])), vm
    geometry = None
    for row in rows:
        if row['event'] == 'ready':
            geometry = (row['ordinal'], row['root_width'], row['root_height'])
        elif row['event'] == 'root_configure' and not row['sent_event']:
            geometry = (row['ordinal'], row['width'], row['height'])
        assert geometry is not None, row
        assert (row['geometry_ordinal'], row['root_width'], row['root_height']) == geometry, row
    received = [e for e in rows if e['event'] == 'core_button' and e['button'] == 1]
    sent = packets[bridges[window]]
    assert len(sent) == len(received) == 6, (vm, len(sent), len(received))
    errors = []
    for packet, event in zip(sent, received):
        assert packet['buttons'] == (1 if event['action'] == 'down' else 0), (packet, event)
        assert event['geometry_ordinal'] <= event['ordinal'] and not event['sent_event'], event
        expected_x = round(packet['x'] * 65535) / 65535 * event['root_width']
        expected_y = round(packet['y'] * 65535) / 65535 * event['root_height']
        dx, dy = event['root_x'] - expected_x, event['root_y'] - expected_y
        # X integer mapping rounds; three physical pixels is stricter than the
        # older three-CSS-pixel diagnostic on this DPR2 guest.
        assert abs(dx) <= 3 and abs(dy) <= 3, (vm, packet, event, dx, dy)
        errors.append({'action':event['action'], 'x':dx, 'y':dy,
                       'rootWidth':event['root_width'], 'rootHeight':event['root_height']})
    print(json.dumps({'vm':vm, 'rootPixelErrors':errors}))
print('BROMURE_X11_ROOT_POINTER_PASS')
