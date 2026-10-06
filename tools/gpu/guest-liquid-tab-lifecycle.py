import json,time,urllib.request,sys,os
sys.path.insert(0,'/usr/local/bin')
from shared_windows import cdp_call
os.environ.update(DISPLAY=':0',XAUTHORITY='/home/chrome/.Xauthority')
def get(path): return json.load(urllib.request.urlopen('http://127.0.0.1:9222'+path,timeout=3))
ws=get('/json/version')['webSocketDebuggerUrl']
def call(m,p): return cdp_call(ws,m,p,timeout=5)
t=call('Target.createTarget',{'url':'about:blank','newWindow':False})['targetId']
time.sleep(.3)
p=next(x for x in get('/json/list') if x['id']==t)
cdp_call(p['webSocketDebuggerUrl'],'Runtime.evaluate',{'expression':'window.tearOffProof={sentinel:12345};document.title="LIQUID DETACH SENTINEL"; document.body.innerHTML="<h1>Tab state preserved</h1><input value=preserved>"; document.body.style.background="#ddf0ff"','returnByValue':True},timeout=3)
old=call('Browser.getWindowForTarget',{'targetId':t})['windowId']
print('BROMURE_LIQUID_FIXTURE_READY',json.dumps({'target':t,'source':old}),flush=True)
deadline=time.monotonic()+40
while time.monotonic()<deadline:
 new=call('Browser.getWindowForTarget',{'targetId':t})['windowId']
 if new!=old:
  time.sleep(2)
  v=cdp_call(p['webSocketDebuggerUrl'],'Runtime.evaluate',{'expression':'[window.tearOffProof.sentinel,document.querySelector("input").value]','returnByValue':True},timeout=3)['result'].get('value')
  assert v==[12345,'preserved'],v
  print('BROMURE_LIQUID_PAGE_STATE_PASS',json.dumps({'target':t,'source':old,'destination':new,'value':v}),flush=True)
  break
 time.sleep(.25)
else: raise RuntimeError('No native detach seen')
