#!/usr/bin/env python3
"""Verify actual Chromium GPU selection and antialiased WebGL2 execution."""
import json
import runpy
import urllib.request

agent = runpy.run_path('/usr/local/bin/tab-agent.py')
call = agent['cdp_ws_call']
def get(path):
    with urllib.request.urlopen('http://127.0.0.1:9222/' + path, timeout=5) as response:
        return json.load(response)
try:
    info = call(get('json/version')['webSocketDebuggerUrl'], 'SystemInfo.getInfo')
    gpu = info['gpu']
    renderer = gpu['auxAttributes']['glRenderer']
    assert 'virgl' in renderer.lower(), renderer
    assert gpu['featureStatus']['gpu_compositing'] == 'enabled', gpu['featureStatus']
    page = next(p for p in get('json/list') if p['type'] == 'page')
    result = call(page['webSocketDebuggerUrl'], 'Runtime.evaluate', {
        'expression': """(() => {
            const canvas = document.createElement('canvas'); canvas.width = canvas.height = 256;
            const gl = canvas.getContext('webgl2', {antialias: true, preserveDrawingBuffer: true});
            if (!gl) throw Error('WebGL2 unavailable');
            const samples = gl.getParameter(gl.SAMPLES);
            gl.clearColor(1, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); gl.finish();
            const pixel = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
            const error = gl.getError();
            return {webgl2: true, antialias: gl.getContextAttributes().antialias,
                    samples, pixel: Array.from(pixel), error};
        })()""", 'returnByValue': True}, timeout=10)
    assert result and 'exceptionDetails' not in result, result
    webgl = result['result']['value']
    assert webgl['pixel'] == [255, 0, 0, 255] and webgl['error'] == 0, webgl
    assert webgl['antialias'] and webgl['samples'] >= 4, webgl
    print(json.dumps({'chromiumRenderer': renderer, 'features': gpu['featureStatus'],
                      'webgl': webgl, 'videoDecodingProfiles': gpu['videoDecoding']}), flush=True)
    print('BROMURE_GPU_ACCEPTANCE_PASS', flush=True)
except Exception as error:
    print('BROMURE_GPU_ACCEPTANCE_FAIL:', repr(error), flush=True)
    raise
