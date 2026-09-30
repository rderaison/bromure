#!/usr/bin/env python3
"""Headless guest rendering proof; rejects a Mesa software fallback."""
import ctypes as c
import json
import os


def function(library, name, result, *arguments):
    fn = getattr(library, name)
    fn.restype, fn.argtypes = result, list(arguments)
    return fn


egl, gbm, gl = (c.CDLL(name) for name in ("libEGL.so.1", "libgbm.so.1", "libGL.so.1"))
pointer, integer, unsigned = c.c_void_p, c.c_int, c.c_uint
fd = os.open("/dev/dri/renderD128", os.O_RDWR | os.O_CLOEXEC)
device = function(gbm, "gbm_create_device", pointer, integer)(fd)
assert device, "GBM device unavailable"
display = function(egl, "eglGetDisplay", pointer, pointer)(device)
major, minor = integer(), integer()
assert function(egl, "eglInitialize", unsigned, pointer, c.POINTER(integer), c.POINTER(integer))(
    display, c.byref(major), c.byref(minor)), "EGL initialization failed"
assert function(egl, "eglBindAPI", unsigned, unsigned)(0x30A0), "Cannot bind GLES"
attrs = (integer * 3)(0x3098, 3, 0x3038)
context = function(egl, "eglCreateContext", pointer, pointer, pointer, pointer, c.POINTER(integer))(
    display, None, None, attrs)
assert context, "No-config GLES 3 context unavailable"
assert function(egl, "eglMakeCurrent", unsigned, pointer, pointer, pointer, pointer)(
    display, None, None, context), "Cannot make context current"
renderer = function(gl, "glGetString", c.c_char_p, unsigned)(0x1F01).decode()
print(json.dumps({"renderer": renderer, "egl": [major.value, minor.value]}), flush=True)
assert "virgl" in renderer.lower(), "Guest selected a software renderer"
texture, framebuffer = unsigned(), unsigned()
function(gl, "glGenTextures", None, integer, c.POINTER(unsigned))(1, c.byref(texture))
function(gl, "glBindTexture", None, unsigned, unsigned)(0x0DE1, texture)
function(gl, "glTexImage2D", None, unsigned, integer, integer, integer, integer, integer,
         unsigned, unsigned, pointer)(0x0DE1, 0, 0x8058, 64, 64, 0, 0x1908, 0x1401, None)
function(gl, "glGenFramebuffers", None, integer, c.POINTER(unsigned))(1, c.byref(framebuffer))
function(gl, "glBindFramebuffer", None, unsigned, unsigned)(0x8D40, framebuffer)
function(gl, "glFramebufferTexture2D", None, unsigned, unsigned, unsigned, unsigned, integer)(
    0x8D40, 0x8CE0, 0x0DE1, texture, 0)
assert function(gl, "glCheckFramebufferStatus", unsigned, unsigned)(0x8D40) == 0x8CD5
function(gl, "glClearColor", None, c.c_float, c.c_float, c.c_float, c.c_float)(1, 0, 0, 1)
function(gl, "glClear", None, unsigned)(0x4000)
pixel = (c.c_ubyte * 4)()
function(gl, "glReadPixels", None, integer, integer, integer, integer, unsigned, unsigned, pointer)(
    0, 0, 1, 1, 0x1908, 0x1401, pixel)
assert list(pixel) == [255, 0, 0, 255], list(pixel)
print(json.dumps({"guestVirglClearAndReadback": True, "pixel": list(pixel)}), flush=True)
function(egl, "eglMakeCurrent", unsigned, pointer, pointer, pointer, pointer)(display, None, None, None)
function(egl, "eglDestroyContext", unsigned, pointer, pointer)(display, context)
function(egl, "eglTerminate", unsigned, pointer)(display)
function(gbm, "gbm_device_destroy", None, pointer)(device)
os.close(fd)
