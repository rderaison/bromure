#!/usr/bin/env python3
"""Compare Mesa X11 EGL and Chromium's bundled ANGLE without browser settings."""
import ctypes as c
import glob
import json
import os
import subprocess
import sys

if len(sys.argv) == 1:
    for backend in ('mesa', 'angle'):
        subprocess.run([sys.executable, __file__, backend], check=False)
    sys.exit()
backend = sys.argv[1]
os.environ['DISPLAY'] = ':0'
os.environ['XAUTHORITY'] = '/home/chrome/.Xauthority'
os.environ.pop('LIBGL_ALWAYS_SOFTWARE', None)
def fn(lib, name, result, *args):
    try: f = getattr(lib, name)
    except AttributeError:
        prefix = 'EGL_' if name.startswith('egl') else 'GL_'
        try: f = getattr(lib, prefix + name[3 if name.startswith('egl') else 2:])
        except AttributeError:
            proc = EGL_PROC
            address = proc(name.encode()); assert address, name
            f = c.CFUNCTYPE(result, *args)(address)
    f.restype = result; f.argtypes = list(args); return f
p, i, u = c.c_void_p, c.c_int, c.c_uint
if backend == 'angle':
    candidates = glob.glob('/usr/lib/chromium/**/libEGL.so', recursive=True)
    print('ANGLE libraries:', candidates, flush=True)
    if not candidates: sys.exit(1)
    egl = c.CDLL(candidates[0]); gl = c.CDLL(os.path.join(os.path.dirname(candidates[0]), 'libGLESv2.so'))
    EGL_PROC = None
    for library in (egl, gl):
        for symbol in ('eglGetProcAddress', 'EGL_GetProcAddress', 'ANGLEGetProcAddress', 'GetProcAddress'):
            try:
                proc = getattr(library, symbol); proc.restype = p; proc.argtypes = [c.c_char_p]
                if proc(b'eglGetDisplay'):
                    EGL_PROC = proc
            except AttributeError: pass
    if EGL_PROC is None:
        print(json.dumps({'backend': 'angle', 'standaloneLibrary': False,
                          'note': 'Bundled shared libraries are stubs; use browser CDP acceptance.'}), flush=True)
        sys.exit()
    address = EGL_PROC(b'eglGetPlatformDisplayEXT')
    get_display = c.CFUNCTYPE(p, u, p, c.POINTER(i))(address)
    display = get_display(0x3202, None, (i * 3)(0x3203, 0x320e, 0x3038))
else:
    egl = c.CDLL('libEGL.so.1'); gl = c.CDLL('libGLESv2.so.2')
    display = fn(egl, 'eglGetDisplay', p, p)(None)
major, minor = i(), i()
initialized = fn(egl, 'eglInitialize', u, p, c.POINTER(i), c.POINTER(i))(display, c.byref(major), c.byref(minor))
error = fn(egl, 'eglGetError', u)
print(json.dumps({'backend': backend, 'initialized': bool(initialized), 'error': hex(error())}), flush=True)
if not initialized: sys.exit(1)
query = fn(egl, 'eglQueryString', c.c_char_p, p, i)
print('EGL extensions:', query(display, 0x3055), flush=True)
configs = (p * 256)(); count = i()
fn(egl, 'eglGetConfigs', u, p, c.POINTER(p), i, c.POINTER(i))(display, configs, 256, c.byref(count))
types = set()
for cfg in configs[:min(count.value, 256)]:
    value = i(); fn(egl, 'eglGetConfigAttrib', u, p, p, i, c.POINTER(i))(display, cfg, 0x3040, c.byref(value)); types.add(value.value)
print('EGL config renderable types:', sorted(types), flush=True)
fn(egl, 'eglBindAPI', u, u)(0x30a0)
for version in (2, 3):
    context = fn(egl, 'eglCreateContext', p, p, p, p, c.POINTER(i))(display, None, None, (i * 3)(0x3098, version, 0x3038))
    print('Requested ES', version, 'context', bool(context), 'error', hex(error()), flush=True)
    if context and fn(egl, 'eglMakeCurrent', u, p, p, p, p)(display, None, None, context):
        get_string = fn(gl, 'glGetString', c.c_char_p, u)
        print(json.dumps({'backend': backend, 'requested': version, 'renderer': str(get_string(0x1f01)), 'version': str(get_string(0x1f02)), 'extensions': str(get_string(0x1f03))}), flush=True)
        fn(egl, 'eglMakeCurrent', u, p, p, p, p)(display, None, None, None)
        fn(egl, 'eglDestroyContext', u, p, p)(display, context)
fn(egl, 'eglTerminate', u, p)(display)
