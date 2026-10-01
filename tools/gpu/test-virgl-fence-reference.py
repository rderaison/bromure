#!/usr/bin/env python3
"""Run pinned Mesa's public flush callback against real FD ownership fixtures.

Pass mesa-25.2.8.tar.xz. Upstream must leak; patched callback must balance
references through repeated surface flushes, shared ownership and failures.
This is an API lifetime regression, not hardware/browser acceptance.
"""
import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

PIN = '097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93'
MEMBER = 'src/gallium/drivers/virgl/virgl_context.c'
PATCH = Path(__file__).resolve().parents[2] / 'Sources/SandboxEngine/Resources/vm-setup/gpu/mesa-virgl-fence-reference.patch'
PRELUDE = r'''
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
struct pipe_fence_handle { unsigned refs; int fd; };
struct virgl_winsys {
    void (*fence_reference)(struct virgl_winsys *, struct pipe_fence_handle **,
                            struct pipe_fence_handle *);
};
struct virgl_screen { struct virgl_winsys *vws; };
struct pipe_context { struct virgl_screen *screen; };
struct virgl_context { struct pipe_context base; };
enum pipe_flush_flags { FLUSH_DEFAULT = 0 };
#define virgl_context(p) ((struct virgl_context *)(p))
#define virgl_screen(p) (p)
static unsigned live, created, closed, submissions, fail_next;
static struct pipe_fence_handle *make_fence(void) {
    struct pipe_fence_handle *f = calloc(1, sizeof(*f)); assert(f);
    f->refs = 1; f->fd = open("/dev/null", O_RDONLY); assert(f->fd >= 0);
    ++live; ++created; return f;
}
static void reference(struct virgl_winsys *ws, struct pipe_fence_handle **dst,
                      struct pipe_fence_handle *src) {
    (void)ws;
    if (src) ++src->refs;
    if (*dst && !--(*dst)->refs) {
        assert(fcntl((*dst)->fd, F_GETFD) != -1);
        assert(close((*dst)->fd) == 0); free(*dst); --live; ++closed;
    }
    *dst = src;
}
static void virgl_flush_eq(struct virgl_context *ctx, void *closure,
                           struct pipe_fence_handle **out) {
    assert(ctx == closure); ++submissions;
    // Winsys submit writes a fresh owned fence on success; leaves output
    // untouched on failure. This is the real DRM winsys contract.
    if (out && !fail_next) *out = make_fence();
    fail_next = 0;
}
'''
EPILOGUE = r'''
int main(void) {
    struct virgl_winsys ws = {reference};
    struct virgl_screen screen = {&ws}; struct virgl_context ctx = {{&screen}};
    struct pipe_fence_handle *surface = NULL;
    for (unsigned i = 0; i < 10000; ++i) {
        virgl_flush_from_st(&ctx.base, &surface, FLUSH_DEFAULT);
        if (live != 1) {
            fprintf(stderr, "fence leak: live=%u after %u flushes\n", live, i+1);
            return 2;
        }
        assert(surface->refs == 1 && fcntl(surface->fd, F_GETFD) != -1);
    }
    // Replacing one reference must not destroy another context's ownership.
    struct pipe_fence_handle *other = NULL;
    reference(&ws, &other, surface); int old_fd = other->fd;
    virgl_flush_from_st(&ctx.base, &surface, FLUSH_DEFAULT);
    assert(live == 2 && other->refs == 1 && fcntl(old_fd, F_GETFD) != -1);
    reference(&ws, &other, NULL); assert(live == 1);
    // A submit that produces no fence must not leak the caller's old one.
    fail_next = 1;
    virgl_flush_from_st(&ctx.base, &surface, FLUSH_DEFAULT);
    assert(!surface && live == 0);
    unsigned before = created;
    virgl_flush_from_st(&ctx.base, NULL, FLUSH_DEFAULT);
    assert(created == before && live == 0);
    virgl_flush_from_st(&ctx.base, &surface, FLUSH_DEFAULT);
    reference(&ws, &surface, NULL);
    assert(created == closed && submissions == 10004);
    puts("BROMURE_VIRGL_FENCE_REFERENCE_PASS");
}
'''


def routine(source):
    start = source.index('static void virgl_flush_from_st(')
    return source[start:source.index('\nstatic struct pipe_sampler_view', start)]


def main():
    archive = Path(sys.argv[1])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PIN:
        raise SystemExit('Mesa archive does not match production pin')
    with tarfile.open(archive) as tar:
        original = tar.extractfile('mesa-25.2.8/' + MEMBER).read().decode()
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        src = root / MEMBER
        src.parent.mkdir(parents=True)
        src.write_text(original)
        subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-d', temp],
                       input=PATCH.read_text(), text=True, check=True, timeout=10)
        for label, text in [('upstream', original), ('patched', src.read_text())]:
            test = root / (label + '.c')
            test.write_text(PRELUDE + routine(text) + EPILOGUE)
            binary = root / label
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-Wno-unused-parameter', str(test), '-o', str(binary)],
                           check=True, timeout=30)
            result = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=10)
            if label == 'upstream':
                assert result.returncode == 2 and 'fence leak:' in result.stderr, result
                print('Unpatched Mesa reproduces:', result.stderr.strip())
            else:
                assert result.returncode == 0, result.stderr
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
