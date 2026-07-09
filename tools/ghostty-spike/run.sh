#!/bin/bash
# Build + run the Phase 0 GhosttyKit spike (4 surfaces + teardown soak).
# Exits 0 on pass. Briefly shows a small window titled "bromure ghostty
# spike" — it closes itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XCFW="$ROOT/vendor/GhosttyKit.xcframework/macos-arm64"
[ -d "$XCFW" ] || { echo "run tools/build-ghostty.sh first" >&2; exit 1; }
OUT="${TMPDIR:-/tmp}/bromure-ghostty-spike"
swiftc "$ROOT/tools/ghostty-spike/main.swift" \
    -I "$XCFW/Headers" \
    "$XCFW/libghostty-fat.a" \
    -framework AppKit -framework Metal -framework MetalKit \
    -framework QuartzCore -framework CoreText -framework Carbon \
    -framework CoreVideo -framework IOSurface -framework UniformTypeIdentifiers \
    -lc++ \
    -o "$OUT"
GHOSTTY_RESOURCES_DIR="$ROOT/vendor/ghostty-resources/ghostty" exec "$OUT"
