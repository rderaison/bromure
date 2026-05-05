#!/usr/bin/env bash
# build-qemu.sh — build QEMU for Windows with the feature set Bromure
# AC needs (virtfs/9p, vhost-user-fs, GTK + SDL displays, WHPX, tools).
#
# Designed to run inside the MSYS2 UCRT64 shell. The PowerShell wrapper
# (build-qemu.ps1) handles locating MSYS2 and dispatching here.
#
# Inputs (env vars):
#   QEMU_VERSION   — git tag to build, default v11.1.0
#   OUTPUT_DIR     — staged output directory, default $REPO/windows/dist/qemu-bundle
#   BUILD_DIR      — scratch checkout/build dir, default ${TMPDIR:-/tmp}/bromure-qemu
#   JOBS           — parallel make jobs, default $(nproc)
#
# We don't keep the QEMU source tree in our repo — it's cloned fresh
# from upstream each build. Bumping the pinned version is a one-line
# change at the top of this script.

set -euo pipefail

QEMU_VERSION="${QEMU_VERSION:-v11.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/windows/dist/qemu-bundle}"
BUILD_DIR="${BUILD_DIR:-${TMPDIR:-/tmp}/bromure-qemu}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

log() { printf '[build-qemu] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Sanity: we need to be in MSYS2 UCRT64. Other prefixes (MINGW64,
# CLANG64) would also work but the dep names differ; pinning to UCRT64
# keeps the script simple.
# ---------------------------------------------------------------------------
if [ -z "${MSYSTEM:-}" ]; then
    log "MSYSTEM not set — run this from an MSYS2 shell (UCRT64)."
    exit 2
fi
if [ "${MSYSTEM}" != "UCRT64" ]; then
    log "MSYSTEM=$MSYSTEM but UCRT64 is required (rerun under UCRT64 prefix)."
    exit 2
fi

# ---------------------------------------------------------------------------
# Build dependencies. Pulled directly from QEMU's upstream W32 build
# guide (https://wiki.qemu.org/Hosts/W32), pruned to what our flag set
# actually needs. `--needed` skips already-installed packages.
# ---------------------------------------------------------------------------
log "installing MSYS2 build dependencies (pacman --needed)"
pacman -S --noconfirm --needed \
    base-devel \
    git \
    mingw-w64-ucrt-x86_64-toolchain \
    mingw-w64-ucrt-x86_64-glib2 \
    mingw-w64-ucrt-x86_64-pixman \
    mingw-w64-ucrt-x86_64-pkgconf \
    mingw-w64-ucrt-x86_64-python \
    mingw-w64-ucrt-x86_64-ninja \
    mingw-w64-ucrt-x86_64-meson \
    mingw-w64-ucrt-x86_64-gtk3 \
    mingw-w64-ucrt-x86_64-SDL2 \
    mingw-w64-ucrt-x86_64-libpng \
    mingw-w64-ucrt-x86_64-libjpeg-turbo \
    mingw-w64-ucrt-x86_64-curl \
    mingw-w64-ucrt-x86_64-bzip2 \
    mingw-w64-ucrt-x86_64-lzo2 \
    mingw-w64-ucrt-x86_64-snappy \
    mingw-w64-ucrt-x86_64-libssh \
    mingw-w64-ucrt-x86_64-zstd \
    mingw-w64-ucrt-x86_64-spice-protocol \
    mingw-w64-ucrt-x86_64-spice \
    mingw-w64-ucrt-x86_64-usbredir \
    mingw-w64-ucrt-x86_64-libslirp

# ---------------------------------------------------------------------------
# Clone (or fetch) QEMU upstream at the pinned tag.
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
SRC_DIR="$BUILD_DIR/qemu"
if [ ! -d "$SRC_DIR/.git" ]; then
    log "cloning QEMU $QEMU_VERSION into $SRC_DIR"
    git clone --depth 1 --branch "$QEMU_VERSION" \
        https://gitlab.com/qemu-project/qemu.git "$SRC_DIR"
else
    log "reusing existing checkout at $SRC_DIR; resetting to $QEMU_VERSION"
    git -C "$SRC_DIR" fetch --depth 1 origin tag "$QEMU_VERSION" || \
        git -C "$SRC_DIR" fetch --depth 1 origin
    git -C "$SRC_DIR" -c advice.detachedHead=false checkout "$QEMU_VERSION"
fi

# ---------------------------------------------------------------------------
# Configure. Flag set is the minimum to give us:
#   * x86_64 emulation only (saves ~5x build time vs all archs)
#   * WHPX accelerator (Windows Hypervisor Platform; built-in)
#   * GTK + SDL displays so the runtime can fall back per-RDP
#   * SPICE for clipboard / vdagent
#   * Tools (qemu-img is what we use for raw→qcow2 in the bake)
#
# *Not* --enable-virtfs / --enable-vhost-user-fs. QEMU's meson refuses
# both on Windows hosts ("virtio-9p (virtfs) requires Linux or macOS
# or FreeBSD") because the 9p server uses Unix-only syscalls (xattr,
# setresuid, fchroot, ...). vhost-user-fs is similarly Linux-only via
# virtiofsd-rs's AF_UNIX requirement. The Windows runtime uses
# per-launch ISO + SMB instead.
# ---------------------------------------------------------------------------
INSTALL_DIR="$BUILD_DIR/staging"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

BUILD_OUT="$BUILD_DIR/build"
mkdir -p "$BUILD_OUT"
cd "$BUILD_OUT"

# NOTE on virtiofs / vhost-user: investigated and ruled out.
# QEMU's meson.build:230 explicitly rejects vhost-user on Windows
# hosts. Patching the gate compiles, but vhost-user **fundamentally
# requires SCM_RIGHTS file-descriptor passing over AF_UNIX**, which
# Windows AF_UNIX doesn't support. So even with a hypothetical
# virtiofsd.exe (which doesn't exist as an official binary —
# virtiofsd-rs is Linux-only, the "virtiofsd.exe" tutorials online
# refer to a non-existent or experimental binary), the wire protocol
# can't function on a Windows host. virtiofsd-rs's own docs list
# Linux as the only target, since it relies on seccomp / namespaces
# / capabilities. See windows/QEMU_BUILD.md and
# windows/SHARING_INVESTIGATION.md for full sources + the chosen
# alternatives (per-launch ISO + future WinFsp-based custom server).

# QEMU's `scripts/symlink-install-tree.py` postconf builds a fake
# "qemu-bundle/" tree of symlinks at meson setup time so binaries are
# runnable from the build dir as if installed. On Windows that
# requires admin privileges (or Developer Mode) — and the tree is only
# used by tests/dev-loop runs that we don't care about here. Stub the
# script to a no-op so `ninja install` (which uses meson introspection,
# not this tree) still works.
SYMLINK_SCRIPT="$SRC_DIR/scripts/symlink-install-tree.py"
if [ -f "$SYMLINK_SCRIPT" ] && ! grep -q '^# bromure-stub' "$SYMLINK_SCRIPT"; then
    log "stubbing symlink-install-tree.py (qemu-bundle/ tree skipped on Windows)"
    cat > "$SYMLINK_SCRIPT" <<'PYSTUB'
#!/usr/bin/env python3
# bromure-stub: original script created a build-tree mirror of the
# install layout via os.symlink. Windows requires admin/DevMode for
# os.symlink, and we only ever consume the install via `ninja install`
# anyway, so this stub no-ops the postconf.
import sys
sys.exit(0)
PYSTUB
fi

if [ ! -f build.ninja ]; then
    log "configuring QEMU"
    "$SRC_DIR/configure" \
        --prefix="$INSTALL_DIR" \
        --target-list=x86_64-softmmu \
        --enable-whpx \
        --enable-tools \
        --enable-gtk \
        --enable-sdl \
        --enable-spice \
        --enable-png \
        --enable-curl \
        --enable-bzip2 \
        --enable-lzo \
        --enable-snappy \
        --enable-libssh \
        --enable-zstd \
        --enable-slirp \
        --disable-docs \
        --disable-werror \
        --disable-gnutls
fi

log "building QEMU (jobs=$JOBS)"
ninja -j"$JOBS"

log "installing to staging dir $INSTALL_DIR"
ninja install

# ---------------------------------------------------------------------------
# Stage the install into OUTPUT_DIR with the layout QemuPaths expects:
#
#   $OUTPUT_DIR/
#     qemu-system-x86_64.exe
#     qemu-img.exe
#     *.dll                       (all dynamic deps)
#     share/                      (firmware, keymaps, etc)
#
# The MSYS2 `make install` lays things out under bin/ + share/; we
# flatten so QemuPaths.Resolve's "bundle root" probe finds it.
# ---------------------------------------------------------------------------
log "staging output bundle at $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/share"

# Binaries. QEMU's flat-prefix install puts .exe directly under the
# install dir; some configurations also use bin/. Try both.
copy_bin() {
    local name="$1"
    if [ -f "$INSTALL_DIR/bin/$name" ]; then
        cp "$INSTALL_DIR/bin/$name" "$OUTPUT_DIR/"
    elif [ -f "$INSTALL_DIR/$name" ]; then
        cp "$INSTALL_DIR/$name" "$OUTPUT_DIR/"
    fi
}
for exe in qemu-system-x86_64.exe qemu-system-x86_64w.exe qemu-img.exe \
           qemu-edid.exe qemu-storage-daemon.exe qemu-io.exe qemu-nbd.exe \
           elf2dmp.exe qemu-ga.exe; do
    copy_bin "$exe"
done

# Firmware blobs & other share/ data — copy whatever QEMU shipped.
# QEMU 11 drops EDK2 firmwares + bios.bin + keymaps + etc directly
# under share/, not share/qemu/. Both layouts handled.
if [ -d "$INSTALL_DIR/share/qemu" ]; then
    cp -r "$INSTALL_DIR/share/qemu/." "$OUTPUT_DIR/share/"
fi
if [ -d "$INSTALL_DIR/share" ]; then
    # Pull firmware + keymap files we actually need; skip docs / locale.
    for sub in keymaps; do
        [ -d "$INSTALL_DIR/share/$sub" ] && cp -r "$INSTALL_DIR/share/$sub" "$OUTPUT_DIR/share/"
    done
    # Anything matching firmware patterns at the share/ root.
    for f in "$INSTALL_DIR/share/"*.fd "$INSTALL_DIR/share/"*.bin "$INSTALL_DIR/share/"*.rom \
             "$INSTALL_DIR/share/"*.dtb "$INSTALL_DIR/share/"*.img \
             "$INSTALL_DIR/share/"vgabios-*.bin "$INSTALL_DIR/share/"bios*.bin; do
        [ -f "$f" ] && cp "$f" "$OUTPUT_DIR/share/"
    done
fi

# Dynamic DLL closure — walk every .exe with `ldd` and copy each
# resolved DLL that lives under MSYS2's mingw64 prefix. System DLLs
# (in C:\Windows\System32) stay where they are.
log "resolving dynamic dependencies"
declare -A copied_dlls
copy_dll_closure() {
    local exe="$1"
    while read -r line; do
        # ldd output: "name => /path (0x...)"; we want the path.
        local dll_path
        dll_path=$(echo "$line" | awk '{ print $3 }')
        if [ -z "$dll_path" ] || [ ! -f "$dll_path" ]; then continue; fi
        # Only ship MSYS2 DLLs; skip /c/Windows etc.
        case "$dll_path" in
            /ucrt64/*|/mingw64/*) ;;
            *) continue ;;
        esac
        local base
        base=$(basename "$dll_path")
        if [ -n "${copied_dlls[$base]:-}" ]; then continue; fi
        cp "$dll_path" "$OUTPUT_DIR/$base"
        copied_dlls[$base]=1
        # Recurse one level so transitive deps come too. ldd already
        # walks the whole chain so a single pass is enough; this
        # comment is just to remember why we don't loop manually.
    done < <(ldd "$exe" 2>/dev/null || true)
}

for exe in "$OUTPUT_DIR"/*.exe; do
    copy_dll_closure "$exe"
done

# ---------------------------------------------------------------------------
# Manifest — single text file in the bundle telling future-us (or a CI
# job) what tag this came from. The PowerShell wrapper checks this to
# decide whether a rebuild is needed.
# ---------------------------------------------------------------------------
cat > "$OUTPUT_DIR/MANIFEST.txt" <<MANIFEST
qemu_version=$QEMU_VERSION
built_on=$(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by=$(whoami)@$(hostname)
target_list=x86_64-softmmu
flags_summary=whpx,gtk,sdl,spice,tools
MANIFEST

log "DONE — bundle at $OUTPUT_DIR"
log "  qemu-system-x86_64.exe + $(ls "$OUTPUT_DIR"/*.dll 2>/dev/null | wc -l) DLLs"
