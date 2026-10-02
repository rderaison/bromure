#!/usr/bin/python3 -u
"""Opt-in two-GPU experiment: one Xorg, two independent X screens.

prepare runs before Xorg as root; session runs as chrome under xinit.
No PRIME sharing, Xinerama, persistent profile reuse or default activation.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import time

STATE = Path('/run/bromure-multigpu')
MESA = Path('/opt/bromure/mesa-virgl')


def discover(sysfs=Path('/sys/class/drm')):
    devices = []
    for card in sysfs.glob('card*'):
        if not re.fullmatch(r'card\d+', card.name):
            continue
        device = (card / 'device').resolve()
        feature_files = [device / 'features', *device.glob('virtio*/features')]
        features = []
        for path in feature_files:
            try:
                features.append(path.read_text().strip())
            except OSError:
                pass
        # Linux emits negotiated virtio features in bit-number order.
        if not any(len(bits) >= 32 and bits[0] == '1' and
                   set(bits) <= {'0', '1'} for bits in features):
            continue
        pci = next((p.name for p in (device, *device.parents)
                    if re.fullmatch(r'[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]', p.name)), None)
        renders = sorted(p.name for p in sysfs.glob('renderD*')
                         if re.fullmatch(r'renderD\d+', p.name) and
                         (p / 'device').resolve() == device)
        if pci is None or len(renders) != 1:
            raise ValueError(f'{card.name}: ambiguous PCI/render-node mapping')
        domain, bus, slot, function = map(lambda x: int(x, 16), re.split('[:.]', pci))
        devices.append(dict(pci=pci, card='/dev/dri/' + card.name,
                            render='/dev/dri/' + renders[0],
                            busID=f'PCI:{bus}@{domain}:{slot}:{function}'))
    devices.sort(key=lambda d: d['pci'])
    if len(devices) != 2 or len({d['pci'] for d in devices}) != 2:
        raise ValueError(f'experiment requires exactly two negotiated VirGL GPUs, found {len(devices)}')
    for index, device in enumerate(devices):
        device.update(index=index, display=f':0.{index}', cdpPort=9222 + index)
    return devices


def xorg_config(devices):
    sections = ['''Section "ServerFlags"
  Option "AutoAddGPU" "false"
  Option "AutoBindGPU" "false"
  Option "Xinerama" "false"
EndSection
Section "ServerLayout"
  Identifier "BromureExperimentalMultiGPU"
  Screen 0 "BromureScreen0" 0 0
  Screen 1 "BromureScreen1" RightOf "BromureScreen0"
  Option "Xinerama" "false"
EndSection
''']
    for device in devices:
        i = device['index']
        sections.append(f'''Section "Device"
  Identifier "BromureGPU{i}"
  Driver "modesetting"
  BusID "{device['busID']}"
  Option "kmsdev" "{device['card']}"
  Option "SWCursor" "false"
EndSection
Section "Screen"
  Identifier "BromureScreen{i}"
  Device "BromureGPU{i}"
  DefaultDepth 24
  SubSection "Display"
    Depth 24
  EndSubSection
EndSection
''')
    return '\n'.join(sections)


def read_environment(path):
    result = {}
    for line in path.read_text().splitlines():
        fields = shlex.split(line, comments=True)
        if fields and fields[0] == 'export':
            fields = fields[1:]
        if len(fields) == 1 and '=' in fields[0]:
            key, value = fields[0].split('=', 1)
            result[key] = value
    return result


def screen_environment(values, device):
    env = dict(os.environ, DISPLAY=device['display'], GRAPHICS_BACKEND='virgl',
               LIBGL_DRIVERS_PATH=str(MESA / 'lib/dri'),
               LIBVA_DRIVERS_PATH=str(MESA / 'lib/dri'), LIBVA_DRIVER_NAME='virtio_gpu')
    env.pop('LIBGL_ALWAYS_SOFTWARE', None)
    env['LD_LIBRARY_PATH'] = '/opt/bromure/chromium-vaapi:' + str(MESA / 'lib')
    scale = values.get('DISPLAY_SCALE', '2')
    if scale not in ('1', '2', '3', '4'):
        raise ValueError('unsupported display scale')
    env['XCURSOR_SIZE'] = str(int(scale) * 24)
    env['XCURSOR_THEME'] = 'Adwaita'
    return env


def browser_command(values, device, profiles):
    # Distinct user-data-dir is essential: Chromium otherwise forwards the
    # second launch to the first process and its original X screen/GPU.
    replaced = {'--user-data-dir', '--remote-debugging-port', '--remote-debugging-address',
                '--hardware-video-device-path', '--render-node-override', '--use-angle',
                '--use-gl', '--force-device-scale-factor'}
    args = shlex.split(values.get('EXTRA_FLAGS', ''))
    retained = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        key, equals, _ = arg.partition('=')
        if key in replaced:
            skip = not equals
        else:
            retained.append(arg)
    binary = values.get('BROWSER_BIN') or 'chromium-browser'
    if binary not in ('chromium-browser', 'chromium', 'google-chrome-stable'):
        raise ValueError('unsupported browser binary')
    command = [binary, '--no-first-run', '--no-default-browser-check', '--disable-pings',
               '--start-maximized', '--disable-vulkan', '--font-render-hinting=none', *retained,
               '--use-gl=angle', '--use-angle=gles',
               '--force-device-scale-factor=' + values.get('DISPLAY_SCALE', '2'),
               '--user-data-dir=' + str(profiles / f"screen-{device['index']}"),
               '--remote-debugging-address=127.0.0.1',
               '--remote-debugging-port=' + str(device['cdpPort']),
               '--hardware-video-device-path=' + device['render'],
               '--render-node-override=' + device['render']]
    if values.get('CHROME_UA'):
        command.append('--user-agent=' + values['CHROME_UA'])
    if values.get('CHROME_LANG'):
        command.append('--lang=' + values['CHROME_LANG'])
    command.append(values.get('CHROME_URL') or 'about:blank')
    return command


def prepare():
    if os.geteuid() != 0:
        raise ValueError('prepare requires root before Xorg starts')
    devices = discover()
    import pwd
    user = pwd.getpwnam('chrome')
    runtime = Path(f'/run/user/{user.pw_uid}')
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(runtime, user.pw_uid, user.pw_gid)
    STATE.mkdir(mode=0o755, exist_ok=True)
    (STATE / 'xorg.conf').write_text(xorg_config(devices))
    manifest = dict(version=1, experimental=True, topology='independent-x-screens', devices=devices)
    (STATE / 'displays.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('BROMURE_MULTIGPU_TOPOLOGY ' + json.dumps(manifest), flush=True)


def session():
    if os.geteuid() == 0:
        raise ValueError('session must run as the chrome user')
    os.environ['XDG_RUNTIME_DIR'] = f'/run/user/{os.getuid()}'
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
        os.execvp('dbus-run-session', ['dbus-run-session', '--', __file__, 'session'])
    manifest = json.loads((STATE / 'displays.json').read_text())
    devices = manifest['devices']
    if len(devices) != 2:
        raise ValueError('expected two screens')
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not Path('/tmp/bromure/chrome-ready').exists():
        if stopped:
            return
        time.sleep(.1)
    values = read_environment(Path('/tmp/bromure/chrome-env'))
    if values.get('GRAPHICS_BACKEND') != 'virgl':
        raise ValueError('experimental session requires explicit VirGL configuration')
    # Preserve the ordinary VPN gate: never launch browsing before its tunnel.
    if values.get('VPN_AUTO_CONNECT'):
        deadline = time.monotonic() + 120
        status = Path('/tmp/bromure/vpn-status')
        while not status.exists() and time.monotonic() < deadline and not stopped:
            time.sleep(.1)
        if stopped:
            return
        if not status.exists() or status.read_text().splitlines()[0] != 'ok':
            raise ValueError('VPN did not become ready')
    work = Path('/tmp/bromure/multigpu')
    work.mkdir(mode=0o700, exist_ok=True)
    children, logs = [], []
    try:
        # Exactly one audio stack and session bus for the VM, shared by both
        # browsers. Profile policy and the configured proxy remain in force.
        if values.get('AUDIO') == '1':
            for name in ('pipewire', 'wireplumber', 'pipewire-pulse'):
                log = open(work / (name + '.log'), 'ab', buffering=0)
                logs.append(log)
                children.append((name, subprocess.Popen([name], stdout=log, stderr=log)))
                time.sleep(.3)
        for device in devices:
            env = screen_environment(values, device)
            # Fail before launching either browser if the X screen is absent.
            subprocess.run(['xdpyinfo', '-display', device['display']], env=env,
                           stdout=subprocess.DEVNULL, check=True, timeout=5)
        log = open(work / 'input.log', 'ab', buffering=0)
        logs.append(log)
        children.append(('input', subprocess.Popen(
            ['/usr/local/bin/experimental-multigpu-input.py'],
            env=screen_environment(values, devices[0]), stdout=log, stderr=log)))
        for device in devices:
            env = screen_environment(values, device)
            profile = work / 'profiles' / f"screen-{device['index']}" / 'Default'
            profile.mkdir(parents=True, exist_ok=True)
            preferences = Path('/home/chrome/.config/chromium/Default/Preferences')
            if preferences.is_file() and not (profile / 'Preferences').exists():
                shutil.copyfile(preferences, profile / 'Preferences')
            for label, command in (
                ('openbox', ['openbox', '--sm-disable']),
                ('resize', ['/usr/local/bin/resize-watcher.py']),
                ('chromium', browser_command(values, device, work / 'profiles')),
            ):
                log = open(work / f"{device['index']}-{label}.log", 'ab', buffering=0)
                logs.append(log)
                children.append((label, subprocess.Popen(command, env=env, stdout=log, stderr=log)))
        print('BROMURE_MULTIGPU_SESSION_STARTED ' + json.dumps(devices), flush=True)
        while not stopped:
            failed = [(label, child.returncode) for label, child in children if child.poll() is not None]
            if failed:
                raise RuntimeError('experimental child exited: ' + repr(failed))
            time.sleep(.25)
    finally:
        for _, child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for _, child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        for log in logs:
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'session', 'probe'))
    args = parser.parse_args()
    if args.action == 'probe':
        print(json.dumps(discover(), indent=2))
    elif args.action == 'prepare':
        prepare()
    else:
        session()


if __name__ == '__main__':
    main()
