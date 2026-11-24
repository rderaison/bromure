#!/bin/bash
# build.sh [OUT_DIR]: bromure-preinit, the /init of a boot template's
# initramfs (preinit.c): a static binary for the guest, which is this host's
# architecture. Into OUT_DIR (default ~/.local/share/bromure-ac/bin; the
# package installs it beside bromure-ac).
#
# Needs a C compiler with a static libc (libc6-dev). Cross build:
# BROMURE_PREINIT_CC=aarch64-linux-gnu-gcc (libc6-dev-arm64-cross).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HOME/.local/share/bromure-ac/bin}
CC=${BROMURE_PREINIT_CC:-cc}
mkdir -p "$OUT"
"$CC" -static -O2 -Wall -Wextra -Werror -I "$HERE/../ACLinux/Sources/CACLinuxShims/include" \
    -o "$OUT/bromure-preinit.tmp" "$HERE/preinit.c"
mv -f "$OUT/bromure-preinit.tmp" "$OUT/bromure-preinit"
echo "$OUT/bromure-preinit: $(stat -c %s "$OUT/bromure-preinit") bytes"
