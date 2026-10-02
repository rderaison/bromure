#!/usr/bin/env python3
"""PRIVATE opt-in supervisor. Owns native Squid, gateway and exact UID rules.

Install with companion gateway root-owned in /usr/local/bin on a PRIVATE image.
Select with bromure.experimental_async_squid=1 or explicit --private-runtime.
Never wraps a running Squid. No fallback to direct or proxychains on failure.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import select
import signal
import subprocess
import sys
import threading
import time

CHAIN = 'BRM_ASYNC_SQ'
PORT = 40002


def opted_in(cmdline):
    values = [s.split('=', 1)[1] for s in cmdline.split() if s.startswith('bromure.experimental_async_squid=')]
    if values and values != ['1']:
        raise ValueError('invalid async Squid boot opt-in')
    return bool(values)


class RedirectRules:
    def __init__(self, uid, port=PORT, runner=subprocess.run):
        if type(uid) is not int or uid <= 0 or not 1024 <= port <= 65535:
            raise ValueError('invalid redirect identity/port')
        self.uid, self.port, self.run = uid, port, runner
        self.owned, self.jumps = [], []

    def command(self, binary, *args):
        self.run([binary, '-w', '2', '-t', 'nat', *args], check=True,
                 stdout=subprocess.DEVNULL, timeout=5)

    def jump(self):
        return ['OUTPUT', '-p', 'tcp', '-m', 'owner', '--uid-owner', str(self.uid), '-j', CHAIN]

    def install(self):
        # A stale/unowned chain is an error, not permission to flush it.
        for binary in ('iptables', 'ip6tables'):
            self.command(binary, '-N', CHAIN)
            self.owned.append(binary)
            self.command(binary, '-A', CHAIN, '-p', 'tcp', '-j', 'REDIRECT', '--to-ports', str(self.port))
            self.command(binary, '-I', *self.jump()[:1], '1', *self.jump()[1:])
            self.jumps.append(binary)

    def remove(self):
        errors = []
        for binary in reversed(self.jumps):
            try:
                self.command(binary, '-D', *self.jump())
            except Exception as error:
                errors.append(str(error))
        for binary in reversed(self.owned):
            try:
                self.command(binary, '-F', CHAIN)
                self.command(binary, '-X', CHAIN)
            except Exception as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError('redirect cleanup failed: ' + '; '.join(errors))


def trusted_file(path):
    stat = path.stat()
    if not path.is_file() or stat.st_uid != 0 or stat.st_mode & 0o022:
        raise ValueError('candidate executable/config must be root-owned and not group/world writable: ' + str(path))


def processes_for_uid(uid):
    found = []
    for p in Path('/proc').glob('[0-9]*'):
        try:
            if p.joinpath('comm').read_text().strip() != 'squid':
                continue
            ids = next(line.split()[1:] for line in p.joinpath('status').read_text().splitlines() if line.startswith('Uid:'))
            if uid in [int(x) for x in ids]:
                found.append(int(p.name))
        except (OSError, StopIteration):
            pass
    return found


def stop_child(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-runtime', action='store_true')
    parser.add_argument('--squid', default='/usr/sbin/squid')
    parser.add_argument('--config', default='/etc/squid/squid.conf')
    parser.add_argument('--gateway', default=str(Path(__file__).resolve().with_name('async-squid-gateway.py')))
    parser.add_argument('--run-dir', default='/run/bromure-async-squid')
    args = parser.parse_args()
    if os.geteuid() != 0 or not (args.private_runtime or opted_in(Path('/proc/cmdline').read_text())):
        parser.error('root and explicit private opt-in required')
    squid_user, gateway_user = pwd.getpwnam('proxy'), pwd.getpwnam('nobody')
    if squid_user.pw_uid == 0 or gateway_user.pw_uid in (0, squid_user.pw_uid):
        raise ValueError('separate unprivileged Squid and gateway users required')
    squid = Path(args.squid).resolve()
    config = Path(args.config).resolve()
    gateway = Path(args.gateway).resolve()
    if any(c.isspace() for c in str(config)):
        raise ValueError('config path must not contain whitespace')
    for file in (squid, config, gateway):
        trusted_file(file)
    runtime = Path(args.run_dir)
    runtime.mkdir(mode=0o755, exist_ok=True)
    if runtime.is_symlink() or runtime.stat().st_uid != 0 or runtime.stat().st_mode & 0o022:
        raise ValueError('untrusted runtime directory')
    lock = os.open(str(runtime/'supervisor.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if processes_for_uid(squid_user.pw_uid):
        raise RuntimeError('existing Squid must be stopped by its service owner before candidate launch')
    state = runtime/'worker'
    state.mkdir(mode=0o750, exist_ok=True)
    if state.is_symlink():
        raise ValueError('untrusted worker directory')
    os.chown(state, squid_user.pw_uid, squid_user.pw_gid)
    native_config = runtime/'squid.conf'
    if native_config.is_symlink():
        raise ValueError('untrusted native config')
    native_config.write_text(f'include {config}\npid_filename {state}/squid.pid\n')
    os.chmod(native_config, 0o644)
    env = dict(os.environ)
    for name in ('LD_PRELOAD', 'PROXYCHAINS_CONF_FILE'):
        env.pop(name, None)
    stopped = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.set())
    rules = RedirectRules(squid_user.pw_uid)
    gateway_process = squid_process = None
    try:
        gateway_process = subprocess.Popen([sys.executable, str(gateway)], env=env,
            user=gateway_user.pw_uid, group=gateway_user.pw_gid, extra_groups=[],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        ready, _, _ = select.select([gateway_process.stdout], [], [], 5)
        if not ready or not gateway_process.stdout.readline().startswith('BROMURE_ASYNC_SQUID_READY '):
            raise RuntimeError('both gateway address families must bind before Squid launch')
        rules.install()
        squid_process = subprocess.Popen([str(squid), '-N', '-f', str(native_config)], env=env,
            user=squid_user.pw_uid, group=squid_user.pw_gid, extra_groups=[], start_new_session=True)
        # UID is assigned before exec, not inferred from a mutable process name.
        time.sleep(.1)
        if squid_process.poll() is not None:
            raise RuntimeError('native Squid failed startup')
        actual = Path('/proc')/str(squid_process.pid)
        ids = next(line.split()[1:] for line in actual.joinpath('status').read_text().splitlines() if line.startswith('Uid:'))
        if any(int(x) != squid_user.pw_uid for x in ids) or actual.joinpath('exe').resolve() != squid:
            raise RuntimeError('native Squid executable/UID verification failed')
        print('BROMURE_ASYNC_SQUID_ACTIVE ' + json.dumps(dict(squidPID=squid_process.pid,
              squidUID=squid_user.pw_uid, gatewayPID=gateway_process.pid, gatewayUID=gateway_user.pw_uid)), flush=True)
        while not stopped.wait(.25):
            if squid_process.poll() is not None or gateway_process.poll() is not None:
                raise RuntimeError('candidate worker exited; stopping without routing fallback')
    finally:
        # Stop traffic producer FIRST. Never remove redirect under a live Squid.
        stop_child(squid_process)
        stop_child(gateway_process)
        if processes_for_uid(squid_user.pw_uid):
            raise RuntimeError('Squid still running: leaving redirects fail-closed')
        rules.remove()
        os.close(lock)


if __name__ == '__main__':
    main()
