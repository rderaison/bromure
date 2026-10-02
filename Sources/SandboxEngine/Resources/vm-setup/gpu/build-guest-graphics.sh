#!/bin/sh
# Run as root in Ubuntu ARM64. System Mesa remains the software fallback.
set -eu
assets=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" = 0 ]
[ "$(dpkg --print-architecture)" = arm64 ]
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q --no-install-recommends build-essential pkg-config python3-venv flex bison \
    libdrm-dev libexpat1-dev libx11-dev libxext-dev libxfixes-dev libxcb-dri3-dev \
    libxcb-present-dev libxcb-randr0-dev libxshmfence-dev libva-dev libglvnd-dev libelf-dev \
    libzstd-dev zlib1g-dev libxxf86vm-dev libxcb-glx0-dev libxcb-dri2-0-dev libxcb-shm0-dev \
    libxcb-sync-dev libxcb-xfixes0-dev libxrandr-dev libxdamage-dev libx11-xcb-dev patchelf curl patch
build=${BROMURE_GPU_GUEST_BUILD_DIR:-/var/tmp/bromure-graphics-build}
mkdir -p "$build"
archive="$build/mesa-25.2.8.tar.xz"
[ -f "$archive" ] || curl -fL --retry 3 https://archive.mesa3d.org/mesa-25.2.8.tar.xz -o "$archive"
printf '%s  %s\n' 097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93 "$archive" | sha256sum -c -
# Restore pinned source before applying local patches, including on rebuilds.
tar -xJf "$archive" -C "$build"
patch -d "$build/mesa-25.2.8" -p1 < "$assets/mesa-virgl-video-export.patch"
patch -d "$build/mesa-25.2.8" -p1 < "$assets/mesa-virgl-video-compositor.patch"
patch -d "$build/mesa-25.2.8" -p1 < "$assets/mesa-virgl-fence-reference.patch"
[ -x "$build/venv/bin/python3" ] || python3 -m venv "$build/venv"
"$build/venv/bin/pip" install --disable-pip-version-check meson==1.11.2 ninja==1.13.0 Mako==1.3.12 MarkupSafe==3.0.3 PyYAML==6.0.3 packaging==26.3
export PATH="$build/venv/bin:$PATH"
if [ -f "$build/build/build.ninja" ]; then
    meson configure "$build/build"
else
    meson setup "$build/build" "$build/mesa-25.2.8" --prefix=/opt/bromure/mesa-virgl --libdir=lib \
        --buildtype=release -Dgallium-drivers=virgl -Dvulkan-drivers= -Dllvm=disabled \
        -Dgallium-va=enabled -Dvideo-codecs=h264dec -Dplatforms=x11 -Dglvnd=enabled \
        -Dgles1=disabled -Dgles2=enabled -Degl=enabled -Dgbm=enabled -Dglx=dri -Dbuild-tests=false
fi
ninja -C "$build/build" -j "${BROMURE_GPU_BUILD_JOBS:-6}"
meson install --no-rebuild -C "$build/build"
facade=/opt/bromure/chromium-vaapi
mkdir -p "$facade/licenses"
cp -L /usr/lib/aarch64-linux-gnu/libva.so.2 "$facade/libbromure-va.so.2"
patchelf --set-soname libbromure-va.so.2 "$facade/libbromure-va.so.2"
cc -shared -fPIC -O2 -Wall -Wextra -Werror "$assets/chromium-virgl-vaapi.c" \
    -o "$facade/libva.so.2" -Wl,-soname,libva.so.2 -Wl,--no-as-needed \
    -L"$facade" -l:libbromure-va.so.2 -Wl,-rpath,'$ORIGIN' -ldl -pthread
cp /usr/share/doc/libva2/copyright "$facade/licenses/libva.txt"
mkdir -p /opt/bromure/mesa-virgl/licenses
cp "$build/mesa-25.2.8/docs/license.rst" /opt/bromure/mesa-virgl/licenses/Mesa.txt
LD_LIBRARY_PATH=/opt/bromure/mesa-virgl/lib python3 - <<'PY'
import ctypes
from pathlib import Path
root = Path('/opt/bromure/mesa-virgl/lib')
for name in ('libEGL_mesa.so.0', 'libGLX_mesa.so.0', 'libgbm.so.1', 'dri/virtio_gpu_dri.so', 'dri/virtio_gpu_drv_video.so'):
    ctypes.CDLL(str(root/name))
ctypes.CDLL('/opt/bromure/chromium-vaapi/libva.so.2')
PY
printf '%s\n' 'mesa=25.2.8' 'video=h264-8bit-progressive' 'chromium-vaapi-rgb-abi=1' 'virgl-bitstream-range=1' 'virgl-fence-reference=1' > /opt/bromure/mesa-virgl/graphics-build.txt
