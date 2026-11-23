#!/bin/bash
# build.sh [OUT_DIR]: passt for bromure-ac, the pinned upstream release,
# static, into OUT_DIR (default ~/.local/share/bromure-ac/bin): passt, and
# on x86_64 passt.avx2 (passt runs it in its place when the CPU has AVX2).
#
# Why not the distribution's: the daemon runs passt with
# --map-host-loopback, --map-guest-addr and --dns-host
# (PasstUplink.Config.arguments). Ubuntu 24.04's passt (2024-02-20) refuses
# them and exits: no VM, the image bake's installer included, reaches the
# network there. The pinned release is the one the port is tested with.
#
# Plain C, no libraries: `-static` against glibc (passt resolves no names).
# Cross build: BROMURE_PASST_ARCH=x86_64 (or aarch64) on another host, with
# $ARCH-linux-gnu-gcc ($BROMURE_PASST_CC to name another). Sources go to
# $BROMURE_PASST_SRC (default ~/.cache/bromure-ac/passt-src).
set -euo pipefail

TAG=2026_01_20.386b5f5
COMMIT=386b5f5472b89769c025f5d5056348532a823b93
URL=https://passt.top/passt

OUT=${1:-$HOME/.local/share/bromure-ac/bin}
SRC=${BROMURE_PASST_SRC:-$HOME/.cache/bromure-ac/passt-src}
HOST_ARCH=$(uname -m)
ARCH=${BROMURE_PASST_ARCH:-$HOST_ARCH}
case $ARCH in x86_64|aarch64) ;; *) echo "build.sh: unsupported arch $ARCH" >&2; exit 1;; esac
if [ "$ARCH" = "$HOST_ARCH" ]; then CC=${BROMURE_PASST_CC:-gcc}; else CC=${BROMURE_PASST_CC:-$ARCH-linux-gnu-gcc}; fi
die() { echo "build.sh: $*" >&2; exit 1; }

command -v "$CC" >/dev/null || die "$CC not found"
[ "$($CC -dumpmachine | cut -d- -f1)" = "$ARCH" ] || die "$CC builds for $($CC -dumpmachine), not $ARCH"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$(dirname "$SRC")"
    git -c advice.detachedHead=false clone -q --branch "$TAG" --depth 1 "$URL" "$SRC"
fi
cd "$SRC"
git fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
[ "$(git rev-parse "$TAG^{commit}")" = "$COMMIT" ] || die "$TAG is not $COMMIT upstream any more"
git -c advice.detachedHead=false checkout -q --detach "$COMMIT"
git reset -q --hard
git clean -qfdx

# upstream's `make static` flags, for passt alone. PAGE_SIZE is the
# target's (4 KiB, Ubuntu's kernels), not the builder's getconf.
BINS=(passt)
[ "$ARCH" = x86_64 ] && BINS+=(passt.avx2)
make -s CC="$CC" VERSION="$TAG" CFLAGS="-static -DGLIBC_NO_STATIC_NSS -UPAGE_SIZE -DPAGE_SIZE=4096" "${BINS[@]}" 2>&1 \
    | grep -v '"PAGE_SIZE" redefined\|^<command-line>\|^  *|\|^ *[0-9]* | \|^$' || true
mkdir -p "$OUT"
for b in "${BINS[@]}"; do
    [ -x "$b" ] || die "$b wasn't built"
    file "$b" | grep -Eq 'static(-pie)? linked|statically linked' || die "$b isn't static: $(file "$b")"
    install -m 755 "$b" "$OUT/$b.new"
done
for b in "${BINS[@]}"; do mv -f "$OUT/$b.new" "$OUT/$b"; done
if [ "$ARCH" = "$HOST_ARCH" ]; then v=$("$OUT/passt" --version | head -1); else v="$TAG for $ARCH (cross-built)"; fi
echo "$OUT/passt: $v (${BINS[*]})"
