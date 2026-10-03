#!/usr/bin/env python3
"""Build the actual backend callback fixture using its configured VirGL includes."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--cache-root', required=True, type=Path)
args = parser.parse_args()
if sys.platform != 'darwin':
    raise SystemExit('This fixture requires macOS CoreVideo and IOSurface.')
cache = args.cache_root.resolve()
entries = json.loads((cache / 'virgl-build/compile_commands.json').read_text())
entry = next(row for row in entries if row['file'].endswith('virgl_video_videotoolbox.m'))
original = shlex.split(entry['command'])[1:]
flags = ['-I' + str((Path(entry['directory']) / entry['file']).resolve().parent)]
i = 0
while i < len(original):
    flag = original[i]
    if flag in ('-o', '-MF', '-MQ', '-c'):
        i += 2
        continue
    if flag not in ('-MD', '-DNDEBUG'):
        flags.append(flag)
    i += 1
with tempfile.TemporaryDirectory(prefix='bromure-video-surface-budget-') as directory:
    binary = Path(directory) / 'fixture'
    command = ['xcrun', 'clang', *flags, '-UNDEBUG',
               str(Path(__file__).with_suffix('.m').resolve()),
               '-L' + str(cache / 'prefix/lib'), '-lvirglrenderer',
               '-Wl,-rpath,' + str(cache / 'prefix/lib'), '-o', str(binary)]
    for framework in ('Foundation', 'Metal', 'IOSurface', 'VideoToolbox', 'CoreMedia', 'CoreVideo'):
        command += ['-framework', framework]
    subprocess.run(command, cwd=entry['directory'], check=True)
    subprocess.run([str(binary)], check=True)
