#!/bin/bash
# Shared by development and release packaging. Build on SDK 27, retain the
# macOS 14 main-app target, and sign the isolated service with the app identity.
set -euo pipefail
contents=${1:?Pass app Contents directory}
identity=${2:--}
script_dir=$(cd "$(dirname "$0")" && pwd)
renderer=${BROMURE_RENDERER_XPC:-}
if [[ -z "$renderer" && ${BROMURE_BUILD_GPU_RENDERER:-auto} != 0 && $(uname -m) == arm64 && $(xcrun --sdk macosx --show-sdk-version) == 27.* ]]; then
    root=${BROMURE_GPU_BUILD_ROOT:-/private/tmp/bromure-gpu}
    bash "$script_dir/build-renderer-probe.sh"
    package_log=$(mktemp "$root/renderer-package.XXXXXX")
    bash "$script_dir/package-renderer-xpc.sh" "$root" > "$package_log"
    probe=$(tail -n 1 "$package_log")
    renderer="$(dirname "$(dirname "$probe")")/XPCServices/io.bromure.gpu.renderer.broker.xpc"
fi
[[ -n "$renderer" ]] || exit 0
[[ -x "$renderer/Contents/MacOS/renderer" ]] || { echo 'Invalid renderer XPC bundle' >&2; exit 1; }
protocol=$(/usr/libexec/PlistBuddy -c 'Print :BromureRendererProtocolVersion' "$renderer/Contents/Info.plist" 2>/dev/null || true)
[[ "$protocol" == 2 ]] || { echo 'Outdated GPU renderer bundle: rebuild with tools/gpu/package-renderer-xpc.sh; remove any stale BROMURE_RENDERER_XPC override.' >&2; exit 1; }
codesign --verify --deep --strict "$renderer"
mkdir -p "$contents/XPCServices"
service="$contents/XPCServices/io.bromure.gpu.renderer.broker.xpc"
ditto "$renderer" "$service"
for library in "$service/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime --sign "$identity" "$library"
done
codesign --force --options runtime --sign "$identity" \
    --entitlements "$script_dir/worker-inherit.entitlements" "$service/Contents/MacOS/renderer-worker"
codesign --force --options runtime --sign "$identity" \
    --entitlements "$script_dir/helper-probe.entitlements" "$service"
codesign --verify --deep --strict "$service"
echo 'Bundled sandboxed VirGL/Metal and hardware H.264 renderer.'
