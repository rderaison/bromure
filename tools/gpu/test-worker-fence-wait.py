#!/usr/bin/env python3
"""Exercise actual fence-wait routine with controlled clock and retirement.
Does not establish live Metal fence latency or CPU cost.
"""
from pathlib import Path
import tempfile,subprocess
s=Path(__file__).resolve().with_name('renderer-worker.c').read_text()
routine=s[s.index('static int wait_for_gpu('):s.index('static uint32_t load32(')]
source=r'''#include <stdint.h>
#include <assert.h>
#include <time.h>
#include <stdio.h>
static int64_t tick, complete;
static unsigned sleeps, polls;
static int create_error;
static uint32_t retired_fence, expected;
static int virgl_renderer_create_fence(int token,uint32_t context){(void)context;expected=token;return create_error;}
static void virgl_renderer_poll(void){++polls;if(complete>=0 && tick>=complete)retired_fence=expected;}
static int fake_clock(clockid_t id,struct timespec *value){(void)id;value->tv_sec=100+tick/1000000000;value->tv_nsec=tick%1000000000;return 0;}
static int fake_sleep(const struct timespec *value,struct timespec *unused){(void)unused;assert(value->tv_nsec==50000 || value->tv_nsec==250000 || value->tv_nsec==1000000);tick+=value->tv_nsec;++sleeps;return 0;}
#define clock_gettime fake_clock
#define nanosleep fake_sleep
'''+routine+r'''
static void reset(int64_t at){tick=0;complete=at;sleeps=polls=create_error=0;retired_fence=0;}
int main(void){
reset(0);assert(wait_for_gpu(1,0)==1 && sleeps==0);
reset(100000);assert(wait_for_gpu(2,0)==1 && tick==100000 && sleeps==2);
reset(2000000);assert(wait_for_gpu(3,0)==1 && tick==2000000 && sleeps<40);
reset(10000000);assert(wait_for_gpu(4,0)==1 && tick==10000000 && sleeps<60);
reset(-1);assert(wait_for_gpu(5,0)==0 && tick==5000000000LL && polls<5100 && retired_fence==0);
reset(0);create_error=1;assert(wait_for_gpu(6,0)==0 && polls==0 && sleeps==0);
printf("FENCE_WAIT_ACTUAL_ROUTINE_PASS\n");return 0;}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.c').write_text(source)
 subprocess.run(['clang','-Wall','-Wextra','-Werror',str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
