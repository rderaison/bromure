// Content-coding decoders for the proxy's content scans (macOS:
// Compression.framework's zlib and brotli in HTTPProxy.swift), over the
// system's zlib and libbrotlidec. Output is capped: a body that inflates past
// `cap` fails, as macOS's does at 64 MiB.
#include <stdlib.h>
#include <string.h>
#if !__has_include(<zlib.h>)
#error "zlib's headers are missing: install zlib1g-dev (linux/RELEASE_NOTES.md, Host requirements)"
#endif
#if !__has_include(<brotli/decode.h>)
#error "libbrotlidec's headers are missing: install libbrotli-dev (linux/RELEASE_NOTES.md, Host requirements)"
#endif
#include <zlib.h>
#include <brotli/decode.h>
#include "CACLinuxShims.h"

/// Room for more output after `len` bytes: grows `*buf` toward `cap`.
/// -2 when `len` is already at the cap, -1 when memory runs out.
static int room(uint8_t **buf, size_t *have, size_t len, size_t cap) {
    if (len < *have) return 0;
    if (len >= cap) return -2;
    size_t n = *have ? *have * 2 : 64 * 1024;
    if (n > cap) n = cap;
    uint8_t *b = realloc(*buf, n);
    if (!b) return -1;
    *buf = b; *have = n;
    return 0;
}

int acl_inflate(const uint8_t *in, size_t n, int window_bits, size_t cap, uint8_t **out, size_t *out_len) {
    *out = NULL; *out_len = 0;
    z_stream s; memset(&s, 0, sizeof s);
    if (inflateInit2(&s, window_bits) != Z_OK) return -1;
    uint8_t *buf = NULL; size_t have = 0, len = 0;
    s.next_in = (Bytef *)in; s.avail_in = (uInt)n;
    int rc = -1;
    for (;;) {
        int g = room(&buf, &have, len, cap);
        if (g != 0) { rc = g; break; }
        s.next_out = buf + len; s.avail_out = (uInt)(have - len);
        int z = inflate(&s, Z_NO_FLUSH);
        len = have - s.avail_out;
        if (z == Z_STREAM_END) {
            // gzip members may be concatenated (RFC 1952): the next one follows.
            if (s.avail_in > 0 && (window_bits & 16)) { if (inflateReset(&s) != Z_OK) break; continue; }
            rc = 0; break;
        }
        if (z == Z_BUF_ERROR && s.avail_in == 0 && s.avail_out > 0) break;   // truncated (a full output buffer just grows)
        if (z != Z_OK && z != Z_BUF_ERROR) break;               // corrupt
    }
    inflateEnd(&s);
    if (rc != 0) { free(buf); return rc; }
    *out = buf; *out_len = len;
    return 0;
}

int acl_brotli_decode(const uint8_t *in, size_t n, size_t cap, uint8_t **out, size_t *out_len) {
    *out = NULL; *out_len = 0;
    BrotliDecoderState *st = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (!st) return -1;
    uint8_t *buf = NULL; size_t have = 0, len = 0;
    size_t avail_in = n; const uint8_t *next_in = in;
    int rc = -1;
    for (;;) {
        int g = room(&buf, &have, len, cap);
        if (g != 0) { rc = g; break; }
        size_t avail_out = have - len; uint8_t *next_out = buf + len;
        BrotliDecoderResult r = BrotliDecoderDecompressStream(st, &avail_in, &next_in, &avail_out, &next_out, NULL);
        len = have - avail_out;
        if (r == BROTLI_DECODER_RESULT_SUCCESS) { rc = 0; break; }
        if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) continue;
        break;   // error, or NEEDS_MORE_INPUT with none left (truncated)
    }
    BrotliDecoderDestroyInstance(st);
    if (rc != 0) { free(buf); return rc; }
    *out = buf; *out_len = len;
    return 0;
}
