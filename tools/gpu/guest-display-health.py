#!/usr/bin/env python3
"""Passive bounded display/video observer. Does not wake, activate or navigate.

Run as chrome with DISPLAY=:0 XAUTHORITY=/home/chrome/.Xauthority; run the
separate guest-memory-trace.py as root alongside it for GPU FD types/limits/OOM.
Includes XScreenSaver state (not just configured timeout), DPMS power level,
CDP video counters and GPU process identity. Missing access is recorded, not
interpreted as a healthy device. These observations do not prove pixel output.
Requires libxss1 for XScreenSaverQueryInfo; image setup installs it explicitly.
"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, '/usr/local/bin')
try:
    from shared_windows import cdp_call
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/scripts'))
    from shared_windows import cdp_call


def x_state():
    x = C.CDLL('libX11.so.6')
    x.XOpenDisplay.argtypes, x.XOpenDisplay.restype = [C.c_char_p], C.c_void_p
    x.XDefaultRootWindow.argtypes, x.XDefaultRootWindow.restype = [C.c_void_p], C.c_ulong
    x.XCloseDisplay.argtypes = [C.c_void_p]
    d = x.XOpenDisplay(None)
    if not d:
        raise RuntimeError('X display unavailable')
    result = {}
    try:
        try:
            ss = C.CDLL('libXss.so.1')
            class Info(C.Structure):
                _fields_ = [('window', C.c_ulong), ('state', C.c_int), ('kind', C.c_int),
                            ('til_or_since', C.c_ulong), ('idle', C.c_ulong), ('eventMask', C.c_ulong)]
            ss.XScreenSaverQueryInfo.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(Info)]
            info = Info()
            if not ss.XScreenSaverQueryInfo(d, x.XDefaultRootWindow(d), C.byref(info)):
                raise RuntimeError('screensaver query unavailable')
            result['screensaver'] = dict(state=info.state,
                stateName={0:'off', 1:'on', 2:'cycle', 3:'disabled'}.get(info.state, 'unknown'),
                kind=info.kind, idleMs=info.idle, untilOrSinceMs=info.til_or_since)
        except (OSError, RuntimeError) as error:
            result['screensaverError'] = str(error)
        try:
            ext = C.CDLL('libXext.so.6')
            ext.DPMSCapable.argtypes = [C.c_void_p]
            ext.DPMSInfo.argtypes = [C.c_void_p, C.POINTER(C.c_ushort), C.POINTER(C.c_int)]
            if not ext.DPMSCapable(d):
                result['dpms'] = dict(capable=False)
            else:
                level, enabled = C.c_ushort(), C.c_int()
                if not ext.DPMSInfo(d, C.byref(level), C.byref(enabled)):
                    raise RuntimeError('DPMS query failed')
                result['dpms'] = dict(capable=True, enabled=bool(enabled.value), powerLevel=level.value,
                                      powerName={0:'on', 1:'standby', 2:'suspend', 3:'off'}.get(level.value, 'unknown'))
        except (OSError, RuntimeError) as error:
            result['dpmsError'] = str(error)
        return result
    finally:
        x.XCloseDisplay(d)


def command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=2)
        return dict(exitCode=result.returncode, stdout=result.stdout[-32768:], stderr=result.stderr[-2048:])
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(error=str(error))


def get(path):
    with urllib.request.urlopen('http://127.0.0.1:9222/' + path, timeout=2) as response:
        data = response.read(262145)
        if len(data) > 262144:
            raise ValueError('CDP discovery exceeds bound')
        return json.loads(data)


def emit(kind, **data):
    print(json.dumps(dict(kind=kind, monotonicNs=time.monotonic_ns(), wallNs=time.time_ns(), **data)), flush=True)


EXPRESSION = '''(()=>({url:location.href,visibility:document.visibilityState,ready:document.readyState,
 viewport:[innerWidth,innerHeight,devicePixelRatio],
 videos:Array.from(document.querySelectorAll('video')).slice(0,32).map((v,index)=>{
 const q=v.getVideoPlaybackQuality();return {index,src:v.currentSrc.slice(0,512),srcLength:v.currentSrc.length,time:v.currentTime,
 duration:Number.isFinite(v.duration)?v.duration:null,paused:v.paused,ended:v.ended,readyState:v.readyState,
 networkState:v.networkState,width:v.videoWidth,height:v.videoHeight,
 total:q.totalVideoFrames,dropped:q.droppedVideoFrames,
 error:v.error?{code:v.error.code,message:v.error.message}:null}}),
 images:{count:document.images.length,complete:Array.from(document.images).filter(i=>i.complete).length,
 sample:Array.from(document.images).slice(0,16).map(i=>({src:i.currentSrc.slice(0,512),
 width:i.naturalWidth,height:i.naturalHeight,complete:i.complete}))}}))()'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--seconds', type=float, default=600)
    p.add_argument('--interval', type=float, default=5)
    p.add_argument('--target', help='Observe this existing CDP page target only; never activate it')
    p.add_argument('--x-state', action='store_true')
    a = p.parse_args()
    if a.x_state:
        print(json.dumps(x_state()))
        return
    if not 1 <= a.seconds <= 3600 or not .5 <= a.interval <= 30:
        p.error('seconds1..3600, interval.5..30')
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, a.seconds + 8)
    deadline = time.monotonic() + a.seconds
    emit('ready', seconds=a.seconds, interval=a.interval, uid=os.geteuid(),
         xset=command(['xset', 'q']), randr=command(['xrandr', '--query']))
    last_detail = float('-inf')
    while time.monotonic() < deadline:
        start = time.monotonic()
        data = dict(xState=command([sys.executable, str(Path(__file__).resolve()), '--x-state']))
        try:
            browser = get('json/version')['webSocketDebuggerUrl']
            processes = cdp_call(browser, 'SystemInfo.getProcessInfo', {}, timeout=2)['processInfo']
            for row in processes:
                try:
                    row['startTicks'] = int(Path('/proc', str(row['id']), 'stat').read_text().rsplit(')', 1)[1].split()[19])
                except (OSError, ValueError):
                    row['startTicks'] = None
            data['processes'] = processes
            if start - last_detail >= 10:
                last_detail = start
                data['gpu'] = cdp_call(browser, 'SystemInfo.getInfo', {}, timeout=2).get('gpu')
                data['xset'] = command(['xset', 'q'])
            pages = [row for row in get('json/list') if row.get('type') == 'page']
            selected = [row for row in pages if row['id'] == a.target] if a.target else pages[:1]
            data['pageCount'], data['pages'] = len(pages), []
            for page in selected:
                began = time.monotonic()
                try:
                    result = cdp_call(page['webSocketDebuggerUrl'], 'Runtime.evaluate',
                                      {'expression': EXPRESSION, 'returnByValue': True}, timeout=2)
                    if 'exceptionDetails' in result:
                        raise RuntimeError(str(result['exceptionDetails'])[:512])
                    data['pages'].append(dict(targetId=page['id'], value=result['result'].get('value'),
                                              queryMs=(time.monotonic()-began)*1000))
                except (OSError, ValueError, RuntimeError) as error:
                    data['pages'].append(dict(targetId=page['id'], error=str(error)))
        except (OSError, ValueError, RuntimeError, KeyError) as error:
            data['cdpError'] = str(error)
        emit('sample', **data)
        time.sleep(max(0, min(a.interval - (time.monotonic()-start), deadline-time.monotonic())))
    emit('end', reason='deadline')
    signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    main()
