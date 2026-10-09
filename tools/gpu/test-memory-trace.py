#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('guest-memory-trace.py')
spec = importlib.util.spec_from_file_location('trace', SCRIPT)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class MemoryTraceTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('BROMURE_MEMORY_TRACE_REPLAY'),
                         'optional captured fixed-run JSONL replay')
    def test_captured_fixed_run_replay(self):
        # The captured file stays outside git (contains process arguments).
        # Run with BROMURE_MEMORY_TRACE_REPLAY=/path/bromure-fixed-memory.jsonl.
        rows = [json.loads(line) for line in
                Path(os.environ['BROMURE_MEMORY_TRACE_REPLAY']).read_text().splitlines()]
        samples = [row for row in rows if row['kind'] == 'sample']
        recovered = []
        for sample in samples:
            gpu = [p for p in sample['processes'] if '--type=gpu-process' in
                   trace.process_roles([p.get('argv0', p['executable'])])[0]]
            self.assertEqual(len(gpu), 1)
            recovered.extend(gpu)
        self.assertEqual(len(recovered), 961)
        self.assertEqual({(p['pid'], p['start_ticks']) for p in recovered}, {(816, 292)})
        self.assertEqual(max(p['fd_count'] for p in recovered), 166)
        self.assertEqual(max(p['fd_types'].get('sync_file', 0) for p in recovered
                             if 'fd_types' in p), 45)

    def test_flattened_chromium_process_title(self):
        title = ('/usr/lib/chromium/chromium --type=gpu-process '
                 '--enable-logging=stderr --user-agent=Mozilla/5.0 (Macintosh; Intel)')
        self.assertEqual(trace.process_roles([title, '']),
                         (['--type=gpu-process'], 'flattened-process-title'))
        self.assertEqual(trace.process_roles([
            '/proc/self/exe --type=utility --utility-sub-type=media.mojom.VideoDecoderFactory', '']),
            (['--type=utility', '--utility-sub-type=media.mojom.VideoDecoderFactory'],
             'flattened-process-title'))
        # Do not interpret text inside an intact argument as a process role.
        self.assertEqual(trace.process_roles([
            '/usr/bin/chromium', '--user-agent=Example --type=gpu-process', '']),
            ([], 'argv'))

    def test_stat_comm_parentheses_and_spaces(self):
        self.assertEqual(trace.identity('42 (chrome (GPU)) S ' +
                                       ' '.join(['0'] * 18 + ['12345', '99'])), 12345)
        with self.assertRaises(ValueError):
            trace.identity('ERROR: process disappeared')

    def test_cpu_ticks_and_bounded_thread_wait_samples(self):
        tail = ['0'] * 20
        tail[0], tail[7], tail[9], tail[11], tail[12], tail[19] = 'S', '3', '4', '17', '19', '123'
        stat = '42 (chrome (GPU)) ' + ' '.join(tail)
        self.assertEqual(trace.cpu_counters(stat), dict(state='S', minor_faults=3,
                         major_faults=4, user_ticks=17, system_ticks=19))
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for tid in range(65):
                task = base / 'task' / str(tid + 100)
                task.mkdir(parents=True)
                (task / 'stat').write_text(stat)
                (task / 'comm').write_text('GpuMain\n')
                (task / 'wchan').write_text('dma_fence_default_wait\n')
            result = trace.gpu_threads(base)
            self.assertEqual(len(result['threads']), 64)
            self.assertTrue(result['truncated'])
            self.assertFalse(result['errors'])
            self.assertEqual(result['threads'][0]['wchan'], 'dma_fence_default_wait')
            self.assertEqual(result['threads'][0]['user_ticks'], 17)

    def test_proc_identity_memory_and_fd(self):
        with tempfile.TemporaryDirectory() as temp:
            original = trace.PROC
            self.addCleanup(setattr, trace, 'PROC', original)
            trace.PROC = Path(temp)
            base = trace.PROC / '42'
            base.mkdir()
            files = dict(cmdline='/usr/bin/chromium\0--type=gpu-process\0',
                         stat='42 (chromium) S ' + ' '.join(['0'] * 18 + ['123']),
                         status='VmRSS: 1234 kB\nRssShmem: 456 kB\nThreads: 7\nPPid: 1',
                         oom_score='400', oom_score_adj='300',
                         smaps_rollup='Pss: 789 kB\nPrivate_Dirty: 123 kB',
                         limits='Max open files 1024 4096 files', cgroup='')
            for name, value in files.items():
                (base / name).write_text(value)
            (base / 'fd').mkdir()
            (base / 'fd/3').symlink_to('/dev/dri/renderD129')
            (base / 'fd/4').symlink_to('/memfd:example (deleted)')
            result = trace.snapshot_process(42, True)
            self.assertEqual(result['start_ticks'], 123)
            self.assertEqual(result['role'], ['--type=gpu-process'])
            self.assertEqual(result['status_kib']['RssShmem'], 456)
            self.assertEqual(result['smaps_rollup_kib']['Pss'], 789)
            self.assertEqual(result['fd_types'], {'drm': 1, 'memfd': 1})
            self.assertIn('error', result['cgroup_memory'])
            (base / 'cmdline').write_text('/bin/unrelated\0')
            self.assertIsNone(trace.snapshot_process(42, True))
            (base / 'cmdline').write_text('/proc/self/exe\0--type=gpu-process\0')
            self.assertEqual(trace.snapshot_process(42, False)['role'],
                             ['--type=gpu-process'])
            (base / 'cmdline').write_text('/proc/self/exe\0--type=utility\0')
            (base / 'exe').symlink_to('/usr/lib/chromium/chromium')
            self.assertEqual(trace.snapshot_process(42, False)['executable'],
                             '/usr/lib/chromium/chromium')
            (base / 'cmdline').write_text(
                '/proc/self/exe --type=gpu-process --use-angle=gles\0')
            (base / 'exe').unlink()
            result = trace.snapshot_process(42, False)
            self.assertEqual(result['role'], ['--type=gpu-process'])
            self.assertEqual(result['role_source'], 'flattened-process-title')

    def test_pid_reuse_rejected(self):
        from unittest.mock import patch
        original = trace.read
        reads = 0

        def read(path, limit=131072):
            nonlocal reads
            if Path(path).name == 'cmdline':
                return '/usr/bin/chromium\0'
            if Path(path).name == 'stat':
                reads += 1
                return '42 (chromium) S ' + ' '.join(['0'] * 18 + [str(reads)])
            return original(path, limit)

        with patch.object(trace, 'read', read):
            with self.assertRaisesRegex(ValueError, 'PID reused'):
                trace.snapshot_process(99999999, False)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux /proc')
    def test_live_gpu_role_with_proc_self_exe_argv0(self):
        # Exercise full enumeration/JSON output, not just the selection helper.
        # A non-Chromium executable ensures the exact GPU role is sufficient.
        child = subprocess.Popen(['/proc/self/exe', '-c',
                                  'import time; time.sleep(15)',
                                  '--type=gpu-process'], executable=sys.executable)
        try:
            result = subprocess.run([sys.executable, str(SCRIPT), '--seconds', '1',
                                     '--interval', '.25', '--gpu-threads'], capture_output=True,
                                    text=True, timeout=8, check=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            samples = [r for r in rows if r['kind'] == 'sample']
            self.assertTrue(samples)
            for sample in samples:
                records = [p for p in sample['processes'] if p['pid'] == child.pid]
                self.assertEqual(len(records), 1, sample['errors'])
                self.assertEqual(records[0]['argv0'], '/proc/self/exe')
                self.assertEqual(records[0]['role'], ['--type=gpu-process'])
                self.assertGreaterEqual(records[0]['fd_count'], 3)
            self.assertIn('fd_types', next(p for p in samples[0]['processes']
                                          if p['pid'] == child.pid))
            process = next(p for p in samples[0]['processes'] if p['pid'] == child.pid)
            self.assertGreaterEqual(process['cpu']['user_ticks'], 0)
            self.assertEqual(process['gpu_threads']['threads'][0]['tid'], child.pid)
            self.assertFalse(process['gpu_threads']['errors'])
            self.assertGreater(rows[0]['clock_ticks_per_second'], 0)
        finally:
            child.terminate()
            child.wait(timeout=3)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux /proc')
    def test_bounded_live_smoke(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--seconds', '1',
                                 '--interval', '.25'], capture_output=True,
                                text=True, timeout=8, check=True)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(rows[0]['kind'], 'ready')
        self.assertEqual(rows[-1]['reason'], 'deadline')
        self.assertTrue(any(row['kind'] == 'sample' and
                            'MemAvailable' in row['meminfo_kib'] for row in rows))
        self.assertTrue(any(row['kind'].startswith('kernel') for row in rows))


if __name__ == '__main__':
    unittest.main()
