#!/usr/bin/env python3
"""Parallel real-site smoke test; host gpu-browser supplies clicks/resizes.

Uses a private guest's CDP and a temporary display sentinel to distinguish
black presentation from legitimately dark sites. No credentials or submissions.
"""
import base64
import hashlib
import json
import os
import runpy
import subprocess
import time
import threading
from pathlib import Path
import urllib.request

VM = int(os.environ.get("BROMURE_TEST_VM", "1"))
cdp = runpy.run_path('/usr/local/bin/tab-agent.py')
class DeadlineSocket:
    def __init__(self, sock, deadline):
        self.sock, self.deadline = sock, deadline
    def __getattr__(self, name):
        return getattr(self.sock, name)
    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('CDP method wall deadline expired')
        self.sock.settimeout(remaining)
    def recv(self, size):
        self.remaining()
        return self.sock.recv(size)
    def sendall(self, data):
        self.remaining()
        return self.sock.sendall(data)

def call(ws_url, method, params=None, timeout=3):
    # Keep protocol errors instead of reducing every failure to None. Enable
    # navigation events on this connection so a public site's beforeunload
    # dialog is visible and can be acknowledged for this test navigation.
    # Connection/upgrade uses the guest helper's own timeout. Once connected,
    # every fragmented read or ping response shares one method deadline.
    raw_sock = cdp['_ws_connect'](ws_url)
    deadline = time.monotonic() + timeout
    sock = DeadlineSocket(raw_sock, deadline)
    started, unmatched = time.monotonic(), 0
    try:
        if method == 'Page.navigate':
            cdp['_ws_send'](sock, json.dumps({'id':10, 'method':'Page.enable'}))
            while True:
                sock.settimeout(max(0.01, deadline - time.monotonic()))
                response = json.loads(cdp['_ws_recv'](sock))
                if response.get('id') == 10:
                    assert 'error' not in response, response
                    break
        request = {'id':1, 'method':method}
        if params is not None:
            request['params'] = params
        cdp['_ws_send'](sock, json.dumps(request))
        while time.monotonic() < deadline:
            sock.settimeout(max(0.01, deadline - time.monotonic()))
            response = json.loads(cdp['_ws_recv'](sock))
            if response.get('method') == 'Page.javascriptDialogOpening':
                dialog = response['params']
                assert method == 'Page.navigate' and dialog['type'] == 'beforeunload', dialog
                emit('beforeunload-dialog', dialog)
                cdp['_ws_send'](sock, json.dumps({'id':2, 'method':'Page.handleJavaScriptDialog', 'params':{'accept':True}}))
            if response.get('id') == 1:
                assert 'error' not in response, (method, response)
                return response.get('result', {})
            if response.get('id') == 2:
                assert 'error' not in response, (method, response)
            unmatched += 1
        raise TimeoutError(f'CDP {method} exceeded {timeout}s')
    except Exception as error:
        emit('cdp-failure', {'method':method, 'target':ws_url, 'elapsed':time.monotonic()-started,
                             'unmatched':unmatched, 'error':repr(error)})
        raise RuntimeError(f'CDP {method} failed: {error!r}') from error
    finally:
        sock.close()
def get(path):
    with urllib.request.urlopen('http://127.0.0.1:9222/' + path, timeout=10) as response:
        return json.load(response)
def emit(kind, value):
    print('BROMURE_STRESS ' + json.dumps({'vm': VM, 'kind': kind, **value}), flush=True)
def evaluate(expression):
    result = call(ws, 'Runtime.evaluate', {'expression': expression, 'returnByValue': True}, timeout=15)
    assert result is not None and 'exceptionDetails' not in result, ('CDP evaluation failed', result)
    return result['result'].get('value')

def kernel_progress():
    for _ in range(28):
        time.sleep(10)
        paths = ['/proc/stat', '/proc/interrupts', '/proc/softirqs', '/proc/pressure/cpu', '/proc/pressure/memory', '/proc/meminfo']
        emit('kernel-progress', {path: Path(path).read_text() for path in paths})
        audio_paths = list(Path('/proc/asound').glob('card*/pcm*/sub*/status')) + list(Path('/proc/asound').glob('card*/pcm*/sub*/hw_params'))
        emit('audio-progress', {str(path):path.read_text() for path in audio_paths})
threading.Thread(target=kernel_progress, daemon=True).start()

