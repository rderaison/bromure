#!/usr/bin/env bash
# Build bromure_zeropages for one kernel, reproducibly (the sentry's recipe,
# scripts/openshell-guest/sentry/build.sh: pinned compiler, SOURCE_DATE_EPOCH,
# KBUILD_BUILD_*, a fixed staging path).
#
#   ./build.sh <kver> [--verify]     needs linux-headers-<kver> installed
#   SRC=<dir with Makefile + bromure_zeropages.c> OUT=<dir> ./build.sh <kver>
#
# Writes $OUT/bromure_zeropages-<kver>.ko and a .txt build record.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE}"
KVER="${1:?usage: build.sh <kernel release> [--verify]}"
OUT="${OUT:-$HERE/../zeropages-dist}"
VERIFY=0
[ "${2:-}" = "--verify" ] && VERIFY=1

KDIR="/lib/modules/$KVER/build"
[ -d "$KDIR" ] || { echo "kernel headers for $KVER are not installed (linux-headers-$KVER)" >&2; exit 1; }

CC_CANDIDATE=$(sed -n 's/^.*aarch64-linux-gnu-gcc-\([0-9]*\).*$/aarch64-linux-gnu-gcc-\1/p' \
    "$KDIR/include/generated/compile.h" 2>/dev/null | head -1)
if [ -n "${CC_CANDIDATE:-}" ] && command -v "$CC_CANDIDATE" > /dev/null 2>&1; then
    CC="$CC_CANDIDATE"
else
    CC="${CC:-gcc}"
    echo "note: building with $CC, not the kernel's own compiler" >&2
fi

: "${SOURCE_DATE_EPOCH:=$(stat -c %Y "$SRC/bromure_zeropages.c")}"
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH" KBUILD_BUILD_USER=bromure KBUILD_BUILD_HOST=bromure

# Fixed path: an out-of-tree build embeds its directory, so mktemp would make
# every build differ.
STAGE="${BROMURE_ZEROPAGES_STAGE:-/tmp/bromure-zeropages-build}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
BUILD="$STAGE/build"

build_once() {
    rm -rf "$BUILD"; mkdir -p "$BUILD"
    cp "$SRC/bromure_zeropages.c" "$SRC/Makefile" "$BUILD/"
    make -C "$KDIR" M="$BUILD" CC="$CC" \
        KCPPFLAGS="-fdebug-prefix-map=$BUILD=/bromure -fmacro-prefix-map=$BUILD=/bromure" \
        modules > "$BUILD/build.log" 2>&1 \
        || { echo "build failed:"; tail -30 "$BUILD/build.log"; exit 1; }
    cp "$BUILD/bromure_zeropages.ko" "$1"
}

build_once "$STAGE/first.ko"
FIRST=$(sha256sum "$STAGE/first.ko" | cut -d' ' -f1)
if [ "$VERIFY" = "1" ]; then
    build_once "$STAGE/second.ko"
    SECOND=$(sha256sum "$STAGE/second.ko" | cut -d' ' -f1)
    [ "$FIRST" = "$SECOND" ] || { echo "NOT REPRODUCIBLE: $FIRST vs $SECOND" >&2; trap - EXIT; exit 1; }
    echo "reproducible: two builds agree ($FIRST)"
fi

MAGIC=$(modinfo -F vermagic "$STAGE/first.ko")
case "$MAGIC" in "$KVER "*) ;; *) echo "vermagic $MAGIC does not match $KVER" >&2; exit 1 ;; esac

mkdir -p "$OUT"
cp "$STAGE/first.ko" "$OUT/bromure_zeropages-$KVER.ko"
{
    echo "kernel:      $KVER"
    echo "vermagic:    $MAGIC"
    echo "headers:     linux-headers-$KVER $(dpkg-query -W -f='${Version}' "linux-headers-$KVER" 2>/dev/null || echo unknown)"
    echo "compiler:    $($CC --version | head -1)"
    echo "sha256:      $FIRST"
    echo "sourceHash:  $(sh "$HERE/source-hash.sh" "$SRC")"
    echo "source:      SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    echo "reproducible: $([ "$VERIFY" = "1" ] && echo "verified (two builds agree)" || echo "not checked this run")"
} | tee "$OUT/bromure_zeropages-$KVER.txt"
