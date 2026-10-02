import base64, json, pathlib, runpy, statistics, time, urllib.request
agent=runpy.run_path('/usr/local/bin/tab-agent.py')
call=agent['cdp_ws_call']
def get(path):
 with urllib.request.urlopen('http://127.0.0.1:9222/'+path,timeout=10) as response:return json.load(response)
version=get('json/version');browser=version['webSocketDebuggerUrl']
gpu=call(browser,'SystemInfo.getInfo',timeout=10)['gpu']
page=next(x for x in get('json/list') if x['type']=='page');ws=page['webSocketDebuggerUrl']
def evaluate(code,timeout=120):
 reply=call(ws,'Runtime.evaluate',{'expression':code,'returnByValue':True,'awaitPromise':True},timeout=timeout)
 assert reply and 'exceptionDetails' not in reply,reply
 return reply['result']['value']
# Readiness is checked rather than hidden by a fixed startup sleep.
for attempt in range(20):
 ready=call(ws,'Runtime.evaluate',{'expression':'document.readyState','returnByValue':True},timeout=3)
 if ready:break
 time.sleep(1)
else:raise RuntimeError('Page did not become responsive')
setup=evaluate(base64.b64decode('__THROUGHPUT__').decode());samples=[]
for trial in range(5):
 cases=setup['cases'];cases=cases[trial%len(cases):]+cases[:trial%len(cases)]
 for case in cases:
  row=evaluate('window.bromureBenchmark('+json.dumps(case['name'])+')');row['trial']=trial+1;samples.append(row)
visible=evaluate(base64.b64decode('__VISIBLE__').decode(),timeout=100)
end=call(browser,'SystemInfo.getInfo',timeout=10)['gpu']
passed=not visible['hiddenDuringTest'] and not visible['geometryChanged'] and visible['frames']>0 and visible['visibility']=='visible' and visible['glError']==0 and end['auxAttributes']['processCrashCount']==gpu['auxAttributes']['processCrashCount']
result={'passed':passed,'browser':version['Browser'],'renderer':gpu['auxAttributes']['glRenderer'],
 'gpuCrashCountBefore':gpu['auxAttributes']['processCrashCount'],'gpuCrashCountAfter':end['auxAttributes']['processCrashCount'],
 'throughput':samples,'visible':visible,'imageBuild':pathlib.Path('/opt/bromure/mesa-virgl/graphics-build.txt').read_text() if pathlib.Path('/opt/bromure/mesa-virgl/graphics-build.txt').exists() else None}
print('BROMURE_SCREEN_RESULT '+json.dumps(result),flush=True)
assert passed,result
print('BROMURE_GPU_ACCEPTANCE_PASS',flush=True)
