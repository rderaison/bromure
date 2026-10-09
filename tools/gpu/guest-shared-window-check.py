#!/usr/bin/env python3
"""Private two-scanout proof: both windows belong to the same browser process."""
import json, pathlib, runpy, sys, time, urllib.request
sys.path.insert(0, '/usr/local/bin')
call = runpy.run_path('/usr/local/bin/tab-agent.py')['cdp_ws_call']

def browser_processes():
    result = []
    for directory in pathlib.Path('/proc').glob('[0-9]*'):
        try:
            executable = (directory / 'exe').resolve().name
            command = (directory / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            if executable in ('chrome', 'chromium') and '--type=' not in command:
                # starttime is field22; comm may contain spaces.
                stat = (directory / 'stat').read_text().rsplit(')', 1)[1].split()
                result.append({'pid': int(directory.name), 'startTicks': int(stat[19]), 'command': command})
        except OSError:
            pass
    return sorted(result, key=lambda row: row['pid'])

before = browser_processes()
assert len(before) == 1, before
print('BROMURE_SHARED_BROWSER_BEFORE ' + json.dumps(before), flush=True)
deadline = time.monotonic() + 60
while True:
    with urllib.request.urlopen('http://127.0.0.1:9222/json/list', timeout=3) as response:
        pages = [page for page in json.load(response) if page['type'] == 'page']
    if len(pages) == 2:
        break
    assert time.monotonic() < deadline, pages
    time.sleep(.2)
with urllib.request.urlopen('http://127.0.0.1:9222/json/version', timeout=3) as response:
    browser_ws = json.load(response)['webSocketDebuggerUrl']
info = call(browser_ws, 'SystemInfo.getInfo', timeout=10)
assert 'virgl' in info['gpu']['auxAttributes']['glRenderer'].lower(), info
records = []
for page in pages:
    result = call(browser_ws, 'Browser.getWindowForTarget', {'targetId': page['id']}, timeout=10)
    bounds = call(browser_ws, 'Browser.getWindowBounds', {'windowId': result['windowId']}, timeout=10)['bounds']
    records.append((result['windowId'], page, bounds))
records.sort(key=lambda row: row[2]['left'])
assert len({wid for wid, page, bounds in records}) == 2, records
assert [row[2]['left'] for row in records] == [0, 640], records
for index, (wid, page, bounds) in enumerate(records):
    colour = [[22, 160, 74], [32, 84, 210]][index]
    expression = '''(()=>{document.body.style.cssText='margin:0;overflow:hidden';document.body.innerHTML='';
const c=document.createElement('canvas');c.width=innerWidth*devicePixelRatio;c.height=innerHeight*devicePixelRatio;
c.style.cssText='width:100vw;height:100vh;display:block';document.body.append(c);
const gl=c.getContext('webgl2');if(!gl)throw Error('WebGL2 unavailable');
gl.clearColor(__COLOUR__[0]/255,__COLOUR__[1]/255,__COLOUR__[2]/255,1);gl.clear(gl.COLOR_BUFFER_BIT);
const px=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,px);
return {pixel:Array.from(px),width:innerWidth,height:innerHeight};})()'''.replace('__COLOUR__', json.dumps(colour))
    result = call(page['webSocketDebuggerUrl'], 'Runtime.evaluate', {'expression': expression, 'returnByValue': True}, timeout=15)
    assert result and 'exceptionDetails' not in result and result['result']['value']['pixel'] == colour + [255], result
    print('BROMURE_SHARED_WINDOW_WEBGL ' + json.dumps({'windowId': wid, 'targetId': page['id'], 'result': result['result']['value']}), flush=True)
after = browser_processes()
assert after == before, (before, after)
print('BROMURE_SHARED_BROWSER_AFTER ' + json.dumps(after), flush=True)
print('BROMURE_GPU_ACCEPTANCE_PASS', flush=True)
