#!/usr/bin/env python3
"""Compile actual production buffer lifetime routines with platform API stubs."""
from pathlib import Path
import re, subprocess, tempfile
source = (Path(__file__).resolve().parent / 'virgl-video-videotoolbox.m').read_text()
def routine(name):
    start = re.search(r'^[^\n]*\b' + name + r'\([^\n]*\) \{', source, re.M).start()
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#define VIDEO_MAX_DIMENSION 4096
#define PIPE_FORMAT_NV12 166
#define PIPE_FORMAT_IYUV 167
#define PIPE_FORMAT_YV12 168
#define PIPE_FORMAT_B8G8R8A8_UNORM 1
#define PIPE_FORMAT_R8G8B8A8_UNORM 2
#define virgl_error(...) ((void)0)
#define os_log_error(...) ((void)0)
#define OS_LOG_DEFAULT 0
#define CVPixelBufferRelease(p) ((void)(p))
static unsigned buffer_count;
static uint64_t video_buffer_bytes;
static uint64_t physical_memory = UINT64_C(64) << 30;
static bool initialized = true, fail_allocation;
static uint32_t next_buffer_id;
struct virgl_video_create_buffer_args { unsigned format,width,height,interlaced; };
struct virgl_video_buffer { struct virgl_video_create_buffer_args args; void *image; uint32_t id; uint64_t reserved_bytes; };
static void *allocation(size_t n,size_t s) { return fail_allocation ? NULL : calloc(n,s); }
#define calloc allocation
'''
for name in ['video_buffer_reservation','video_buffer_budget','virgl_video_create_buffer','virgl_video_destroy_buffer']:
    code += '\n' + routine(name).replace('[[NSProcessInfo processInfo] physicalMemory]', 'physical_memory')
code += r'''
int main(void) {
    assert(video_buffer_reservation(1280,720) == 1843200);
    assert(video_buffer_reservation(1920,1080) == 4456448);
    assert(video_buffer_reservation(3840,2160) == 16588800);
    assert(video_buffer_budget() == (UINT64_C(512)<<20));
    physical_memory = UINT64_C(4)<<30;
    assert(video_buffer_budget() == (UINT64_C(128)<<20));
    physical_memory = UINT64_C(64)<<30;
    struct virgl_video_create_buffer_args a={166,1280,720,0};
    struct virgl_video_buffer *buffers[512];
    unsigned n=0;
    while ((buffers[n]=virgl_video_create_buffer(&a))) { ++n; assert(n<512); }
    assert(n==291 && buffer_count==n);
    assert(video_buffer_bytes==(uint64_t)n*1843200);
    uint64_t charged=video_buffer_bytes;
    assert(!virgl_video_create_buffer(&a) && charged==video_buffer_bytes);
    while(n) virgl_video_destroy_buffer(buffers[--n]);
    assert(!buffer_count && !video_buffer_bytes);
    fail_allocation=true;
    assert(!virgl_video_create_buffer(&a) && !buffer_count && !video_buffer_bytes);
    fail_allocation=false;
    a.width=4097; assert(!virgl_video_create_buffer(&a));
    a.width=0; assert(!virgl_video_create_buffer(&a));
    a.width=1281; assert(!virgl_video_create_buffer(&a));
    a.width=1280; a.format=999; assert(!virgl_video_create_buffer(&a));
    a.format=166; a.width=3840; a.height=2160;
    n=0;
    while((buffers[n]=virgl_video_create_buffer(&a))) { ++n; assert(n<512); }
    assert(n==32);
    while(n) virgl_video_destroy_buffer(buffers[--n]);
    assert(!buffer_count && !video_buffer_bytes);
    a.width=64; a.height=64;
    for(n=0;n<512;++n) { buffers[n]=virgl_video_create_buffer(&a); assert(buffers[n]); }
    assert(!virgl_video_create_buffer(&a));
    while(n) virgl_video_destroy_buffer(buffers[--n]);
    assert(!buffer_count && !video_buffer_bytes);
    puts("VIDEO_BUFFER_BUDGET_PASS actual create/destroy: pressure, reuse, OOM, invalid dimensions, hard count");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    c=Path(tmp)/'test.c'; c.write_text(code)
    exe=Path(tmp)/'test'
    subprocess.run(['cc','-std=c11','-Wall','-Werror',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True,timeout=10)
