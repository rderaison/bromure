#!/usr/bin/env python3
"""Collect guest playback evidence and sampled CPU; never discard failed trials."""
import argparse
import json
import pathlib
import re
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('--log', type=pathlib.Path, required=True)
parser.add_argument('--cpu', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
a = parser.parse_args()
text = re.sub(r'\[VM \d+\] ', '', a.log.read_text(errors='replace'))
starts = {}
samples = []
result = None
for match in re.finditer(r'BROMURE_VIDEO_(START|SAMPLE|RESULT) ', text):
    try:
        value, _ = json.JSONDecoder().raw_decode(text[match.end():])
    except ValueError:
        continue
    kind = match.group(1)
    if kind == 'START':
        starts[(value['case'], value['trial'])] = value['wallTime']
    elif kind == 'SAMPLE':
        samples.append(value)
    else:
        result = value
assert result is not None and 'BROMURE_VIDEO_RUN_COMPLETE' in text, 'Run incomplete; retain raw evidence separately'
assert len(samples) == result['trials'] * len(result['clips']['clips']), 'Missing trial evidence'
cpu = [json.loads(line) for line in a.cpu.read_text().splitlines()]
for row in samples:
    start = starts[(row['case'], row['trial'])]
    end = row['wallTime']
    totals = {}
    for before, after in zip(cpu, cpu[1:]):
        lo, hi = before['wallTime'], after['wallTime']
        overlap = max(0, min(hi, end) - max(lo, start))
        if overlap <= 0 or hi <= lo:
            continue
        for pid, process in after['processes'].items():
            previous = before['processes'].get(pid)
            delta = process['cpuSeconds'] - (previous['cpuSeconds'] if previous else 0)
            if delta < 0:
                continue
            category = process['category']
            totals[category] = totals.get(category, 0) + delta * overlap / (hi-lo)
    percentages = {key: 100*value/(end-start) for key, value in totals.items()}
    row['hostCPU'] = {
        'percentByCategory': percentages,
        'totalPercent': sum(percentages.values()),
        'oneCoreEqualsPercent': 100,
        'method': '0.5s cumulative ps CPU snapshots, weighted boundary intervals; owned app, renderer broker/worker and unique newly started VZ service. Excludes WindowServer, kernel GPU work and shared system daemons; not total system energy.'}
result['samples'] = samples
for case, summary in result['summary'].items():
    rows = [row for row in samples if row['case'] == case]
    assert len(rows) == result['trials'] and len({row['trial'] for row in rows}) == result['trials']
    summary['medianHostCPUPercent'] = statistics.median(row['hostCPU']['totalPercent'] for row in rows)
    summary['samplesHostCPUPercent'] = [row['hostCPU']['totalPercent'] for row in rows]
    summary['samplesPresentedFramesPerSecond'] = [row['presentedFramesPerSecond'] for row in rows]
    summary['samplesPlaybackSpeedRatio'] = [row['playbackSpeedRatio'] for row in rows]
result['allTrialsSucceeded'] = all(row['trialSucceeded'] for row in samples)
a.output.write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result['summary'], indent=2))
