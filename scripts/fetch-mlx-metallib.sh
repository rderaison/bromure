#!/usr/bin/env bash
#
# fetch-mlx-metallib.sh — obtain the Metal shader library MLX needs at runtime,
# version-matched to the mlx C++ that mlx-swift vendors.
#
# Why this exists: `swift build` (SwiftPM command line) CANNOT compile MLX's
# Metal kernels — only Xcode/xcodebuild can (with the Metal Toolchain). Rather
# than move the whole build to xcodebuild, we ship a prebuilt, pinned
# `mlx.metallib` colocated with the executable; MLX's loader searches for
# `<binary_dir>/mlx.metallib` first. The metallib MUST match mlx-swift's vendored
# mlx version exactly — a mismatch fails at first kernel dispatch (e.g.
# "rope_float16 cannot be used to build a pipeline state").
#
# The prebuilt library is extracted from the official `mlx` PyPI wheel for that
# exact version (the Metal library is identical across cpXX wheels; no Python is
# installed or run — we just unzip a file).
#
# Usage:
#   scripts/fetch-mlx-metallib.sh [DEST]
#     DEST — optional path to copy the metallib to (e.g. .../Contents/MacOS/mlx.metallib)
#   Prints the cached metallib path on stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the mlx version mlx-swift vendors, so the metallib tracks the SPM pin.
# Falls back to the known-good version if the checkout isn't resolved yet.
FALLBACK_VER="0.24.2"
MLX_PKG="$SCRIPT_DIR/.build/checkouts/mlx-swift/Package.swift"
if [ -f "$MLX_PKG" ]; then
    VER="$(sed -nE 's/.*MLX_VERSION", to: "\\?"?([0-9]+\.[0-9]+\.[0-9]+)\\?"?.*/\1/p' "$MLX_PKG" | head -1)"
fi
VER="${VER:-$FALLBACK_VER}"

# Known-good SHA-256 of the extracted mlx.metallib, per mlx version. The metallib
# is Apple's compiled Metal library (from the official `mlx` package,
# github.com/ml-explore/mlx). Pinning the hash means a tampered/substituted wheel
# is rejected — update this when bumping the mlx-swift pin.
metallib_sha256() {
    case "$1" in
        0.24.2) echo "0ebd8924001cec43f38e1f9e7882596e269fa2dc497d6e9626fd454ab151df62" ;;
        *)      echo "" ;;
    esac
}

CACHE_DIR="${BROMURE_MLX_CACHE:-$HOME/Library/Caches/io.bromure.build/mlx}"
CACHED="$CACHE_DIR/mlx-$VER.metallib"

if [ ! -f "$CACHED" ]; then
    echo "fetch-mlx-metallib: downloading prebuilt mlx.metallib for mlx==$VER…" >&2
    mkdir -p "$CACHE_DIR"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    # Find a macOS arm64 wheel for this exact version (any cpXX — the metallib
    # is the same compiled Metal library in all of them).
    URL="$(curl -fsSL "https://pypi.org/pypi/mlx/$VER/json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d['urls']:
    n = f['filename']
    if 'macosx' in n and 'arm64' in n and n.endswith('.whl'):
        print(f['url']); break
")"
    if [ -z "$URL" ]; then
        echo "fetch-mlx-metallib: no macOS arm64 wheel found for mlx==$VER" >&2
        exit 1
    fi
    curl -fsSL "$URL" -o "$TMP/mlx.whl"
    ( cd "$TMP" && unzip -o -q mlx.whl 'mlx/lib/mlx.metallib' )
    mv "$TMP/mlx/lib/mlx.metallib" "$CACHED"
    echo "fetch-mlx-metallib: cached $CACHED ($(du -h "$CACHED" | cut -f1))" >&2
fi

# Integrity check (fresh download or cache): the bytes must match the pinned
# Apple-published metallib for this version. Unknown versions warn but proceed
# (so a mlx-swift bump isn't hard-blocked before the map is updated).
EXPECT="$(metallib_sha256 "$VER")"
if [ -n "$EXPECT" ]; then
    GOT="$(shasum -a 256 "$CACHED" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECT" ]; then
        echo "fetch-mlx-metallib: SHA-256 mismatch for mlx==$VER" >&2
        echo "  got  $GOT" >&2
        echo "  want $EXPECT" >&2
        rm -f "$CACHED"
        exit 1
    fi
else
    echo "fetch-mlx-metallib: warning — no pinned SHA-256 for mlx==$VER; skipping integrity check." >&2
fi

if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    cp "$CACHED" "$1"
fi
echo "$CACHED"
