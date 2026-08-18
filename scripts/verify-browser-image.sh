#!/usr/bin/env bash
#
# verify-browser-image.sh — the publish gates for a freshly built browser
# image, runnable on their own (Jenkinsfile.browser-image gives each its
# own stage) or from scripts/publish-browser-image.sh (local end-to-end).
#
#   boot      bromure verify-image: the disk must boot to the root serial
#             prompt — proves kernel, initramfs, rootfs and systemd.
#   browsers  bromure verify-browsers: apply the catalog postinstall (Google
#             Chrome, WARP) exactly as end-user installs do, then boot a
#             Chromium session and a Chrome session through the real VMPool
#             path and require each browser to come up. Gates the incident
#             where a published image booted fine but Chrome wouldn't install
#             and Chromium wouldn't start.
#   all       both, in that order.
#
# Usage:
#   ./scripts/verify-browser-image.sh <path-to-bromure> <image-dir> [boot|browsers|all]
#
# <image-dir> is what `bromure init-foss-image --output` produced
# (linux-base.img, vmlinuz, initrd, image-version, build-info.json). It is
# never modified: both gates work on disposable APFS clones (`cp -c`) in a
# temp dir, so the artifacts stay byte-identical to what gets checksummed
# and uploaded afterwards.
set -euo pipefail

BROMURE="${1:-}"
IMAGE_DIR="${2:-}"
WHAT="${3:-all}"
if [ -z "$BROMURE" ] || [ ! -x "$BROMURE" ] || [ -z "$IMAGE_DIR" ] || [ ! -d "$IMAGE_DIR" ]; then
    echo "usage: $0 <path-to-bromure> <image-dir> [boot|browsers|all]" >&2
    exit 2
fi
case "$WHAT" in boot|browsers|all) ;; *) echo "unknown gate '$WHAT' (boot|browsers|all)" >&2; exit 2;; esac

BROMURE="$(cd "$(dirname "$BROMURE")" && pwd)/$(basename "$BROMURE")"
IMAGE_DIR="$(cd "$IMAGE_DIR" && pwd)"
BASE_IMG="$IMAGE_DIR/linux-base.img"
KERNEL="$IMAGE_DIR/vmlinuz"
INITRD="$IMAGE_DIR/initrd"
for f in "$BASE_IMG" "$KERNEL" "$INITRD"; do
    [ -f "$f" ] || { echo "ERROR: $f missing — not an init-foss-image output dir?" >&2; exit 1; }
done

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

verify_boot() {
    echo "=== Boot-checking the image (on a disposable clone) ==="
    local img="$SCRATCH/verify.img"
    cp -c "$BASE_IMG" "$img"
    "$BROMURE" verify-image --disk "$img" --kernel "$KERNEL" --initrd "$INITRD" --timeout 300
    rm -f "$img"
}

verify_browsers() {
    echo "=== Verifying Chromium + Google Chrome sessions (on a disposable copy) ==="
    # verify-browsers writes into its directory (postinstall + session
    # clones), so it gets a full copy of the artifact set.
    local dir="$SCRATCH/verify-browsers"
    mkdir -p "$dir"
    cp -c "$BASE_IMG" "$dir/linux-base.img"
    cp -c "$KERNEL"   "$dir/vmlinuz"
    cp -c "$INITRD"   "$dir/initrd"
    if [ -f "$IMAGE_DIR/image-version" ]; then cp "$IMAGE_DIR/image-version" "$dir/image-version"; fi
    "$BROMURE" verify-browsers --dir "$dir" --browser-timeout 180
    rm -rf "$dir"
}

case "$WHAT" in
    boot)     verify_boot ;;
    browsers) verify_browsers ;;
    all)      verify_boot; verify_browsers ;;
esac
echo "=== Image verification ($WHAT) passed ==="
