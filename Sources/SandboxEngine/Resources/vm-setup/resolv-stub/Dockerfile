# Builds libresolv_stub.so — the glibc-compat shim that lets the Debian
# (glibc) warp-cli binary relocate on musl Alpine. It supplies the resolver
# entry points gcompat lacks (__res_init et al.) and forwards glibc's
# fcntl64 to musl's fcntl. Unlike the out-of-tree kernel modules this is
# kernel-INDEPENDENT — pure userspace linked against musl — so a single
# arm64 build serves every guest kernel and never needs a per-KVER rebuild.
#
# The build context must be the vm-setup dir so configs/resolv-stub.c
# (the single source of truth, also compiled inline by setup.sh) is
# reachable:
#   docker build --no-cache --platform linux/arm64 \
#       -f resolv-stub/Dockerfile -t resolv-stub-builder .
#   docker create --name rstub resolv-stub-builder
#   docker cp rstub:/out/libresolv_stub.so resolv-stub/
#   docker rm rstub
FROM arm64v8/alpine:3.22

RUN apk add --no-cache gcc musl-dev binutils

COPY configs/resolv-stub.c /tmp/resolv-stub.c

# fcntl stays undefined in the .so and binds to the host process's musl
# libc at load time — exactly what warp-cli needs. Gate on the exported
# symbols: a shim missing __res_init or fcntl64 is worthless, so fail the
# build rather than ship a dud .so (mirrors setup.sh's kernel-module gate).
RUN mkdir -p /out && \
    gcc -shared -fPIC -O2 -o /out/libresolv_stub.so /tmp/resolv-stub.c && \
    for sym in __res_init fcntl64; do \
        nm -D --defined-only /out/libresolv_stub.so | grep -qw "$sym" \
            || { echo "resolv-stub: expected symbol '$sym' not exported"; exit 1; }; \
    done && \
    nm -D --defined-only /out/libresolv_stub.so
