#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
build_root="${1:-/private/tmp/bromure-gpu}"
prefix="$build_root/prefix"
angle="${BROMURE_ANGLE_SOURCE:-$build_root/sources/angle}"
virgl="${BROMURE_VIRGL_SOURCE:-$build_root/sources/virgl}"
output=$(mktemp -d "$build_root/renderer-xpc.XXXXXX")
app="$output/BromureRendererXPCProbe.app"
service="$app/Contents/XPCServices/io.bromure.gpu.renderer.broker.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS" "$service/Contents/Frameworks"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.bromure.renderer-xpc-probe</string>
<key>CFBundleExecutable</key><string>xpc-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cat > "$service/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.bromure.gpu.renderer.broker</string>
<key>CFBundleExecutable</key><string>renderer</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
xcrun clang -target arm64-apple-macosx27.0 -Wall -Wextra -Werror -fobjc-arc \
    -DBROMURE_RENDERER_XPC -I"$angle/Source/ThirdParty/ANGLE/include" \
    -I"$prefix/include" -I"$prefix/include/virgl" -I"$virgl/src" \
    "$script_dir/validate-metal-renderer.c" "$script_dir/renderer-worker.c" \
    "$script_dir/validate-shared-texture.m" "$script_dir/validate-video-decoder.m" \
    "$script_dir/renderer-xpc-service.m" \
    -L"$prefix/lib" -lepoxy -lvirglrenderer -framework Foundation -framework Metal \
    -framework IOSurface -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
    -Wl,-rpath,@executable_path/../Frameworks -o "$service/Contents/MacOS/renderer"
cp "$service/Contents/MacOS/renderer" "$service/Contents/MacOS/renderer-worker"
xcrun clang -target arm64-apple-macosx14.0 -Wall -Wextra -Werror -fobjc-arc \
    "$script_dir/validate-renderer-xpc.m" -framework Foundation -framework Metal \
    -framework IOSurface -o "$app/Contents/MacOS/xpc-probe"
for library in libEGL.dylib libGLESv2.dylib libepoxy.0.dylib libvirglrenderer.1.dylib; do
    cp -L "$prefix/lib/$library" "$service/Contents/Frameworks/$library"
    install_name_tool -id "@rpath/$library" "$service/Contents/Frameworks/$library"
done
for binary in "$service/Contents/MacOS/renderer" "$service/Contents/MacOS/renderer-worker" "$service"/Contents/Frameworks/*.dylib; do
    while IFS= read -r dependency; do
        [[ "$dependency" == "$prefix/lib/"* ]] || continue
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
    done < <(otool -L "$binary" | awk 'NR>1 {print $1}')
done
mkdir -p "$service/Contents/Resources/licenses"
cp "$prefix"/licenses/* "$service/Contents/Resources/licenses/"
identity=${CODESIGN_IDENTITY:--}
for library in "$service"/Contents/Frameworks/*.dylib; do codesign --force --options runtime --sign "$identity" "$library"; done
codesign --force --options runtime --sign "$identity" --entitlements "$script_dir/worker-inherit.entitlements" "$service/Contents/MacOS/renderer-worker"
codesign --force --options runtime --sign "$identity" --entitlements "$script_dir/helper-probe.entitlements" "$service"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app/Contents/MacOS/xpc-probe"
