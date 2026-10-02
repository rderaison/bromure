#!/bin/bash
# Package only the standalone proof as a sandboxed helper app.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
build_root=${1:-${BROMURE_GPU_BUILD_ROOT:-/private/tmp/bromure-gpu}}
build_root=$(cd "$build_root" && pwd)
prefix="$build_root/prefix"
bundle_root=$(mktemp -d "$build_root/renderer-probe.XXXXXX")
bundle="$bundle_root/BromureRendererProbe.app"
frameworks="$bundle/Contents/Frameworks"
mkdir -p "$bundle/Contents/MacOS" "$frameworks"
cp "$script_dir/helper-probe-Info.plist" "$bundle/Contents/Info.plist"
cp "$build_root/metal-probe" "$bundle/Contents/MacOS/metal-probe"
for library in libEGL.dylib libGLESv2.dylib libepoxy.0.dylib libvirglrenderer.1.dylib; do
    cp "$prefix/lib/$library" "$frameworks/$library"
    install_name_tool -id "@rpath/$library" "$frameworks/$library"
done
install_name_tool -change "$prefix/lib/libepoxy.0.dylib" @rpath/libepoxy.0.dylib "$frameworks/libvirglrenderer.1.dylib"
binary="$bundle/Contents/MacOS/metal-probe"
install_name_tool -change "$prefix/lib/libepoxy.0.dylib" @rpath/libepoxy.0.dylib "$binary"
install_name_tool -change "$prefix/lib/libvirglrenderer.1.dylib" @rpath/libvirglrenderer.1.dylib "$binary"
install_name_tool -rpath "$prefix/lib" @executable_path/../Frameworks "$binary"
cp -R "$prefix/licenses" "$bundle/Contents/Resources"
for library in libEGL.dylib libGLESv2.dylib libepoxy.0.dylib libvirglrenderer.1.dylib; do
    codesign --force --sign - "$frameworks/$library"
done
codesign --force --sign - --entitlements "$script_dir/helper-probe.entitlements" "$bundle"
codesign --verify --strict "$bundle"
echo "Sandboxed probe built: $binary"