def monitor_media(target):
    try:
        sock = DeadlineSocket(cdp['_ws_connect'](target), time.monotonic() + 270)
        try:
            cdp['_ws_send'](sock, json.dumps({'id':1,'method':'Media.enable'}))
            while True:
                response = json.loads(cdp['_ws_recv'](sock))
                if response.get('id') == 1:
                    emit('media-monitor', {'response':response})
                elif response.get('method') in ('Media.playerPropertiesChanged','Media.playerErrorsRaised'):
                    emit('media-event', {'method':response['method'], 'params':response['params']})
        finally:
            sock.close()
    except Exception as error:
        emit('media-monitor-ended', {'error':repr(error)})

try:
    if os.environ.get('BROMURE_X11_TRACE_B64'):
        trace_path = Path('/tmp/bromure-x11-input-trace.py')
        trace_path.write_bytes(base64.b64decode(os.environ['BROMURE_X11_TRACE_B64'], validate=True))
        trace = subprocess.Popen(['runuser', '-u', 'chrome', '--', 'env', 'DISPLAY=:0',
                                  'XAUTHORITY=/home/chrome/.Xauthority', 'python3', str(trace_path),
                                  '--seconds', '60'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        trace_ready = threading.Event()
        def read_trace():
            for line in trace.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    emit('x11-trace-diagnostic', {'line':line.rstrip()})
                    continue
                emit('x11-input', event)
                if event.get('event') == 'ready': trace_ready.set()
            emit('x11-trace-exit', {'code':trace.wait()})
        threading.Thread(target=read_trace, daemon=True).start()
        assert trace_ready.wait(5), 'Passive X11 observer did not become ready before clicks'
    browser = get('json/version')['webSocketDebuggerUrl']
    initial_gpu = call(browser, 'SystemInfo.getInfo')['gpu']
    assert 'virgl' in initial_gpu['auxAttributes']['glRenderer'].lower()
    emit('gpu-state', {'renderer':initial_gpu['auxAttributes']['glRenderer'], 'features':initial_gpu['featureStatus']})
    ws = next(p for p in get('json/list') if p['type'] == 'page')['webSocketDebuggerUrl']
    threading.Thread(target=monitor_media, args=(ws,), daemon=True).start()
    call(ws, 'Page.bringToFront')
    call(ws, 'Page.navigate', {'url': 'data:text/html,<style>html,body{margin:0;background:rgb(240,140,40);height:5000px}button{position:fixed;inset:0;background:rgb(240,140,40);border:0;cursor:crosshair}</style><button></button>'})
    time.sleep(1)
    evaluate("window.hostEvents=[];['pointermove','mousedown','mouseup','click'].forEach(type=>addEventListener(type,e=>hostEvents.push({type,x:e.clientX,y:e.clientY,screenX:e.screenX,screenY:e.screenY,width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screenWidth:screen.width,screenHeight:screen.height,time:Date.now()}),true));true")
    emit('fixture-ready', {})
    if Path('/proc/asound/pcm').exists() and 'playback' in Path('/proc/asound/pcm').read_text():
        def sample_playback():
            for _ in range(16):
                states = {}
                for status in Path('/proc/asound').glob('card*/pcm*p/sub*/status'):
                    try:
                        states[str(status)] = {'status':status.read_text(),
                                               'hwParams':status.with_name('hw_params').read_text()}
                    except OSError as sample_error:
                        states[str(status)] = {'error':str(sample_error)}
                emit('audio-pcm-sample', {'monotonic':time.monotonic(),'states':states})
                time.sleep(0.5)
        threading.Thread(target=sample_playback, daemon=True).start()
        tone = call(ws, 'Runtime.evaluate', {'expression': "(()=>{const c=new AudioContext();const o=c.createOscillator(),g=c.createGain();g.gain.value=0.005;o.connect(g).connect(c.destination);o.start();o.stop(c.currentTime+5);return c.resume().then(()=>({state:c.state,rate:c.sampleRate}))})()", 'awaitPromise':True, 'returnByValue':True, 'userGesture':True}, timeout=15)
        assert tone is not None and 'exceptionDetails' not in tone, ('Audio playback failed', tone)
        emit('audio-playback', tone['result'].get('value', {}))
    else:
        emit('audio-playback-skipped', {'reason':'no playback device; graphics-only diagnostic'})
    for _ in range(27):
        time.sleep(1)
        evaluate('scrollBy(0,80);true')
    events = evaluate('hostEvents')
    clicks = [e for e in events if e['type'] == 'click']
    assert len(clicks) >= 3, events
    assert clicks[0]['width'] != clicks[-1]['width'], clicks
    # The wire uses the full active X screen. Chromium's layout viewport can
    # still have its previous dimensions when the moving-resize click arrives.
    # Evaluate that click against screen geometry, and settled clicks against
    # the DOM viewport. Report both; this is not retained-image hit testing.
    click_checks = []
    for i,e in enumerate(clicks):
        if i == 1:
            click_checks.append({'basis':'host-packet-screen-coordinates',
                                 'requiresExternalCorrelation':True})
            continue
        expected_x = e['width'] * (0.25 if i > 0 else 0.5)
        expected_y = e['height'] * (0.35 if i > 0 else 0.5)
        error_x, error_y = e['x'] - expected_x, e['y'] - expected_y
        click_checks.append({'basis':'DOM-viewport', 'errorX':error_x, 'errorY':error_y})
        assert abs(error_x) <= 3 and abs(error_y) <= 3, (e, click_checks[-1])
    emit('host-click-pass', {'clicks': clicks, 'checks':click_checks})
    sites = ['https://www.slashdot.org/', 'https://www.apple.com/', 'https://www.google.com/',
             'https://www.youtube.com/watch?v=e7VveWeRwUU&list=RDe7VveWeRwUU&start_radio=1',
             'https://en.wikipedia.org/wiki/Metal_(API)', 'https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API',
             'https://github.com/', 'https://www.bbc.com/', 'https://threejs.org/examples/webgl_animation_keyframes.html',
             'https://www.google.com/']
    sites = sites[(VM-1)%len(sites):] + sites[:(VM-1)%len(sites)]
    extra_targets = [call(browser, 'Target.createTarget', {'url':url, 'background':True})['targetId'] for url in sites[:5]]
    primary_ws = ws
    call(ws, 'Page.bringToFront')
    emit('tabs-open', {'totalTabs':len([p for p in get('json/list') if p['type']=='page'])})
    for url in sites:
        navigation_started = time.monotonic()
        response = call(ws, 'Page.navigate', {'url': url}, timeout=20)
        if response.get('errorText'):
            emit('network-error', {'requested': url, 'error': response['errorText']})
            raise RuntimeError(f"Navigation failed: {url}: {response['errorText']}")
        # A fixed three-second sleep can send the first wheel to a document
        # whose renderer has no input surface yet. Wait for a ready document
        # and a composited frame before testing interaction, recording delays.
        ready_deadline = time.monotonic() + 30
        while True:
            readiness = evaluate("({url:location.href,ready:document.readyState,body:!!document.body,title:document.title})")
            if readiness['ready'] in ('interactive','complete') and readiness['body']:
                break
            assert time.monotonic() < ready_deadline, ('Document did not become ready',url,readiness)
            time.sleep(0.25)
        first_frame = call(ws,'Page.captureScreenshot',{'format':'png'},timeout=20)
        assert first_frame and first_frame.get('data'), ('No first composited frame',url)
        emit('page-ready', {'requested':url,'elapsed':time.monotonic()-navigation_started,**readiness})
        # A painted sentinel makes transient whole-frame clears distinguishable
        # from intentional dark page/video content. It never receives input.
        evaluate("(()=>{const d=document.createElement('div');d.id='bromurePresentationSentinel';d.style='position:fixed;left:calc(50% - 24px);top:0;width:48px;height:100vh;background:rgb(240,140,40);z-index:2147483647;pointer-events:none';document.documentElement.append(d);document.querySelectorAll('video').forEach(v=>{v.muted=true;v.play().catch(()=>{})});return true})()")
        for step in range(5):
            call(ws, 'Input.dispatchMouseEvent', {'type':'mouseWheel','x':200,'y':200,'deltaX':0,'deltaY':400 if step<3 else -300}, timeout=10)
            time.sleep(1)
            state = evaluate("({url:location.href,title:document.title,ready:document.readyState,bodyBytes:document.body?.innerText.length||0,scrollY,visibleSentinel:!!document.getElementById('bromurePresentationSentinel'),video:[...document.querySelectorAll('video')].map(v=>({time:v.currentTime,ready:v.readyState,paused:v.paused,error:v.error?.code||null,total:v.getVideoPlaybackQuality().totalVideoFrames,dropped:v.getVideoPlaybackQuality().droppedVideoFrames}))})")
            emit('page-sample', {'requested':url,'step':step,**state})
        screenshot = call(ws, 'Page.captureScreenshot', {'format':'png'}, timeout=20)
        assert screenshot is not None and 'data' in screenshot, ('Screenshot failed', url)
        emit('page-complete', {'requested':url,'screenshotSHA256':hashlib.sha256(screenshot['data'].encode()).hexdigest()})
    for target in extra_targets:
        call(browser, 'Target.activateTarget', {'targetId':target})
        ws = next(p for p in get('json/list') if p['id']==target)['webSocketDebuggerUrl']
        time.sleep(1)
        state = evaluate("({url:location.href,title:document.title,ready:document.readyState})")
        evaluate('scrollBy(0,500);true')
        time.sleep(1)
        emit('tab-switch', state)
    ws = primary_ws
    call(ws, 'Page.bringToFront')
    for target in extra_targets:
        call(browser, 'Target.closeTarget', {'targetId':target})
    time.sleep(3)
    emit('tabs-closed', {'remainingTabs':len([p for p in get('json/list') if p['type']=='page'])})
    final_gpu = call(browser, 'SystemInfo.getInfo')['gpu']
    assert final_gpu['auxAttributes']['processCrashCount'] == initial_gpu['auxAttributes']['processCrashCount'], final_gpu['auxAttributes']
    emit('pass', {'sites':len(sites),'renderer':final_gpu['auxAttributes']['glRenderer'],'gpuProcessCrashes':final_gpu['auxAttributes']['processCrashCount']})
    print('BROMURE_GPU_ACCEPTANCE_PASS', flush=True)
except Exception as error:
    emit('fail', {'error':repr(error), 'interrupts':subprocess.run(['cat','/proc/interrupts'],capture_output=True,text=True,timeout=3).stdout, 'processes':subprocess.run(['ps','-eo','pid,stat,pcpu,comm'],capture_output=True,text=True,timeout=3).stdout})
    # Preserve the failed operation; follow-up probes distinguish a blocked
    # renderer from a live browser/guest instead of turning a retry into PASS.
    for name, probe in [
        ('targets', lambda:get('json/list')),
        ('browser-gpu', lambda:call(browser,'SystemInfo.getInfo',timeout=3)),
        ('page-tree', lambda:call(ws,'Page.getFrameTree',timeout=3)),
        ('page-runtime', lambda:call(ws,'Runtime.evaluate',{'expression':'({url:location.href,ready:document.readyState,now:Date.now()})','returnByValue':True},timeout=3)),
    ]:
        try:
            emit('failure-diagnostic', {'name':name,'result':probe()})
        except Exception as diagnostic_error:
            emit('failure-diagnostic', {'name':name,'error':repr(diagnostic_error)})
    threads = subprocess.run(['ps','-eLo','pid,tid,stat,pcpu,wchan:40,comm','--sort=-pcpu'],capture_output=True,text=True,timeout=3)
    emit('failure-threads', {'threads':threads.stdout[:40000]})
    # Include every main thread and helper thread; Chromium154 names several
    # process leaders simply "chromium", so a comm whitelist misses the waits.
    for snapshot in range(2):
        for process in Path('/proc').iterdir():
            if not process.name.isdigit(): continue
            try:
                cmd = (process/'cmdline').read_bytes()
                if b'chromium' not in cmd: continue
                tasks = []
                for task in (process/'task').iterdir():
                    row = {'tid':int(task.name)}
                    for field in ('comm','wchan','stat','syscall','stack'):
                        try: row[field] = (task/field).read_text()[:4096]
                        except OSError as capture_error: row[field] = {'error':str(capture_error)}
                    tasks.append(row)
                emit('failure-process-threads', {'snapshot':snapshot,'monotonic':time.monotonic(),
                     'pid':int(process.name),'cmdline':cmd.replace(b'\0',b' ').decode(errors='replace')[:4096],
                     'tasks':tasks})
            except OSError:
                continue
        if snapshot == 0: time.sleep(1)
    emit('failure-xorg-tail', {'log':subprocess.run(['tail','-n','80','/tmp/startx.log'],capture_output=True,text=True,timeout=3).stdout})
    raise
