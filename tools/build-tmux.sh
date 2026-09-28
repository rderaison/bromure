#!/bin/bash
# Build a self-contained tmux for the agent host (bromure-agent-host bundles it
# in Contents/MacOS/tmux). libevent and utf8proc (character widths — emoji in
# agent TUIs) are linked statically; ncurses comes from the system. Versions
# are pinned in tools/tmux.version (like ghostty.commit).
# Output: vendor/tmux/bin/tmux. Never committed; build.sh runs this when missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux.version"   # TMUX_VERSION, LIBEVENT_VERSION, UTF8PROC_VERSION

OUT="$ROOT/vendor/tmux"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFIX="$WORK/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0"

echo "=== libevent $LIBEVENT_VERSION ==="
curl -fsSL -o "$WORK/libevent.tgz" \
    "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"
tar -xzf "$WORK/libevent.tgz" -C "$WORK"
( cd "$WORK/libevent-$LIBEVENT_VERSION"
  # The SDK declares pipe2/accept4 (newer macOS), but they're weak below
  # our deployment target: libevent would call a NULL pointer on macOS 14.
  ac_cv_func_pipe2=no ac_cv_func_accept4=no \
  ./configure --prefix="$PREFIX" --disable-shared --enable-static \
      --disable-openssl --disable-samples --disable-libevent-regress >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null )

echo "=== utf8proc $UTF8PROC_VERSION ==="
curl -fsSL -o "$WORK/utf8proc.tgz" \
    "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$UTF8PROC_VERSION.tar.gz"
tar -xzf "$WORK/utf8proc.tgz" -C "$WORK"
( cd "$WORK/utf8proc-$UTF8PROC_VERSION"
  make libutf8proc.a CFLAGS="$CFLAGS" >/dev/null
  mkdir -p "$PREFIX/lib" "$PREFIX/include"
  cp libutf8proc.a "$PREFIX/lib/"
  cp utf8proc.h "$PREFIX/include/" )

echo "=== tmux $TMUX_VERSION ==="
curl -fsSL -o "$WORK/tmux.tgz" \
    "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
tar -xzf "$WORK/tmux.tgz" -C "$WORK"
( cd "$WORK/tmux-$TMUX_VERSION"
  LIBEVENT_CFLAGS="-I$PREFIX/include" \
  LIBEVENT_LIBS="$PREFIX/lib/libevent_core.a" \
  LIBTINFO_CFLAGS="" LIBTINFO_LIBS="-lncurses" \
  LIBUTF8PROC_CFLAGS="-I$PREFIX/include -DUTF8PROC_STATIC" \
  LIBUTF8PROC_LIBS="$PREFIX/lib/libutf8proc.a" \
      ./configure --prefix="$PREFIX" --enable-utf8proc >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null )

mkdir -p "$OUT/bin"
cp "$WORK/tmux-$TMUX_VERSION/tmux" "$OUT/bin/tmux"
strip -x "$OUT/bin/tmux" || true
echo "$TMUX_VERSION" > "$OUT/VERSION"
echo "=== tmux built: $OUT/bin/tmux ==="
otool -L "$OUT/bin/tmux"
