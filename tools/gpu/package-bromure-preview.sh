#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
build_dir="${1:?Pass the SwiftPM binary directory}"
xpc="${2:?Pass the built io.bromure.gpu.renderer.broker.xpc directory}"
output="${3:-/private/tmp/bromure-gpu-preview}"
[[ -x "$build_dir/bromure" && -d "$xpc" ]] || { echo 'Missing built app or service' >&2; exit 1; }
mkdir -p "$output"
directory=$(mktemp -d "$output/preview.XXXXXX")
app="$directory/Bromure GPU Preview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$app/Contents/XPCServices"
cp "$build_dir/bromure" "$app/Contents/MacOS/bromure"
cp "$repo/Sources/Browser/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.bromure.gpu-preview' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Bromure GPU Preview' "$app/Contents/Info.plist"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/bromure" 2>/dev/null || true
for resource in "$build_dir"/*.bundle; do
    [[ -e "$resource" ]] && cp -R "$resource" "$app/Contents/Resources/"
done
cp -R "$build_dir/Sparkle.framework" "$app/Contents/Frameworks/"
cp -R "$xpc" "$app/Contents/XPCServices/io.bromure.gpu.renderer.broker.xpc"
codesign --force --sign - --entitlements "$repo/tools/gpu/probe.entitlements" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app/Contents/MacOS/bromure"
