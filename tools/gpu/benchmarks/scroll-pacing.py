#!/usr/bin/env python3
"""Compare guest animation pacing on identical deterministic scrolling content.

Use gpu-browser --guest-probe with the same image, scale and window dimensions.
This measures Chromium requestAnimationFrame pacing, not host presentation latency.
"""
import json
import runpy
import time
import urllib.parse
import urllib.request

call = runpy.run_path('/usr/local/bin/tab-agent.py')['cdp_ws_call']
with urllib.request.urlopen('http://127.0.0.1:9222/json/list', timeout=5) as response:
    page = [p for p in json.load(response) if p['type'] == 'page'][-1]
ws = page['webSocketDebuggerUrl']
html = '<style>body{margin:0;background:#182333;color:white;font:24px sans-serif}article{margin:20px;padding:30px;height:180px;border-radius:20px;box-shadow:0 5px 15px #0008;background:linear-gradient(120deg,#236a88,#674197)}</style>'
html += '<div id=fixture style="width:500px;height:410px;overflow:auto">'
html += ''.join(f'<article>Scroll pacing fixture {i}<p>Deterministic text, gradients and shadows</p></article>' for i in range(100))
html += '</div>'
call(ws, 'Page.bringToFront')
call(ws, 'Page.navigate', {'url': 'data:text/html,' + urllib.parse.quote(html)})
time.sleep(2)
call(ws, 'Runtime.evaluate', {'expression': '''
window.pacing = {intervals: [], width: fixture.clientWidth, height: fixture.clientHeight, dpr: devicePixelRatio};
let start, previous;
function tick(now) {
  if (start === undefined) start = now;
  if (previous !== undefined && now - start > 2000) pacing.intervals.push(now - previous);
  previous = now;
  fixture.scrollTo(0, ((now - start) * 0.7) % 18000);
  if (now - start < 18000) requestAnimationFrame(tick); else pacing.done = true;
}
requestAnimationFrame(tick); true;
''', 'returnByValue': True})
time.sleep(20)
result = call(ws, 'Runtime.evaluate', {'expression': 'JSON.stringify(pacing)', 'returnByValue': True})
pacing = json.loads(result['result']['value'])
assert pacing.get('done'), pacing
intervals = sorted(pacing.pop('intervals'))
assert len(intervals) > 30
pacing.update(samples=len(intervals), meanMs=sum(intervals)/len(intervals),
              p50Ms=intervals[len(intervals)//2], p95Ms=intervals[int(len(intervals)*.95)],
              p99Ms=intervals[int(len(intervals)*.99)], over25Ms=sum(x>25 for x in intervals),
              over50Ms=sum(x>50 for x in intervals))
print('BROMURE_SCROLL_PACING ' + json.dumps(pacing), flush=True)
