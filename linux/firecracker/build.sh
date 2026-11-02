#!/bin/bash
# build.sh [OUT_DIR]: Firecracker for bromure-ac. Clones the pinned upstream
# release, applies patches/ (vhost-user-fs, a SOCK_DGRAM net backend), and
# builds the static musl binary with upstream's seccomp filter into OUT_DIR
# (default ~/.local/share/bromure-ac/bin).
#
# Needs: git, rustup (the toolchain pinned by upstream is fetched on demand),
# musl-gcc (musl-tools, or a musl built into ~/.local/musl), libseccomp.so.2
# (the build script links it to compile the filter), kernel UAPI headers.
# Sources go to $BROMURE_FC_SRC (default ~/.cache/bromure-ac/firecracker-src).
set -euo pipefail

TAG=v1.17.0
COMMIT=95f868c8e345b1cc8faccd1a3c910b4989dc3f58
URL=https://github.com/firecracker-microvm/firecracker.git

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HOME/.local/share/bromure-ac/bin}
SRC=${BROMURE_FC_SRC:-$HOME/.cache/bromure-ac/firecracker-src}
ARCH=$(uname -m)
TARGET=$ARCH-unknown-linux-musl
die() { echo "build.sh: $*" >&2; exit 1; }

export PATH=$HOME/.cargo/bin:$HOME/.local/musl/bin:$PATH
command -v rustup >/dev/null || die "rustup not found (https://rustup.rs; installing it in ~ is enough)"
command -v musl-gcc >/dev/null || die "musl-gcc not found (musl-tools, or musl built with --prefix=~/.local/musl)"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$(dirname "$SRC")"
    git clone -q --branch "$TAG" --depth 1 "$URL" "$SRC"
fi
cd "$SRC"
git fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
[ "$(git rev-parse "$TAG^{commit}")" = "$COMMIT" ] || die "$TAG is not $COMMIT upstream any more"
git am --abort >/dev/null 2>&1 || true
git checkout -q --detach "$COMMIT"
git reset -q --hard
git clean -qfdx -e build/
GIT_COMMITTER_NAME=bromure-build GIT_COMMITTER_EMAIL=build@bromure.invalid \
    git am -q --committer-date-is-author-date "$HERE"/patches/*.patch

# musl-gcc sees only musl's headers: give it the kernel's UAPI ones.
INC=$SRC/build/bromure-include
mkdir -p "$INC"
for d in linux asm-generic; do ln -sfn "/usr/include/$d" "$INC/$d"; done
ln -sfn "/usr/include/$ARCH-linux-gnu/asm" "$INC/asm"
[ -e "$INC/linux/version.h" ] || die "kernel UAPI headers not found (linux-libc-dev)"
# The seccomp filter compiler (a host build script) links -lseccomp: the
# runtime library is enough.
LIB=$SRC/build/bromure-lib
mkdir -p "$LIB"
if ! ldconfig -p | grep -q 'libseccomp\.so '; then
    so=$(ldconfig -p | sed -n 's/.*libseccomp\.so\.2 .*=> //p' | head -1)
    [ -n "$so" ] || die "libseccomp.so.2 not found"
    ln -sfn "$so" "$LIB/libseccomp.so"
fi

T=${TARGET//-/_}
env LIBRARY_PATH="$LIB${LIBRARY_PATH:+:$LIBRARY_PATH}" "CC_$T=musl-gcc" "CFLAGS_$T=-isystem $INC" \
    cargo build -q --release -p firecracker --target "$TARGET"
mkdir -p "$OUT"
install -m 755 "build/cargo_target/$TARGET/release/firecracker" "$OUT/firecracker.new"
mv -f "$OUT/firecracker.new" "$OUT/firecracker"
echo "$OUT/firecracker: $("$OUT/firecracker" --version | head -1), $(git log --oneline "$COMMIT".. | wc -l) patches"
