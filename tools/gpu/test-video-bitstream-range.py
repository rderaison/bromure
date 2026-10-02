#!/usr/bin/env python3
"""Execute Mesa's patched decode upload routine against instrumented pipe APIs.

Usage: python3 tools/gpu/test-video-bitstream-range.py /path/to/mesa-25.2.8.tar.xz
The archive must match the production pin. No download or GPU is performed.
This tests mapped transfer ranges, copied bytes and retained synchronization;
actual hardware decoding and throughput require the rebuilt guest on macOS.
"""
import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

PIN = '097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93'
MEMBER = 'src/gallium/drivers/virgl/virgl_video.c'
PATCH = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/gpu/mesa-virgl-video-export.patch'

# The routine below is extracted from the real, pinned Mesa source, not copied
# into this harness. Pipe mocks deliberately expose the allocated versus mapped
# sizes; upstream's full allocation upload must fail the very same test.
PRELUDE = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define PIPE_BIND_CUSTOM 1
#define PIPE_USAGE_STAGING 2
#define PIPE_MAP_WRITE 4
struct pipe_resource { unsigned size; unsigned char *data; };
struct virgl_resource { struct pipe_resource base; void *hw_res; };
struct pipe_transfer { struct pipe_resource *res; unsigned size; };
struct winsys { void (*resource_wait)(struct winsys *, void *); };
struct virgl_screen { struct winsys *vws; };
struct pipe_context { struct virgl_screen *screen; void (*flush)(struct pipe_context *, void *, unsigned); };
struct virgl_context { struct pipe_context base; };
struct pipe_video_codec { unsigned unused; };
struct pipe_video_buffer { unsigned unused; };
struct virgl_video_buffer { struct pipe_video_buffer base; };
struct pipe_picture_desc { unsigned value; };
union virgl_picture_desc { unsigned value; unsigned char padding[128]; };
struct virgl_video_codec {
    struct pipe_video_codec base;
    struct virgl_context *vctx;
    struct pipe_resource *bs_buffers[10], *desc_buffers[10];
    unsigned cur_buffer, bs_size;
};
#define virgl_video_codec(p) ((struct virgl_video_codec *)(p))
#define virgl_video_buffer(p) ((struct virgl_video_buffer *)(p))
#define virgl_resource(p) ((struct virgl_resource *)(p))
#define virgl_screen(p) (p)
static unsigned expected, mapped, encoded, waits, flushes, fail_map, fail_allocation;
static struct pipe_transfer transfer;
static struct pipe_resource *active;
static void flush(struct pipe_context *ctx, void *fence, unsigned flags) {
    (void)ctx; assert(!fence && !flags); ++flushes;
}
static void wait_resource(struct winsys *ws, void *res) {
    (void)ws; assert(res && flushes == 1); ++waits;
}
static unsigned pipe_buffer_size(struct pipe_resource *p) { return p->size; }
static struct pipe_resource *pipe_buffer_create(struct virgl_screen *s, unsigned bind, unsigned usage, unsigned size) {
    (void)s; assert(bind == PIPE_BIND_CUSTOM && usage == PIPE_USAGE_STAGING);
    if (fail_allocation) return NULL;
    struct virgl_resource *r = calloc(1, sizeof(*r)); assert(r);
    r->base.size = size; r->base.data = malloc((size_t)size + 16); assert(r->base.data);
    memset(r->base.data, 0xa5, (size_t)size + 16); r->hw_res = r;
    return &r->base;
}
static void pipe_resource_reference(struct pipe_resource **p, struct pipe_resource *other) {
    assert(!other); if (*p) { free((*p)->data); free(*p); } *p = NULL;
}
static void *pipe_buffer_map_range(struct pipe_context *ctx, struct pipe_resource *r,
                                  unsigned offset, unsigned size, unsigned usage, struct pipe_transfer **out) {
    (void)ctx; assert(!offset && usage == PIPE_MAP_WRITE && size && size <= r->size);
    if (r == active || waits == 1) { active = r; mapped = size; }
    if (fail_map && waits == fail_map) return NULL;
    transfer = (struct pipe_transfer){r, size}; *out = &transfer; return r->data;
}
static void *pipe_buffer_map(struct pipe_context *ctx, struct pipe_resource *r,
                            unsigned usage, struct pipe_transfer **out) {
    return pipe_buffer_map_range(ctx, r, 0, r->size, usage, out);
}
static void pipe_buffer_unmap(struct pipe_context *ctx, struct pipe_transfer *t) {
    (void)ctx; assert(t == &transfer);
}
static void fill_picture_desc(struct pipe_picture_desc *p, union virgl_picture_desc *d) {
    memset(d, 0, sizeof(*d)); d->value = p->value;
}
static void virgl_encode_decode_bitstream(struct virgl_context *ctx, struct virgl_video_codec *c,
                                        struct virgl_video_buffer *b, void *desc, unsigned size) {
    (void)ctx; (void)b; assert(waits == 2 && size == sizeof(union virgl_picture_desc));
    assert(c->bs_size == expected && ((union virgl_picture_desc *)desc)->value == 123);
    ++encoded;
}
'''

EPILOGUE = r'''
static void run_case(unsigned allocation, unsigned a, unsigned b, unsigned failure) {
    struct winsys ws = {wait_resource}; struct virgl_screen screen = {&ws};
    struct virgl_context ctx = {{&screen, flush}};
    struct virgl_video_codec c = {.vctx = &ctx, .cur_buffer = 9};
    struct virgl_video_buffer target = {0}; struct pipe_picture_desc picture = {123};
    c.bs_buffers[9] = pipe_buffer_create(&screen, 1, 2, allocation);
    c.desc_buffers[9] = pipe_buffer_create(&screen, 1, 2, sizeof(union virgl_picture_desc));
    unsigned char *first = malloc(a), *second = malloc(b); assert(first && second);
    memset(first, 0x37, a); memset(second, 0x82, b);
    const void *parts[] = {first, second}; unsigned sizes[] = {a, b};
    // Reuse a slot with a much smaller next picture: stale allocation/tail must
    // not become the transfer size, and the caller still owns ring advancement.
    for (unsigned pass = 0; pass < 2; ++pass) {
        if (pass) { sizes[0] = 3; sizes[1] = 2; }
        expected = sizes[0] + sizes[1]; mapped = encoded = waits = flushes = 0;
        fail_map = failure; active = NULL;
        virgl_video_decode_bitstream(&c.base, &target.base, &picture, 2, parts, sizes);
        if (mapped != expected) {
            fprintf(stderr, "overtransfer: mapped=%u actual=%u\n", mapped, expected); exit(2);
        }
        assert(flushes == 1 && c.cur_buffer == 9);
        assert(encoded == (failure ? 0u : 1u));
        assert(waits == (failure == 1 ? 1u : 2u));
        if (failure != 1) {
            assert(!memcmp(active->data, first, sizes[0]));
            assert(!memcmp(active->data + sizes[0], second, sizes[1]));
        }
        for (unsigned i = 0; i < 16; ++i) assert(active->data[active->size + i] == 0xa5);
    }
    free(first); free(second);
    pipe_resource_reference(&c.bs_buffers[9], NULL); pipe_resource_reference(&c.desc_buffers[9], NULL);
}
int main(void) {
    run_case(4177920, 1000, 733, 0);     // 1080p allocation, small multi-slice picture.
    run_case(16588800, 65537, 70001, 0); // 4K allocation, spans transport chunks.
    run_case(64, 1000, 733, 0);          // Larger picture reallocates as before.
    run_case(4177920, 1000, 733, 1);     // Mapping failure must not submit decode.
    run_case(4177920, 1000, 733, 2);     // Descriptor-map failure, same guarantee.
    struct winsys ws = {wait_resource}; struct virgl_screen screen = {&ws};
    struct virgl_context ctx = {{&screen, flush}};
    struct virgl_video_codec c = {.vctx = &ctx};
    struct virgl_video_buffer target = {0}; struct pipe_picture_desc picture = {123};
    const void *parts[] = {"x", "y"};
    unsigned empty[] = {0, 0}, overflow[] = {UINT_MAX, 2}, valid[] = {1, 1};
    mapped = encoded = waits = flushes = fail_map = 0;
    virgl_video_decode_bitstream(&c.base, &target.base, &picture, 2, parts, empty);
    virgl_video_decode_bitstream(&c.base, &target.base, &picture, 2, parts, overflow);
    assert(!(mapped || encoded || waits || flushes));
    fail_allocation = 1;
    virgl_video_decode_bitstream(&c.base, &target.base, &picture, 2, parts, valid);
    assert(!c.bs_buffers[0] && !(mapped || encoded || waits || flushes));
    fail_allocation = 0;
    c.desc_buffers[0] = pipe_buffer_create(&screen, 1, 2, sizeof(union virgl_picture_desc));
    expected = 2; active = NULL;
    virgl_video_decode_bitstream(&c.base, &target.base, &picture, 2, parts, valid);
    assert(encoded == 1 && mapped == 2); // Retry after failed allocation.
    pipe_resource_reference(&c.bs_buffers[0], NULL); pipe_resource_reference(&c.desc_buffers[0], NULL);
    puts("BROMURE_VIDEO_BITSTREAM_RANGE_PASS");
}
'''


def routine(source):
    start = source.index('static void virgl_video_decode_bitstream(')
    end = source.index('\nstatic void virgl_video_encode_bitstream(', start)
    return source[start:end]


def main():
    archive = Path(sys.argv[1])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PIN:
        raise SystemExit('Mesa archive does not match the production pin')
    with tarfile.open(archive) as tar:
        original = tar.extractfile('mesa-25.2.8/' + MEMBER).read().decode()
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        src = root / MEMBER
        src.parent.mkdir(parents=True)
        src.write_text(original)
        subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-d', temp],
                       input=PATCH.read_text(), text=True, check=True, timeout=10)
        for label, source in [('upstream', original), ('patched', src.read_text())]:
            test = root / (label + '.c')
            test.write_text(PRELUDE + routine(source) + EPILOGUE)
            binary = root / label
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(test), '-o', str(binary)], check=True, timeout=30)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            if label == 'upstream':
                assert result.returncode == 2 and 'overtransfer:' in result.stderr, result
                print('Unpatched Mesa reproduces excess upload:', result.stderr.strip())
            else:
                assert result.returncode == 0, result.stderr
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
