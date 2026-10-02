#!/bin/bash
# Standalone macOS 27 renderer proof. Does not link libraries into Bromure.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
build_root=${BROMURE_GPU_BUILD_ROOT:-/private/tmp/bromure-gpu}
mkdir -p "$build_root"
build_root=$(cd "$build_root" && pwd)
prefix="$build_root/prefix"
tool_env=${BROMURE_GPU_TOOL_ENV:-$build_root/tools}
angle=${BROMURE_ANGLE_SOURCE:-$build_root/sources/angle}
epoxy=${BROMURE_EPOXY_SOURCE:-$build_root/sources/epoxy}
virgl=${BROMURE_VIRGL_SOURCE:-$build_root/sources/virgl}
pkgconf=${BROMURE_PKGCONF_SOURCE:-$build_root/sources/pkgconf}

if [[ $(uname -m) != arm64 ]]; then echo 'Apple Silicon required' >&2; exit 1; fi
if [[ $(xcrun --sdk macosx --show-sdk-version) != 27.* ]]; then
    echo 'macOS SDK 27 required' >&2; exit 1
fi

if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
    echo 'Metal Toolchain is missing or cannot run with the selected Xcode.' >&2
    echo 'Run as the Jenkins build user: xcodebuild -downloadComponent MetalToolchain' >&2
    echo 'Then verify: xcrun --sdk macosx metal --version' >&2
    exit 1
fi

checkout() {
    local directory=$1 repository=$2 revision=$3
    if [[ ! -d "$directory/.git" ]]; then
        mkdir -p "$directory"
        git init -q "$directory"
        git -C "$directory" remote add origin "$repository"
        git -C "$directory" fetch -q --depth 1 --filter=blob:none origin "$revision"
        if [[ "$directory" == "$angle" ]]; then
            git -C "$directory" sparse-checkout init --cone
            git -C "$directory" sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
        fi
        git -C "$directory" checkout -q --detach "$revision"
    fi
    [[ $(git -C "$directory" rev-parse HEAD) == "$revision" ]] || {
        echo "Wrong source revision in $directory; use a fresh build directory" >&2; exit 1;
    }
    if [[ "$directory" != "$epoxy" && "$directory" != "$angle" && "$directory" != "$virgl" ]]; then
        git -C "$directory" diff --quiet
        git -C "$directory" diff --cached --quiet
    fi
}

checkout "$angle" https://github.com/utmapp/WebKit.git ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
checkout "$epoxy" https://github.com/utmapp/libepoxy.git bf98587477fe68d07b93319ece7b40a7d0e2eabe
checkout "$virgl" https://github.com/utmapp/virglrenderer.git 5d26f605f50f8e22002ec6db5fb775e1992d4e96
checkout "$pkgconf" https://github.com/pkgconf/pkgconf.git 4fc570f91d9d8d843ab32d2198a5c064538d8ffd
if ! git -C "$epoxy" apply --reverse --check "$script_dir/libepoxy-dylib.patch" 2>/dev/null; then
    git -C "$epoxy" apply --check "$script_dir/libepoxy-dylib.patch"
    git -C "$epoxy" apply "$script_dir/libepoxy-dylib.patch"
fi
git -C "$epoxy" diff --cached --quiet
git -C "$epoxy" -c core.abbrev=8 diff -- src/dispatch_common.c | cmp - "$script_dir/libepoxy-dylib.patch"
git -C "$epoxy" diff --quiet -- . ':!src/dispatch_common.c'
if ! git -C "$angle" apply --reverse --check "$script_dir/angle-dylib.patch" 2>/dev/null; then
    git -C "$angle" apply --check "$script_dir/angle-dylib.patch"
    git -C "$angle" apply "$script_dir/angle-dylib.patch"
fi
git -C "$angle" diff --cached --quiet
git -C "$angle" -c core.abbrev=8 diff -- Source/ThirdParty/ANGLE/src/common/system_utils.cpp | cmp - "$script_dir/angle-dylib.patch"
git -C "$angle" diff --quiet -- . ':!Source/ThirdParty/ANGLE/src/common/system_utils.cpp'

if ! git -C "$virgl" apply --reverse --check "$script_dir/virgl-metal-browser.patch" 2>/dev/null; then
    git -C "$virgl" apply --check "$script_dir/virgl-metal-browser.patch"
    git -C "$virgl" apply "$script_dir/virgl-metal-browser.patch"
fi
git -C "$virgl" diff --cached --quiet
git -C "$virgl" -c core.abbrev=8 diff -- meson.build src/meson.build src/vrend/vrend_decode.c src/vrend/virgl_video.h src/vrend/vrend_video.c src/vrend/vrend_formats.c src/vrend/vrend_renderer.c src/vrend/vrend_renderer.h src/vrend/vrend_shader.c | cmp - "$script_dir/virgl-metal-browser.patch"
git -C "$virgl" diff --quiet -- . ':!src/vrend/vrend_formats.c' ':!src/vrend/vrend_renderer.c' ':!src/vrend/vrend_renderer.h' ':!meson.build' ':!src/meson.build' ':!src/vrend/virgl_video.h' ':!src/vrend/vrend_video.c' ':!src/vrend/vrend_decode.c' ':!src/vrend/vrend_shader.c'

