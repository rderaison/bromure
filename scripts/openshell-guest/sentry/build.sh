#!/usr/bin/env bash
# Build the shipped sentry module for one kernel, reproducibly.
#
# Run this at Bromure release time, inside a guest VM of the image being
# released (or any Ubuntu arm64 box with that kernel's headers installed). The
# output goes straight into the meta share layout:
#
#     sentry-dist/bromure_sentry-<kernel-release>.ko
#
# `bromure-sentryd` looks for exactly that name, so the kernel a module was
# built for is part of its identity and a mismatched module is never loaded by
# accident.
#
#   ./build.sh                          build for the running kernel
#   ./build.sh 6.8.0-142-generic        build for a specific one
#   ./build.sh 6.8.0-142-generic --verify   build twice and compare
#   OUT=/path/to/meta/sentry ./build.sh
#
# The kernel does NOT have to be the running one — only its headers have to be
# installed. That is what lets the release pipeline build a module for a new base
# image before that image is ever booted:
#
#   sudo apt-get install -y linux-headers-<kver>
#   ./build.sh <kver>
#
# `sentry-dist/` is a SET of `<kver>.ko` files and the host stages all of them;
# `bromure-sentryd` picks the one matching `$(uname -r)` at boot. So adding a new
# image kernel is additive and never invalidates the old one.
#
# Reproducibility: the build is pinned to the kernel release and to Ubuntu's own
# compiler for that kernel, `SOURCE_DATE_EPOCH` is pinned to the source's mtime,
# and `KBUILD_BUILD_*` are pinned so the module does not embed the builder's
# hostname or the wall clock. Two runs from the same source and the same headers
# produce byte-identical output; the script verifies that itself with --verify.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="${1:-$(uname -r)}"
# NOT under $HERE. `make clean` with kbuild's M=<dir> deletes *.ko recursively
# beneath the module directory, so a dist/ inside it is destroyed by the next
# clean -- measured, after it ate the release artifact once.
OUT="${OUT:-$HERE/../sentry-dist}"
VERIFY=0
[ "${2:-}" = "--verify" ] && VERIFY=1

KDIR="/lib/modules/$KVER/build"
if [ ! -d "$KDIR" ]; then
    echo "kernel headers for $KVER are not installed." >&2
    echo "  sudo apt-get install -y linux-headers-$KVER" >&2
    exit 1
fi

# Ubuntu builds its arm64 kernels with aarch64-linux-gnu-gcc-13. Using a
# different compiler still produces a loadable module (the vermagic check does
# not cover it) but changes the bytes, so pin it when it is there.
CC_CANDIDATE=$(sed -n 's/^.*aarch64-linux-gnu-gcc-\([0-9]*\).*$/aarch64-linux-gnu-gcc-\1/p' \
    "/lib/modules/$KVER/build/include/generated/compile.h" 2>/dev/null | head -1)
if [ -n "${CC_CANDIDATE:-}" ] && command -v "$CC_CANDIDATE" > /dev/null 2>&1; then
    CC="$CC_CANDIDATE"
else
    CC="${CC:-gcc}"
    echo "note: building with $CC, not the kernel's own compiler" >&2
fi

# Pin everything the kernel build would otherwise take from the environment.
SOURCE_DATE_EPOCH=$(git -C "$HERE" log -1 --format=%ct -- . 2>/dev/null \
    || stat -c %Y "$HERE/bromure_sentry.c")
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH"
export KBUILD_BUILD_USER=bromure
export KBUILD_BUILD_HOST=bromure

# A FIXED staging path, not mktemp. An out-of-tree module build embeds its own
# directory in places the prefix maps below do not reach, so a random staging
# directory makes every run produce a different .ko — measured: two runs of an
# earlier version of this script, byte-identical source, differed. Pinning the
# path is what makes two builds on two machines agree, which is the only form of
# reproducibility worth claiming.
STAGE="${BROMURE_SENTRY_STAGE:-/tmp/bromure-sentry-build}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
BUILD="$STAGE/build"

build_once() {
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    cp "$HERE/bromure_sentry.c" "$HERE/bromure_sentry.h" "$HERE/Makefile" "$BUILD/"
    # No BROMURE_SENTRY_TESTABLE here, ever: the shipped module has no exit path.
    make -C "$KDIR" M="$BUILD" CC="$CC" \
        KCPPFLAGS="-fdebug-prefix-map=$BUILD=/bromure -fmacro-prefix-map=$BUILD=/bromure" \
        modules > "$BUILD/build.log" 2>&1 \
        || { echo "build failed:"; tail -30 "$BUILD/build.log"; exit 1; }
    cp "$BUILD/bromure_sentry.ko" "$1"
    cp "$BUILD/build.log" "$1.log"
}

build_once "$STAGE/first.ko"
FIRST_HASH=$(sha256sum "$STAGE/first.ko" | cut -d' ' -f1)

if [ "$VERIFY" = "1" ]; then
    build_once "$STAGE/second.ko"
    SECOND_HASH=$(sha256sum "$STAGE/second.ko" | cut -d' ' -f1)
    if [ "$FIRST_HASH" != "$SECOND_HASH" ]; then
        echo "NOT REPRODUCIBLE: $FIRST_HASH vs $SECOND_HASH" >&2
        echo "compare with: diffoscope $STAGE/first.ko $STAGE/second.ko" >&2
        trap - EXIT
        exit 1
    fi
    echo "reproducible: two builds agree ($FIRST_HASH)"
fi

# Refuse to ship a module that would be rejected at load time anyway.
MAGIC=$(modinfo -F vermagic "$STAGE/first.ko")
case "$MAGIC" in
    "$KVER "*) ;;
    *) echo "vermagic $MAGIC does not match $KVER" >&2; exit 1 ;;
esac

# And refuse to ship one that can be unloaded.
if modinfo "$STAGE/first.ko" | grep -q '^parm: *pin'; then
    echo "REFUSING: this module was built with BROMURE_SENTRY_TESTABLE" >&2
    exit 1
fi

mkdir -p "$OUT" "$OUT/src"
cp "$STAGE/first.ko" "$OUT/bromure_sentry-$KVER.ko"
# The source travels with the binary so bromure-sentryd can rebuild for a guest
# that has upgraded its own kernel past the image's.
cp "$HERE/bromure_sentry.c" "$HERE/bromure_sentry.h" "$HERE/Makefile" "$OUT/src/"
cp "$STAGE/first.ko.log" "$OUT/bromure_sentry-$KVER.build.log"

# Record the exact headers package the module was compiled against, not just the
# kernel release. Two builds of "6.8.0-142-generic" against different
# linux-headers point releases are different builds, and the release pipeline
# needs to be able to say which one shipped.
HEADERS_PKG="linux-headers-$KVER"
HEADERS_VER=$(dpkg-query -W -f='${Version}' "$HEADERS_PKG" 2>/dev/null || echo "unknown")

{
    echo "kernel:      $KVER"
    echo "vermagic:    $MAGIC"
    echo "headers:     $HEADERS_PKG $HEADERS_VER"
    echo "compiler:    $($CC --version | head -1)"
    echo "sha256:      $FIRST_HASH"
    echo "source:      SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    echo "built:       $(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
    echo "reproducible: $([ "$VERIFY" = "1" ] && echo "verified (two builds agree)" || echo "not checked this run")"
} | tee "$OUT/bromure_sentry-$KVER.txt"

echo
echo "-> $OUT/bromure_sentry-$KVER.ko"
echo "   stage this directory as <meta-share>/sentry/"
