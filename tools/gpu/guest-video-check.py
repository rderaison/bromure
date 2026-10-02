#!/usr/bin/env python3
"""Strict actual Chromium hardware playback check for a trusted red H.264 MP4.

Place the trusted fixture at /tmp/bromure-movie.mp4 (or set
BROMURE_GPU_VIDEO_FIXTURE). This does not establish which host decoder runs;
combine it with the renderer's hardware-only VideoToolbox evidence.
"""
import base64
import json
import os
from pathlib import Path
import runpy
import socket
import time
import urllib.request

agent = runpy.run_path('/usr/local/bin/tab-agent.py')
call = agent['cdp_ws_call']
def get(path):
    with urllib.request.urlopen('http://127.0.0.1:9222/' + path, timeout=5) as response:
        return json.load(response)

def verify():
    gpu = call(get('json/version')['webSocketDebuggerUrl'], 'SystemInfo.getInfo')['gpu']
    assert 'virgl' in gpu['auxAttributes']['glRenderer'].lower(), gpu
    assert gpu['featureStatus']['gpu_compositing'] == 'enabled', gpu['featureStatus']
    fixture_path = Path(os.environ.get('BROMURE_GPU_VIDEO_FIXTURE', '/tmp/bromure-movie.mp4'))
    fixture = fixture_path.read_bytes()
    mime = 'video/webm' if fixture_path.suffix == '.webm' else 'video/mp4'
    expected_decoder = os.environ.get('BROMURE_GPU_EXPECT_DECODER', 'VaapiVideoDecoder')
    assert expected_decoder in ('VaapiVideoDecoder', 'FFmpegVideoDecoder', 'VpxVideoDecoder')
    platform = expected_decoder == 'VaapiVideoDecoder'
    assert 0 < len(fixture) <= 8 * 1024 * 1024
    page = next(p for p in get('json/list') if p['type'] == 'page')
    ws = page['webSocketDebuggerUrl']
    call(ws, 'Page.navigate', {'url': 'about:blank'})
    time.sleep(0.5)
    connection = agent['_ws_connect'](ws)
    properties = {}
    try:
        agent['_ws_send'](connection, json.dumps({'id': 1, 'method': 'Media.enable'}))
        encoded = base64.b64encode(fixture).decode('ascii')
        expression = """(() => {
            const v = document.createElement('video'); v.id = 'bromureHardwareMovie';
            v.muted = true; v.loop = true; v.autoplay = true; v.width = 512;
            v.src = 'data:""" + mime + """;base64,""" + encoded + """';
            document.body.append(v); v.play(); return true;
        })()"""
        call(ws, 'Runtime.evaluate', {'expression': expression, 'returnByValue': True})
        connection.settimeout(1)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                event = json.loads(agent['_ws_recv'](connection))
            except socket.timeout:
                continue
            if event.get('method') == 'Media.playerPropertiesChanged':
                for item in event['params']['properties']:
                    properties[item['name']] = item['value']
        response = call(ws, 'Runtime.evaluate', {'expression': """(() => {
            const v = document.getElementById('bromureHardwareMovie');
            const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
            const x = c.getContext('2d'); x.drawImage(v, 0, 0);
            return {frames: v.getVideoPlaybackQuality().totalVideoFrames, error: v.error,
                    width: v.videoWidth, height: v.videoHeight, readyState: v.readyState,
                    pixel: Array.from(x.getImageData(c.width / 2, c.height / 2, 1, 1).data)};
        })()""", 'returnByValue': True}, timeout=10)
        assert 'exceptionDetails' not in response, response
        playback = response['result']['value']
        assert properties.get('kVideoDecoderName') == expected_decoder, properties
        assert properties.get('kIsPlatformVideoDecoder') == ('true' if platform else 'false'), properties
        assert playback['error'] is None and playback['readyState'] >= 2 and playback['frames'] >= 30, playback
        red, green, blue, alpha = playback['pixel']
        assert red >= 240 and green <= 12 and blue <= 12 and alpha == 255, playback
        print(json.dumps({'renderer': gpu['auxAttributes']['glRenderer'],
                          'decoder': properties['kVideoDecoderName'], 'platformDecoder': platform,
                          'playback': playback}), flush=True)
        print('BROMURE_HARDWARE_MOVIE_PASS' if platform else 'BROMURE_SOFTWARE_VIDEO_FALLBACK_PASS', flush=True)
    finally:
        connection.close()

try:
    verify()
except Exception as error:
    print('BROMURE_HARDWARE_MOVIE_FAIL:', repr(error), flush=True)
    raise
