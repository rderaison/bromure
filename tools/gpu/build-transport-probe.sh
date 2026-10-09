#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${BROMURE_TRANSPORT_PROBE:-/private/tmp/bromure-gpu-probe}"
source_dir=$(mktemp -d /private/tmp/bromure-transport.XXXXXX)
trap 'rm -rf "$source_dir"' EXIT
# Swift top-level code in a multiple-source executable must be named main.swift.
cp tools/gpu/validate-custom-virtio.swift "$source_dir/main.swift"
xcrun swiftc -target arm64-apple-macosx14.0 \
  -module-cache-path "${TMPDIR:-/private/tmp}/bromure-gpu-modules" \
  "$source_dir/main.swift" Sources/SandboxEngine/RendererCommandProcessor.swift Sources/SandboxEngine/MacOS27RendererClient.swift -o "$output"
codesign --force --sign - --entitlements tools/gpu/probe.entitlements "$output"
printf '%s\n' "$output"