if [[ ! -f "$virgl/src/vrend/virgl_video_videotoolbox.m" ]]; then
    cp "$script_dir/virgl-video-videotoolbox.m" "$virgl/src/vrend/virgl_video_videotoolbox.m"
fi
cmp "$script_dir/virgl-video-videotoolbox.m" "$virgl/src/vrend/virgl_video_videotoolbox.m"

if [[ ! -x "$tool_env/bin/python3" ]]; then xcrun python3 -m venv "$tool_env"; fi
if ! "$tool_env/bin/python3" -c 'import pkg_resources; pkg_resources.require(["meson==1.11.2", "ninja==1.13.2", "Mako==1.3.12", "MarkupSafe==3.0.3", "packaging==26.3", "PyYAML==6.0.3"])' 2>/dev/null; then
    "$tool_env/bin/pip" install --disable-pip-version-check meson==1.11.2 ninja==1.13.2 Mako==1.3.12 MarkupSafe==3.0.3 packaging==26.3 PyYAML==6.0.3
fi
export PATH="$tool_env/bin:$prefix/bin:$PATH"
export TMPDIR="$build_root/temporary"
mkdir -p "$TMPDIR" "$prefix/lib" "$prefix/include"
export MACOSX_DEPLOYMENT_TARGET=27.0

echo 'Building ANGLE Metal (log: angle-build.log)'
if ! (cd "$angle/Source/ThirdParty/ANGLE" && xcodebuild archive -quiet \
    -project ANGLE.xcodeproj -scheme ANGLE -sdk macosx ARCHS=arm64 \
    -destination 'generic/platform=macOS' -configuration Release \
    -archivePath "$build_root/angle-archive" -derivedDataPath "$build_root/angle-derived" \
    WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR= \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO MACOSX_DEPLOYMENT_TARGET=27.0 \
    WK_LIBCPP_ASSERTIONS_CFLAGS=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST) >"$build_root/angle-build.log" 2>&1; then
    tail -60 "$build_root/angle-build.log" >&2; exit 1
fi
cp "$build_root/angle-archive.xcarchive/Products/usr/local/lib/"lib{EGL,GLESv2}.dylib "$prefix/lib/"
install_name_tool -id @rpath/libEGL.dylib "$prefix/lib/libEGL.dylib"
install_name_tool -id @rpath/libGLESv2.dylib "$prefix/lib/libGLESv2.dylib"
codesign --force --sign - "$prefix/lib/libEGL.dylib"
codesign --force --sign - "$prefix/lib/libGLESv2.dylib"

build_meson() {
    local name=$1 source=$2
    shift 2
    if [[ -f "$build_root/$name-build/build.ninja" ]]; then
        meson configure "$build_root/$name-build" "$@"
    else
        meson setup "$build_root/$name-build" "$source" --prefix="$prefix" "$@"
    fi
    meson compile -C "$build_root/$name-build"
    meson install -C "$build_root/$name-build"
}
build_meson pkgconf "$pkgconf" -Ddefault_library=static -Dtests=disabled
export PKG_CONFIG="$prefix/bin/pkgconf"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
# pkgconf was built in this same prefix; retain its include/library flags.
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1 PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
include_angle="-I$angle/Source/ThirdParty/ANGLE/include"
build_meson epoxy "$epoxy" -Dtests=false -Dglx=no -Degl=yes "-Dc_args=$include_angle"
build_meson virgl "$virgl" -Dplatforms=egl -Dtests=false -Dvtest=false \
    -Dvenus=false -Dneptune=false -Dvideo=true "-Dc_args=$include_angle"

# Preserve upstream notices alongside probe dependencies.
mkdir -p "$prefix/licenses"
cp "$angle/Source/ThirdParty/ANGLE/LICENSE" "$prefix/licenses/ANGLE.txt"
cp "$epoxy/COPYING" "$prefix/licenses/libepoxy.txt"
cp "$virgl/COPYING" "$prefix/licenses/virglrenderer.txt"
xcrun clang -target arm64-apple-macosx27.0 -Wall -Wextra -Werror -fobjc-arc \
    "$include_angle" -I"$prefix/include" -I"$prefix/include/virgl" -I"$virgl/src" \
    "$script_dir/validate-metal-renderer.c" "$script_dir/renderer-worker.c" "$script_dir/validate-shared-texture.m" \
    "$script_dir/validate-video-decoder.m" \
    -L"$prefix/lib" -lepoxy -lvirglrenderer -framework Foundation -framework Metal \
    -framework IOSurface -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
    -Wl,-rpath,"$prefix/lib" -o "$build_root/metal-probe"
echo "Built $build_root/metal-probe; run on macOS 27 with access to the host GPU."
