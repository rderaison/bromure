#!/bin/bash
# arm64-identical.sh <old-ref> [new-ref|WORKTREE]
# Shows that a change to bromure_sentry.c leaves the arm64 module's code and data alone, by
# cross-building both versions for arm64 6.8.0-147-generic on this x86_64 host.
#
# - Ubuntu's arm64 headers (ports.ubuntu.com), extracted, never installed. Their host tools
#   (fixdep, modpost) are arm64 binaries, so they're rebuilt natively from the shipped sources.
# - aarch64-linux-gnu-gcc-13 (apt: gcc-13-aarch64-linux-gnu), pinned paths and epoch, as build.sh.
# - The OLD source is padded with blank lines after its `#error` block so both have the same
#   line numbers (__LINE__ lands in __bug_table and .data). Then the stripped .ko files may
#   differ only in .modinfo's srcversion (the source's MD5) and the build-id note.
set -euo pipefail
OLD=${1:?usage: arm64-identical.sh <old-ref> [new-ref|WORKTREE]}; NEW=${2:-WORKTREE}
REPO=$(cd "$(dirname "$0")/../.." && pwd); SRC=scripts/openshell-guest/sentry
KVER=6.8.0-147; W=${WORK:-$(mktemp -d)}; mkdir -p "$W"
POOL=https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux
G=$W/root/usr/src/linux-headers-$KVER-generic; C=$W/root/usr/src/linux-headers-$KVER
if [ ! -d "$G" ]; then
  for f in linux-headers-${KVER}_$KVER.147_all.deb linux-headers-$KVER-generic_$KVER.147_arm64.deb; do
    curl -fsSL -o "$W/$f" "$POOL/$f"; dpkg-deb -x "$W/$f" "$W/root"
  done
  gcc -O2 -o "$G/scripts/basic/fixdep" "$C/scripts/basic/fixdep.c"
  aarch64-linux-gnu-gcc-13 -c "$C/scripts/mod/empty.c" -o "$W/empty.o"
  gcc -O2 -o "$W/mk_elfconfig" "$C/scripts/mod/mk_elfconfig.c"
  "$W/mk_elfconfig" < "$W/empty.o" > "$C/scripts/mod/elfconfig.h"
  (cd "$G" && aarch64-linux-gnu-gcc-13 -nostdinc -I./arch/arm64/include -I./arch/arm64/include/generated \
     -I./include -I./arch/arm64/include/uapi -I./arch/arm64/include/generated/uapi -I./include/uapi \
     -I./include/generated/uapi -include ./include/linux/compiler-version.h -include ./include/linux/kconfig.h \
     -include ./include/linux/compiler_types.h -D__KERNEL__ -mlittle-endian -O2 -S -o "$W/devtab.s" \
     "$C/scripts/mod/devicetable-offsets.c")
  sed -ne '/^[[:space:]]*\.ascii[[:space:]]*"\(.*\)"/{s:^[[:space:]]*\.ascii[[:space:]]*"\(.*\)":\1:; s:^->\([^ ]*\) [\$#]*\([-0-9]*\) \(.*\):#define \1 \2 /* \3 */:; s:^->\([^ ]*\) [\$#]*\([^ ]*\) \(.*\):#define \1 \2 /* \3 */:; s:->::; p;}' \
    "$W/devtab.s" > "$C/scripts/mod/devicetable-offsets.h"
  (cd "$C/scripts/mod" && gcc -O2 -I. -o "$G/scripts/mod/modpost" modpost.c file2alias.c sumversion.c symsearch.c)
fi
fetch() {   # fetch <ref|WORKTREE> <dir>
  mkdir -p "$2"
  for f in bromure_sentry.c bromure_sentry.h Makefile; do
    if [ "$1" = WORKTREE ]; then cp "$REPO/$SRC/$f" "$2/"; else git -C "$REPO" show "$1:$SRC/$f" > "$2/$f"; fi
  done
}
build() {   # build <src dir> <out.ko>
  local B=/tmp/bromure-sentry-build/build
  rm -rf "$B"; mkdir -p "$B"; cp "$1"/bromure_sentry.[ch] "$1"/Makefile "$B/"
  SOURCE_DATE_EPOCH=1700000000 KBUILD_BUILD_TIMESTAMP=@1700000000 KBUILD_BUILD_USER=bromure KBUILD_BUILD_HOST=bromure \
  make -s -C "$G" M="$B" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc-13 \
    KCPPFLAGS="-fdebug-prefix-map=$B=/bromure -fmacro-prefix-map=$B=/bromure" modules > "$W/build.log" 2>&1 \
    || { tail -20 "$W/build.log"; exit 1; }
  aarch64-linux-gnu-objcopy --strip-debug "$B/bromure_sentry.ko" "$2"
}
fetch "$OLD" "$W/old"; fetch "$NEW" "$W/new"
PAD=$(( $(wc -l < "$W/new/bromure_sentry.c") - $(wc -l < "$W/old/bromure_sentry.c") ))
[ "$PAD" -ge 0 ] || { echo "the new source is shorter; pad it instead"; exit 1; }
python3 - "$W/old/bromure_sentry.c" "$PAD" <<'PY'
import sys
p, n = sys.argv[1], int(sys.argv[2]); s = open(p).read()
a = "#error \"bromure_sentry reads syscall arguments through arm64's pt_regs wrapper convention\"\n#endif\n"
assert s.count(a) == 1, "old source has no arm64-only #error block to pad after"
open(p, "w").write(s.replace(a, a + "\n" * n))
PY
build "$W/old" "$W/old.ko"; build "$W/new" "$W/new.ko"
OD=aarch64-linux-gnu-objdump
if diff <($OD -dr "$W/old.ko" | sed 1,3d) <($OD -dr "$W/new.ko" | sed 1,3d) > "$W/code.diff"; then
  echo "code + relocations: identical"
else
  echo "code + relocations: DIFFER (see $W/code.diff)"; exit 1
fi
diff <($OD -s "$W/old.ko" | sed 1,3d) <($OD -s "$W/new.ko" | sed 1,3d) | grep '^[<>]' | cut -c1-60 || true
echo "(expected above: only .modinfo's srcversion and .note.gnu.build-id)"
