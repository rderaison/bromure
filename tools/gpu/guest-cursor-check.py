#!/usr/bin/env python3
"""Exercise real X11/Chromium virtio cursor updates without repainting scanout.

Combine the guest marker with gpu-browser --cursor-check, which requires cursor
queue activity and successful native AppKit cursor image presentation.
"""
import ctypes
import json
import os
from pathlib import Path
import runpy
import time
import urllib.request

config = Path('/etc/X11/xorg.conf.d/10-virtio.conf').read_text()
assert '"SWCursor" "true"' not in config, 'Rebuild the image with its native cursor configuration'
os.environ['DISPLAY'] = ':0'
os.environ['XAUTHORITY'] = '/home/chrome/.Xauthority'
x11 = ctypes.CDLL('libX11.so.6')
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x11.XDefaultRootWindow.restype = ctypes.c_ulong
x11.XWarpPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                           ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                           ctypes.c_int, ctypes.c_int]
x11.XFlush.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
display = x11.XOpenDisplay(None)
assert display, 'X11 display unavailable'
try:
    root = x11.XDefaultRootWindow(display)
    call = runpy.run_path('/usr/local/bin/tab-agent.py')['cdp_ws_call']
    with urllib.request.urlopen('http://127.0.0.1:9222/json/list', timeout=5) as response:
        page = next(p for p in json.load(response) if p['type'] == 'page')
    for shape in ('crosshair', 'text', 'pointer'):
        result = call(page['webSocketDebuggerUrl'], 'Runtime.evaluate', {
            'expression': "document.body.innerHTML='<div style=\"height:100vh;cursor:%s\">Native cursor test</div>'; document.body.style.cursor='%s';" % (shape, shape),
        })
        assert result and 'exceptionDetails' not in result, result
        for index in range(8):
            x11.XWarpPointer(display, 0, root, 0, 0, 0, 0, 200 + index * 8, 240 + index * 3)
            x11.XFlush(display)
            time.sleep(.1)
    print('BROMURE_CURSOR_QUEUE_EXERCISED', flush=True)
finally:
    x11.XCloseDisplay(display)
