#!/usr/bin/env python3
"""Build a private gpu-browser guest probe from a local clip; no bundled media."""
import argparse
import base64
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--clip',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--animated-siblings',action='store_true')
args=parser.parse_args()
observer=Path(__file__).with_name('observe-video-cadence.js').read_text()
body=r'''
import base64,pathlib,http.server,threading,runpy,urllib.request,json,time,subprocess
root=pathlib.Path('/tmp/window-video');root.mkdir(exist_ok=True)
root.joinpath('clip.mp4').write_bytes(base64.b64decode(CLIP))
class Handler(http.server.SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(root),**kw)
 def log_message(self,*a):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',8767),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
call=runpy.run_path('/usr/local/bin/shared_windows.py')['cdp_call']
def get(p):return json.load(urllib.request.urlopen('http://127.0.0.1:9222/'+p,timeout=5))
time.sleep(10)
browser=get('json/version')['webSocketDebuggerUrl']
pages=[p for p in get('json/list') if p['type']=='page']
rows=[(call(browser,'Browser.getWindowForTarget',{'targetId':p['id']}),p) for p in pages]
rows.sort(key=lambda r:(r[0]['bounds']['left'],r[0]['bounds']['top']))
print('WINDOW_VIDEO_GEOMETRY '+json.dumps([r[0] for r in rows]),flush=True)
subprocess.run(['runuser','-u','chrome','--','env','DISPLAY=:0','XAUTHORITY=/home/chrome/.Xauthority','xrandr','--query'])
for bounds,p in rows:
 call(p['webSocketDebuggerUrl'],'Runtime.evaluate',{'expression':"document.body.style.background='blue';document.body.innerHTML='';true",'returnByValue':True})
ws=rows[0][1]['webSocketDebuggerUrl']
call(ws,'Page.bringToFront',{})
tab=runpy.run_path('/usr/local/bin/tab-agent.py')
media=[]
media_socket=tab['_ws_connect'](ws)
media_socket.settimeout(90)
tab['_ws_send'](media_socket,json.dumps({'id':42,'method':'Media.enable'}))
while True:
 msg=json.loads(tab['_ws_recv'](media_socket))
 if msg.get('id')==42:
  assert 'error' not in msg,msg
  break
def observe_media():
 try:
  while len(media)<1000:
   msg=json.loads(tab['_ws_recv'](media_socket))
   if msg.get('method','').startswith('Media.'):media.append(msg)
 except Exception:pass
threading.Thread(target=observe_media,daemon=True).start()
expr="""(async()=>{document.body.style.margin='0';document.body.innerHTML='<video muted loop style="width:100%;height:100vh;object-fit:contain"></video>';let v=document.querySelector('video');v.src='http://127.0.0.1:8767/clip.mp4';await v.play();return [v.videoWidth,v.videoHeight];})()"""
print('WINDOW_VIDEO_START '+json.dumps(call(ws,'Runtime.evaluate',{'expression':expr,'awaitPromise':True,'returnByValue':True},timeout=15)),flush=True)
time.sleep(3)
for trial in range(3):
 result=call(ws,'Runtime.evaluate',{'expression':OBSERVER,'awaitPromise':True,'returnByValue':True},timeout=15)
 print('WINDOW_VIDEO_RESULT '+json.dumps({'windows':len(rows),'trial':trial,'result':result}),flush=True)
print('WINDOW_VIDEO_MEDIA '+json.dumps(media),flush=True)
media_socket.close()
print('BROMURE_GPU_ACCEPTANCE_PASS',flush=True)
'''
if args.animated_siblings:
    body=body.replace("ws=rows[0][1]['webSocketDebuggerUrl']", 'for bounds,p in rows[1:]:\n call(p[\'webSocketDebuggerUrl\'],\'Runtime.evaluate\',{\'expression\':"document.body.innerHTML=\'<canvas></canvas>\';let c=document.querySelector(\'canvas\');c.width=960;c.height=570;c.style.width=\'100%\';let ctx=c.getContext(\'2d\'),n=0;function animate(){ctx.fillStyle=\'rgb(32,84,210)\';ctx.fillRect(0,0,960,570);ctx.fillStyle=\'white\';ctx.fillRect((n++*8)%960,0,80,570);requestAnimationFrame(animate);}animate();true",\'returnByValue\':True})\n'+"ws=rows[0][1]['webSocketDebuggerUrl']")
args.output.write_text('CLIP='+repr(base64.b64encode(args.clip.read_bytes()).decode())+'\nOBSERVER='+repr(observer)+'\n'+body)
