#!/usr/bin/env python3
"""Plot complete, successful ON/OFF playback trials; requires matplotlib."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

parser = argparse.ArgumentParser()
parser.add_argument('--metal', type=Path, required=True)
parser.add_argument('--apple', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
paths = [('Metal enabled', args.metal, '#625dff'),
         ('Metal disabled / Apple VZ', args.apple, '#9296a0')]
data = []
for label, path, color in paths:
    result = json.loads(path.read_text())
    if not result.get('allTrialsSucceeded'):
        raise SystemExit(f'Refusing to plot failed or incomplete acceptance: {path}')
    data.append((label, result, color))
assert data[0][1]['clips'] == data[1][1]['clips'], 'Different video inputs'
assert data[0][1]['secondsPerTrial'] == data[1][1]['secondsPerTrial']
assert data[0][1]['trials'] == data[1][1]['trials']
cases = [('h264_1080p60', 'H.264 1080p60'),
         ('h264_4k60', 'H.264 4K60'), ('av1_1080p60', 'AV1 1080p60')]
fig, axes = plt.subplots(1, 2, figsize=(11, 5), layout='constrained')
for index, (case, title) in enumerate(cases):
    for platform, (label, result, color) in enumerate(data):
        y = index + (platform - .5) * .32
        summary = result['summary'][case]
        for ax, median, samples in [
            (axes[0], 'medianPresentedFramesPerSecond', 'samplesPresentedFramesPerSecond'),
            (axes[1], 'medianHostCPUPercent', 'samplesHostCPUPercent')]:
            value = summary[median]
            ax.barh(y, value, height=.28, color=color,
                    label=label if index == 0 else None)
            ax.plot(summary[samples], [y] * len(summary[samples]), '|',
                    color='#222222', markersize=8)
            ax.text(value + 1, y, f'{value:.1f}', va='center', fontsize=9)
for ax in axes:
    ax.set_yticks(range(len(cases)), [title for _, title in cases])
    ax.invert_yaxis()
    ax.set_xlim(left=0)
    ax.grid(axis='x', alpha=.18)
    ax.set_axisbelow(True)
    for side in ('top', 'right'):
        ax.spines[side].set_visible(False)
axes[0].set_xlim(0, 68)
axes[0].set_xlabel('Browser presented frames/sec — higher is better')
axes[1].set_xlabel('Attributed host CPU % — 100% equals one core')
axes[1].set_xlim(0, max(max(result['summary'][case]['samplesHostCPUPercent'])
                       for _, result, _ in data for case, _ in cases) * 1.18)
axes[0].legend(loc='center left', bbox_to_anchor=(.015, .30), fontsize=8)
fig.suptitle('Bromure video playback: Metal enabled vs disabled', fontsize=14)
fig.supxlabel('Five 60-second trials; bars are medians, ticks are individual trials.\n'
               'Muted local clips; browser counters, not display latency. CPU excludes shared system daemons.',
               fontsize=9)
args.output_dir.mkdir(parents=True, exist_ok=True)
fig.savefig(args.output_dir / 'video-comparison.png', dpi=180)
svg = args.output_dir / 'video-comparison.svg'
fig.savefig(svg)
svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines()) + '\n')
