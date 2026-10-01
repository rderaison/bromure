#!/usr/bin/env python3
"""Read-only, bounded Chromium/OOM diagnostic. Run as root for full visibility.

python3 guest-memory-trace.py --seconds 1200 --interval 1 > memory.jsonl
No process control, kernel settings, or production service installation.
RSS sums are not unique memory; disappearing PIDs do not establish exit cause.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import signal
import subprocess
import time

PROC = Path('/proc')


def read(path, limit=131072):
    try:
        with open(path, 'r', errors='replace') as stream:
            return stream.read(limit)
    except OSError as error:
        return 'ERROR:' + str(error)


def fields(text):
    result = {}
    for line in text.splitlines():
        parts = line.replace(':', '', 1).split()
        if len(parts) >= 2:
            try:
                result[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return result


def identity(text):
    # comm may contain spaces and parentheses. starttime is stat field 22.
    tail = text[text.rfind(')') + 1:].split()
    if len(tail) < 20:
        raise ValueError('incomplete process stat')
    return int(tail[19])


def emit(kind, **values):
    print(json.dumps(dict(kind=kind, wall_ns=time.time_ns(),
                          monotonic_ns=time.monotonic_ns(), **values)), flush=True)


def cgroup_memory(pid):
    for line in read(PROC / str(pid) / 'cgroup').splitlines():
        if line.startswith('0::'):
            relative = line[3:]
            if '..' in Path(relative).parts:
                return {'error': 'cgroup path outside mount'}
            base = Path('/sys/fs/cgroup') / relative.lstrip('/')
            return {name: read(base / name, 8192) for name in
                    ('memory.current', 'memory.peak', 'memory.max',
                     'memory.events', 'memory.events.local', 'memory.swap.current')}
    return {'error': 'no unified memory cgroup'}


def snapshot_process(pid, detailed):
    base = PROC / str(pid)
    argv = read(base / 'cmdline').split('\0')
    try:
        executable = os.readlink(base / 'exe')
    except OSError:
        executable = None
    names = [Path(value).name.lower() for value in (argv[0], executable or '')]
    # Zygote children may use /proc/self/exe as argv[0]. Record their actual
    # executable, with an explicit GPU-role fallback if exe access is denied.
    if not (any(token in name for name in names for token in ('chrome', 'chromium'))
            or '--type=gpu-process' in argv):
        return None
    start = identity(read(base / 'stat'))
    status = fields(read(base / 'status'))
    data = dict(pid=pid, start_ticks=start, executable=executable or argv[0],
                argv0=argv[0],
                role=[x for x in argv if x.startswith(('--type=', '--utility-sub-type='))],
                status_kib={k: v for k, v in status.items()
                            if k.startswith(('Vm', 'Rss'))},
                threads=status.get('Threads'), ppid=status.get('PPid'),
                oom_score=read(base / 'oom_score', 128).strip(),
                oom_score_adj=read(base / 'oom_score_adj', 128).strip())
    try:
        descriptors = list((base / 'fd').iterdir())
        data['fd_count'] = len(descriptors)
        if detailed:
            types = collections.Counter()
            examples = {}
            for fd in descriptors[:8192]:
                try:
                    target = os.readlink(fd)
                except OSError:
                    types['raced_or_denied'] += 1
                    continue
                category = ('dmabuf' if 'dmabuf' in target or 'dma_buf' in target else
                            'sync_file' if 'sync_file' in target else
                            'drm' if '/dev/dri/' in target else
                            'memfd' if 'memfd:' in target else
                            'socket' if target.startswith('socket:') else
                            'eventfd' if 'eventfd' in target else
                            'eventpoll' if 'eventpoll' in target else
                            'pipe' if target.startswith('pipe:') else
                            'other')
                types[category] += 1
                # At most three representative fdinfo records per type. These
                # identify fence/GEM exporters without dumping every open file.
                bucket = examples.setdefault(category, [])
                if len(bucket) < 3:
                    bucket.append(dict(fd=int(fd.name),
                                       target=target if category != 'other' else '(other)',
                                       info=read(base / 'fdinfo' / fd.name, 2048)))
            data['fd_types'] = dict(types)
            data['fd_examples'] = examples
            data['fd_scan_truncated'] = len(descriptors) > 8192
    except OSError as error:
        data['fd_error'] = str(error)
    if detailed:
        smaps = read(base / 'smaps_rollup')
        data['smaps_rollup_kib'] = fields(smaps)
        if smaps.startswith('ERROR:'):
            data['smaps_error'] = smaps
        data['open_files_limit'] = [line for line in read(base / 'limits').splitlines()
                                    if line.startswith('Max open files')]
        data['cgroup_memory'] = cgroup_memory(pid)
    if identity(read(base / 'stat')) != start:
        raise ValueError('PID reused during snapshot')
    return data


def kernel_log():
    # dmesg is snapshot-only: never clear/read-clear the ring. Kernel messages
    # cover OOM kills, crashes and driver failures, with monotonic timestamps.
    try:
        result = subprocess.run(['dmesg', '--color=never'], capture_output=True,
                                text=True, timeout=2)
        lines = result.stdout.splitlines()
        interesting = [line for line in lines if any(word in line.lower() for word in
                       ('oom', 'out of memory', 'killed process', 'segfault',
                        'trap', 'virtio', 'drm', 'stall', 'hung task'))]
        emit('kernel', returncode=result.returncode, stderr=result.stderr[-4096:],
             lines=interesting[-200:], truncated=len(interesting) > 200)
    except (OSError, subprocess.TimeoutExpired) as error:
        emit('kernel_error', error=str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=1200)
    parser.add_argument('--interval', type=float, default=1)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600 or not .25 <= args.interval <= 30:
        parser.error('seconds must be 1..3600; interval .25..30')
    # Also bounds time spent in native reads. Default SIGALRM terminates even
    # when a Python handler could not run; external caller must check exit.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, args.seconds + 5)
    deadline = time.monotonic() + args.seconds
    emit('ready', uid=os.geteuid(), boot_id=read(PROC / 'sys/kernel/random/boot_id').strip(),
         seconds=args.seconds, interval=args.interval)
    previous = set()
    last_detail = last_kernel = float('-inf')
    while time.monotonic() < deadline:
        now = time.monotonic()
        detailed = now - last_detail >= 5
        if detailed:
            last_detail = now
        records = []
        errors = []
        candidates = sorted(int(p.name) for p in PROC.iterdir() if p.name.isdigit())
        for pid in candidates[:4096]:
            try:
                record = snapshot_process(pid, detailed)
                if record:
                    records.append(record)
            except (OSError, ValueError) as error:
                errors.append(dict(pid=pid, error=str(error)))
        current = {(r['pid'], r['start_ticks']) for r in records}
        vmstat = fields(read(PROC / 'vmstat'))
        emit('sample', meminfo_kib=fields(read(PROC / 'meminfo')),
             vmstat={k: v for k, v in vmstat.items() if k.startswith(
                 ('oom', 'pgscan', 'pgsteal', 'pgmajfault', 'pswp', 'allocstall'))},
             memory_pressure=read(PROC / 'pressure/memory', 4096),
             system_file_nr=read(PROC / 'sys/fs/file-nr', 1024).strip(),
             processes=records, appeared=sorted(current - previous),
             absent_since_last_sample=sorted(previous - current),
             errors=errors, process_scan_truncated=len(candidates) > 4096)
        previous = current
        if now - last_kernel >= 10:
            kernel_log()
            last_kernel = now
        time.sleep(max(0, min(args.interval - (time.monotonic() - now),
                              deadline - time.monotonic())))
    kernel_log()
    emit('end', reason='deadline')
    signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    main()
