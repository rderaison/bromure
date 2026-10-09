#!/usr/bin/env python3
"""Controlled browser playback counters and actual Media-domain decoder evidence."""
import argparse
import http.server
import json
import pathlib
import runpy
import socket
import statistics
import subprocess
import threading
import time
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('--agent', required=True)
p.add_argument('--cdp-base', default='http://127.0.0.1:9222')
p.add_argument('--clips', required=True)
p.add_argument('--seconds', type=int, default=60)
p.add_argument('--trials', type=int, default=5)
p.add_argument('--output')
p.add_argument('--diagnostics', action='store_true', help='Linux process/memory snapshots and stderr on failure; diagnostic runs only')
a = p.parse_args()
assert 1 <= a.trials <= 5 and 5 <= a.seconds <= 120
root = pathlib.Path(a.clips)
manifest = json.loads((root / 'manifest.json').read_text())
agent = runpy.run_path(a.agent)
call = agent['cdp_ws_call']
def get(path):
    with urllib.request.urlopen(a.cdp_base + '/' + path, timeout=10) as r:
        return json.load(r)
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:' + str(server.server_port)
version = get('json/version')
gpu = call(version['webSocketDebuggerUrl'], 'SystemInfo.getInfo')['gpu']
page = next(x for x in get('json/list') if x['type'] == 'page')
ws = page['webSocketDebuggerUrl']
def evaluate(expression):
    r = control_call('Runtime.evaluate', {'expression': expression, 'returnByValue': True,
             'awaitPromise': True, 'userGesture': True}, timeout=20)
    assert 'exceptionDetails' not in r, r
    return r['result']['value']
