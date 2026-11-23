#!/bin/bash
# build.sh [OUT_DIR]: virtiofsd for bromure-ac, the pinned upstream release,
# into OUT_DIR (default ~/.local/share/bromure-ac/bin).
#
# Why not the distribution's: the daemon runs virtiofsd with
# --translate-uid/--translate-gid and --migration-mode/--migration-on-error
# (MachineConfig.virtiofsdArguments), which came in virtiofsd 1.11. Ubuntu
# 24.04 ships 1.10, which refuses them: every share, the image bake's
# included, fails to start there.
#
# A glibc binary with libseccomp and libcap-ng linked in statically: it needs
# only the C library (glibc 2.39, Ubuntu 24.04, or newer). The two static
# libraries are the target's: $BROMURE_VFS_LIBDIR (a directory holding
# libseccomp.a and libcap-ng.a), default /usr/lib/$ARCH-linux-gnu
# (libseccomp-dev, libcap-ng-dev).
#
# Cross build: BROMURE_VFS_ARCH=x86_64 (or aarch64) on another host, linked
# by $ARCH-linux-gnu-gcc (gcc-x86-64-linux-gnu; $BROMURE_VFS_LINKER to name
# another), BROMURE_VFS_LIBDIR the target's libraries (Dockerfile.toolchain
# keeps their packages in /opt/target-debs). Sources go to $BROMURE_VFS_SRC
# (default ~/.cache/bromure-ac/virtiofsd-src).
set -euo pipefail

TAG=v1.13.3
COMMIT=bbf82173682a3e48083771a0a23331e5c23b4924
URL=https://gitlab.com/virtio-fs/virtiofsd.git

OUT=${1:-$HOME/.local/share/bromure-ac/bin}
SRC=${BROMURE_VFS_SRC:-$HOME/.cache/bromure-ac/virtiofsd-src}
HOST_ARCH=$(uname -m)
ARCH=${BROMURE_VFS_ARCH:-$HOST_ARCH}
case $ARCH in x86_64|aarch64) ;; *) echo "build.sh: unsupported arch $ARCH" >&2; exit 1;; esac
LIBDIR=${BROMURE_VFS_LIBDIR:-/usr/lib/$ARCH-linux-gnu}
LINKER=${BROMURE_VFS_LINKER:-$ARCH-linux-gnu-gcc}
TARGET=$ARCH-unknown-linux-gnu
die() { echo "build.sh: $*" >&2; exit 1; }

export PATH=$HOME/.cargo/bin:$PATH
command -v cargo >/dev/null || die "cargo not found (https://rustup.rs)"
for a in libseccomp.a libcap-ng.a; do
    [ -f "$LIBDIR/$a" ] || die "$LIBDIR/$a not found (libseccomp-dev, libcap-ng-dev for $ARCH; or BROMURE_VFS_LIBDIR)"
done
[ "$ARCH" = "$HOST_ARCH" ] || command -v "$LINKER" >/dev/null || die "$LINKER not found (gcc-$(echo "$ARCH" | tr _ -)-linux-gnu)"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$(dirname "$SRC")"
    git clone -q --branch "$TAG" --depth 1 "$URL" "$SRC"
fi
cd "$SRC"
git fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
[ "$(git rev-parse "$TAG^{commit}")" = "$COMMIT" ] || die "$TAG is not $COMMIT upstream any more"
git checkout -q --detach "$COMMIT"
git reset -q --hard
git clean -qfdx -e target/
command -v rustup >/dev/null && rustup target add "$TARGET" >/dev/null

# Only the static archives in the search path: the linker takes them over
# any libseccomp.so/libcap-ng.so elsewhere.
STATIC=$SRC/target/bromure-static
rm -rf "$STATIC" && mkdir -p "$STATIC"
for a in libseccomp.a libcap-ng.a; do ln -s "$(readlink -f "$LIBDIR/$a")" "$STATIC/$a"; done

T=$(echo "${TARGET//-/_}" | tr '[:lower:]' '[:upper:]')
CROSS_ENV=()
[ "$ARCH" = "$HOST_ARCH" ] || CROSS_ENV=("CARGO_TARGET_${T}_LINKER=$LINKER")
env LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH="$STATIC" \
    "CARGO_TARGET_${T}_RUSTFLAGS=-L native=$STATIC" "${CROSS_ENV[@]}" \
    cargo build -q --locked --release --target "$TARGET"
BIN=target/$TARGET/release/virtiofsd

# Linked as meant: only the C library (and the loader) left to the system.
needed=$(readelf -d "$BIN" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -Ev '^(libc|libm|libgcc_s|ld-linux[-a-z0-9_.]*)\.so' || true)
[ -z "$needed" ] || die "virtiofsd still needs $(echo $needed): not the static libraries"
# Runs on Ubuntu 24.04: no symbol from a newer glibc than 2.39.
newest=$(objdump -T "$BIN" | grep -o 'GLIBC_[0-9.]*' | sort -t. -k2,2n -k3,3n -u | tail -1)
[ "$(printf '%s\n' "$newest" GLIBC_2.39 | sort -t. -k2,2n -k3,3n | tail -1)" = GLIBC_2.39 ] \
    || die "virtiofsd needs $newest: newer than Ubuntu 24.04's glibc 2.39"

mkdir -p "$OUT"
install -m 755 "$BIN" "$OUT/virtiofsd.new"
mv -f "$OUT/virtiofsd.new" "$OUT/virtiofsd"
if [ "$ARCH" = "$HOST_ARCH" ]; then v=$("$OUT/virtiofsd" --version | head -1); else v="$TAG for $ARCH (cross-built)"; fi
echo "$OUT/virtiofsd: $v (needs $newest)"
