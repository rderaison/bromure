#!/usr/bin/env python3
"""Actual two-screen Chromium/GL/input regression; run in experimental guest."""
import json,pathlib,runpy,time,urllib.request
agent=runpy.run_path('/usr/local/bin/tab-agent.py');call=agent['cdp_ws_call']
topology=json.loads(pathlib.Path('/run/bromure-multigpu/displays.json').read_text())
assert len(topology['devices'])==2
pages=[]
for index,device in enumerate(topology['devices']):
 port=device['cdpPort'];deadline=time.monotonic()+60
 while True:
  try:
   with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/version',timeout=3) as response:version=json.load(response)
   with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list',timeout=3) as response:targets=json.load(response)
   page=next(t for t in targets if t['type']=='page')
   info=call(version['webSocketDebuggerUrl'],'SystemInfo.getInfo',timeout=10)
   assert info and 'virgl' in info['gpu']['auxAttributes']['glRenderer'].lower()
   assert device['render'] in info['commandLine'],info['commandLine']
   break
  except Exception:
   if time.monotonic()>=deadline:raise
   time.sleep(1)
 ws=page['webSocketDebuggerUrl'];pages.append(ws)
 colour=[[22,160,74],[32,84,210]][index]
 script='''(()=>{document.body.style.cssText='margin:0;overflow:auto';document.body.innerHTML='';
 const c=document.createElement('canvas');c.width=innerWidth*devicePixelRatio;c.height=innerHeight*devicePixelRatio;
 c.style.cssText='width:100vw;height:100vh;display:block';document.body.append(c);
 const gl=c.getContext('webgl2');if(!gl)throw Error('No WebGL2');
 gl.clearColor(COLOUR[0]/255,COLOUR[1]/255,COLOUR[2]/255,1);gl.clear(gl.COLOR_BUFFER_BIT);
 const px=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,px);
 const field=document.createElement('input');field.id='input';field.style.cssText='position:fixed;left:35%;top:35%;width:30%;height:30px;font-size:24px';document.body.append(field);
 const spacer=document.createElement('div');spacer.style.height='3000px';document.body.append(spacer);
 window.events=[];for(const type of ['mousedown','mouseup','wheel','keydown'])document.addEventListener(type,e=>events.push({type,button:e.button,key:e.key,x:e.screenX,y:e.screenY}),true);
 document.addEventListener('mouseup',()=>field.focus());document.title='GPU INDEX test fixture';return {pixel:Array.from(px),renderer:gl.getParameter(gl.RENDERER)};})()'''.replace('COLOUR',json.dumps(colour)).replace('INDEX',str(index))
 result=call(ws,'Runtime.evaluate',{'expression':script,'returnByValue':True},timeout=20)
 assert result and 'exceptionDetails' not in result,result
 assert result['result']['value']['pixel']==colour+[255],result
 print('BROMURE_MULTIGPU_SCREEN '+json.dumps({'index':index,'pci':device['pci'],'render':device['render'],'gpu':info['gpu']['auxAttributes'],'fixture':result['result']['value']}),flush=True)
time.sleep(3) # Allow the compositor and host presentation to receive both fixtures.
print('BROMURE_MULTIGPU_FIXTURES_READY',flush=True)
# Allow actual host events, rather than injecting CDP clicks and claiming input acceptance.
time.sleep(25)
for index,ws in enumerate(pages):
 result=call(ws,'Runtime.evaluate',{'expression':'JSON.stringify({events:window.events,value:document.querySelector("#input").value,scroll:scrollY})','returnByValue':True},timeout=10)
 assert result,result
 state=json.loads(result['result']['value'])
 print('BROMURE_MULTIGPU_INPUT '+json.dumps({'index':index,'state':state}),flush=True)
 assert state['value']==('ac' if index==0 else 'b'),state
 assert any(e['type']=='mousedown' for e in state['events']) and any(e['type']=='mouseup' for e in state['events']),state
 assert state['scroll']>0,state
print('BROMURE_MULTIGPU_ACCEPTANCE_PASS',flush=True)
