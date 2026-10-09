#!/bin/bash
# stamp-build-info.sh — record which build this is in a bundle's Info.plist,
# for the About window ("Jenkins #412 · 69919d6a · 2026-10-09 01:12 UTC").
#
# BromureBuild:     "Jenkins #<BUILD_NUMBER>" on Jenkins (it sets BUILD_NUMBER),
#                   else "Local build".
# BromureCommit:    the short commit, "+dirty" when tracked files changed.
# BromureBuildDate: UTC, when this ran.
#
# Usage: stamp-build-info.sh <Info.plist>   (run before signing)
set -euo pipefail

PLIST="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

commit=$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
if [ "$commit" != unknown ] && ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
    commit="$commit+dirty"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    build="Jenkins #${BUILD_NUMBER}"
else
    build="Local build"
fi
date=$(date -u +"%Y-%m-%d %H:%M UTC")

for kv in "BromureBuild:$build" "BromureCommit:$commit" "BromureBuildDate:$date"; do
    key="${kv%%:*}"; val="${kv#*:}"
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$key string $val" "$PLIST"
done
echo "Build info: $build · $commit · $date"
