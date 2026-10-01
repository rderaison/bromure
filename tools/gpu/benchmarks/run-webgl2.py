#!/usr/bin/env python3
"""Same Chrome/WebGL2 benchmark on native macOS or inside a Bromure guest."""
import argparse, json, pathlib, runpy, statistics, time, urllib.request
p=argparse.ArgumentParser()
p.add_argument('--agent',required=True,help='Path to Bromure tab-agent.py (CDP transport)')
p.add_argument('--workload',default=str(pathlib.Path(__file__).with_name('webgl2-workload.js')))
p.add_argument('--cdp-base',default='http://127.0.0.1:9222')
p.add_argument('--expected-renderer',required=True)
p.add_argument('--trials',type=int,default=5)
p.add_argument('--allow-software',action='store_true',help='Only for the Apple VZ Linux software-rendering baseline')
p.add_argument('--output')
a=p.parse_args();assert 3<=a.trials<=20
call=runpy.run_path(a.agent)['cdp_ws_call']
def get(path):
 with urllib.request.urlopen(a.cdp_base+'/'+path,timeout=10) as r:return json.load(r)
version=get('json/version');gpu=call(version['webSocketDebuggerUrl'],'SystemInfo.getInfo')['gpu']
renderer=gpu['auxAttributes']['glRenderer'];assert a.expected_renderer.lower() in renderer.lower(),renderer
if not a.allow_software:
 assert 'swiftshader' not in renderer.lower() and 'llvmpipe' not in renderer.lower(),renderer
page=next(p for p in get('json/list') if p['type']=='page');ws=page['webSocketDebuggerUrl']
call(ws,'Page.navigate',{'url':'about:blank'});time.sleep(1)
def evaluate(expression):
 r=call(ws,'Runtime.evaluate',{'expression':expression,'returnByValue':True},timeout=120)
 assert r and 'exceptionDetails' not in r,r
 return r['result']['value']
setup=evaluate(pathlib.Path(a.workload).read_text());rows=[]
# Rotate workload order to reduce systematic warming/thermal bias.
for trial in range(a.trials):
 cases=setup['cases'];order=cases[trial%len(cases):]+cases[:trial%len(cases)]
 for c in order:
  row=evaluate('window.bromureBenchmark('+json.dumps(c['name'])+')');row['trial']=trial+1;rows.append(row)
  print('BENCHMARK_SAMPLE '+json.dumps(row),flush=True);time.sleep(.25)
summary={}
for c in setup['cases']:
 samples=[r['elapsedMs'] for r in rows if r['name']==c['name']]
 median=statistics.median(samples)
 summary[c['name']]={**c,'medianMs':median,'minMs':min(samples),'maxMs':max(samples),
   'medianDrawsPerSecond':c['draws']*1000/median,'samplesMs':samples}
result={'browser':version['Browser'],'renderer':renderer,'gpuCompositing':gpu['featureStatus']['gpu_compositing'],
 'setup':setup,'trials':a.trials,'summary':summary,'samples':rows,
 'method':'Offscreen RGBA8 WebGL2, antialiasing off, identical GLSL/draw counts/resolution, 8 warm-up draws per sample, alpha-blended draws prevent last-draw-only elimination; wall-clock batch time includes synchronous 1-pixel readback at batch end to force GPU completion. Compilation and allocation excluded. Includes browser/driver/readback overhead, not a pure GPU hardware timer.'}
if a.output:pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
print('BROMURE_BENCHMARK_RESULT '+json.dumps(result),flush=True)
print('BROMURE_GPU_ACCEPTANCE_PASS',flush=True)