def diagnostic_inventory():
    if not pathlib.Path('/proc/meminfo').exists():
        return {'available': False}
    processes = []
    for directory in pathlib.Path('/proc').iterdir():
        if not directory.name.isdecimal():
            continue
        try:
            command = (directory / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            if '--type=gpu-process' not in command and '--type=renderer' not in command:
                continue
            processes.append({'pid':int(directory.name),'command':command,
                'status':(directory/'status').read_text(),
                'fds':len(list((directory/'fd').iterdir())),
                'smapsRollup':(directory/'smaps_rollup').read_text()})
        except (OSError, ValueError):
            continue
    return {'meminfo':pathlib.Path('/proc/meminfo').read_text(), 'processes':processes,
        'pressure':pathlib.Path('/proc/pressure/memory').read_text()}

samples = []
for trial in range(a.trials):
    cases = manifest['clips']
    order = cases[trial % len(cases):] + cases[:trial % len(cases)]
    for case in order:
        call(ws, 'Page.navigate', {'url': base + '/index.html'})
        time.sleep(1)
        connection = agent['_ws_connect'](ws)
        connection.settimeout(a.seconds + 30)
        properties, errors, messages = {}, [], []
        responses = {}
        response_condition = threading.Condition()
        request_id = 1
        stopped = threading.Event()
        def media_reader():
            try:
                while not stopped.is_set():
                    event = json.loads(agent['_ws_recv'](connection))
                    params = event.get('params', {})
                    if 'id' in event:
                        with response_condition:
                            responses[event['id']] = event
                            response_condition.notify_all()
                    if event.get('method') == 'Media.playerPropertiesChanged':
                        properties.setdefault(params['playerId'], {}).update(
                            {x['name']: x['value'] for x in params['properties']})
                    elif event.get('method') == 'Media.playerErrorsRaised':
                        errors.extend(params.get('errors', []))
                    elif event.get('method') == 'Media.playerMessagesLogged':
                        messages.extend(params.get('messages', []))
            except (OSError, EOFError, ValueError):
                pass
        agent['_ws_send'](connection, json.dumps({'id': 1, 'method': 'Media.enable'}))
        reader = threading.Thread(target=media_reader, daemon=True)
        reader.start()
        def control_call(method, params, timeout=20):
            global request_id
            request_id += 1
            current_id = request_id
            agent['_ws_send'](connection, json.dumps({'id':current_id,'method':method,'params':params}))
            with response_condition:
                assert response_condition.wait_for(lambda:current_id in responses, timeout), method
                reply = responses.pop(current_id)
            assert 'error' not in reply, reply
            return reply['result']
        try:
            control_call('Emulation.setDeviceMetricsOverride', {'width':960,'height':540,
                         'deviceScaleFactor':2,'mobile':False,'screenWidth':960,'screenHeight':540})
            setup = evaluate('''(async () => {
              document.body.style.margin='0'; document.body.style.background='black';
              const v=document.createElement('video'); window.benchVideo=v;
              window.fullscreenEvents=[];document.addEventListener('fullscreenchange',()=>{
                window.fullscreenEvents.push({wall:performance.now(),fullscreen:document.fullscreenElement===v});});
              v.muted=true; v.loop=true; v.style.cssText='width:100vw;height:100vh;object-fit:contain';
              v.src=''' + json.dumps(base + '/' + case['file']) + ''';
              document.body.appendChild(v);
              await v.play();
              return {width:v.videoWidth,height:v.videoHeight,
                viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},
                screen:{width:screen.width,height:screen.height,dpr:devicePixelRatio}};
            })()''')
            assert setup['width'] == case['width'] and setup['height'] == case['height'], setup
            assert setup['viewport'] == {'width':960,'height':540,'dpr':2}, setup
            time.sleep(3)
            evaluate('''(() => {const v=window.benchVideo;window.benchClock={mediaSeconds:0,lastTime:v.currentTime,samples:0};
              window.benchClockTimer=setInterval(()=>{const c=window.benchClock;
                let delta=v.currentTime-c.lastTime;if(delta<0)delta+=v.duration;
                c.mediaSeconds+=delta;c.lastTime=v.currentTime;c.samples++;},100);return true;})()''')
            expression = '''(() => {const v=window.benchVideo,q=v.getVideoPlaybackQuality();return {
              total:q.totalVideoFrames,dropped:q.droppedVideoFrames,currentTime:v.currentTime,
              error:v.error&&{code:v.error.code,message:v.error.message},paused:v.paused,
              readyState:v.readyState,fullscreen:document.fullscreenElement===v,
              mediaClock:window.benchClock,
              wall:performance.now(),visibility:document.visibilityState,fullscreenEvents:window.fullscreenEvents};})()'''
            diagnostics_before = diagnostic_inventory() if a.diagnostics else None
            before = evaluate(expression)
            print('BROMURE_VIDEO_START ' + json.dumps({'case': case['name'], 'trial': trial+1,
                  'wallTime': time.time()}), flush=True)
            time.sleep(a.seconds)
            after = evaluate(expression)
            elapsed = (after['wall'] - before['wall']) / 1000
            total = after['total'] - before['total']
            dropped = after['dropped'] - before['dropped']
            clock = after['mediaClock']
            tail = after['currentTime'] - clock['lastTime']
            if tail < 0:
                tail += case['durationSeconds']
            media_seconds = clock['mediaSeconds'] + tail
            decoders = [v for v in properties.values() if 'kVideoDecoderName' in v]
            trial_succeeded = total > 0 and dropped >= 0 and after['error'] is None and not after['paused'] and bool(decoders)
            row = {'case':case['name'], 'trial':trial+1, 'elapsedSeconds':elapsed,
                   'totalVideoFrames':total,'droppedVideoFrames':dropped,
                   'dropRatePercent':100*dropped/total if total else None,
                   'trialSucceeded':trial_succeeded, 'before':before,'after':after,
                   'presentedFramesPerSecond':(total-dropped)/elapsed,
                   'mediaSecondsAdvanced':media_seconds,'playbackSpeedRatio':media_seconds/elapsed,
                   'setup':setup,'mediaPlayers':properties,'mediaErrors':errors,'mediaMessages':messages,
                   'wallTime':time.time()}
            if a.diagnostics:
                row['diagnostics'] = {'before':diagnostics_before,'after':diagnostic_inventory()}
                if not trial_succeeded:
                    row['diagnostics']['dmesg'] = subprocess.run(['dmesg'],capture_output=True,text=True,timeout=10).stdout[-30000:]
                    log = pathlib.Path('/tmp/startx.log')
                    row['diagnostics']['chromeLog'] = log.read_text(errors='replace')[-40000:] if log.exists() else ''
            samples.append(row)
            print('BROMURE_VIDEO_SAMPLE '+json.dumps(row), flush=True)
            evaluate('(async()=>{clearInterval(window.benchClockTimer);window.benchVideo.pause();if(document.fullscreenElement)await document.exitFullscreen();return true;})()')
        finally:
            stopped.set()
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
            reader.join(timeout=2)
summary = {}
for case in manifest['clips']:
    rows = [x for x in samples if x['case']==case['name']]
    rates = [x['dropRatePercent'] for x in rows if x['dropRatePercent'] is not None]
    summary[case['name']] = {'medianDropRatePercent':statistics.median(rates) if rates else None,
        'minDropRatePercent':min(rates) if rates else None,'maxDropRatePercent':max(rates) if rates else None,
        'failedTrials':sum(not x['trialSucceeded'] for x in rows),
        'samplesDropRatePercent':rates}
    summary[case['name']]['medianPresentedFramesPerSecond'] = statistics.median(x['presentedFramesPerSecond'] for x in rows)
    summary[case['name']]['medianPlaybackSpeedRatio'] = statistics.median(x['playbackSpeedRatio'] for x in rows)
result = {'browser':version['Browser'],'renderer':gpu['auxAttributes']['glRenderer'],
          'clips':manifest,'secondsPerTrial':a.seconds,'trials':a.trials,'samples':samples,'summary':summary,
          'method':'Muted local synthetic clips looped and filling a controlled 960x540 CSS viewport at DPR2 (1920x1080 physical rendering); 3s warm-up, then fixed-duration counter deltas. DOM/OS fullscreen is not used because guest fullscreen exited during setup. Browser frame counters do not measure host display presentation latency or audio synchronization.'}
if a.output:
    pathlib.Path(a.output).write_text(json.dumps(result, indent=2)+'\n')
print('BROMURE_VIDEO_RESULT '+json.dumps(result),flush=True)
print('BROMURE_VIDEO_RUN_COMPLETE',flush=True)
if all(x['trialSucceeded'] for x in samples):
    print('BROMURE_GPU_ACCEPTANCE_PASS',flush=True)
else:
    print('BROMURE_GPU_ACCEPTANCE_FAIL',flush=True)
server.shutdown()
