#!/usr/bin/env bash
#
# publish-browser-image.sh — build the free-software browser base image
# and publish it to the DigitalOcean Space that Bromure Web downloads
# from at install time. Jenkins runs this weekly
# (Jenkinsfile.browser-image) so new installations always start from an
# image with current Alpine packages.
#
# Publishes, under https://dl.bromure.io/ (the `bromure-dl` bucket):
#
#   browser-images/img-catalog.json      ← the live image manifest (1s CDN TTL)
#   browser-images/<uuid>/base.img.gz    ← the compressed raw disk image
#   browser-images/<uuid>/vmlinuz.gz     ← the raw ARM64 kernel (direct boot)
#   browser-images/<uuid>/initrd.gz      ← the mkinitfs initramfs
#
# <uuid> is random per build. Unlike the AC image (EFI/GRUB, one disk
# artifact — scripts/publish-image.sh), the browser image direct-kernel-
# boots via VZLinuxBootLoader, so the kernel and initramfs are published
# alongside the disk and declared in the catalog's `boot` array.
#
# The catalog's postinstall steps come verbatim from
# Sources/SandboxEngine/Resources/browser-img-catalog.json (the canonical
# source) — that's where the non-free software (Cloudflare WARP) is
# declared, since the published image must contain free software only.
# Apple fonts are likewise never in the published image (copied from the
# end-user's own Mac during postinstall).
#
# Sequence (mirrors scripts/publish-image.sh):
#   1. Build the image with the latest Alpine packages
#      (bromure init-foss-image — strict: missing kernel modules FAIL).
#   2. Boot-check an APFS CLONE of the disk (bromure verify-image): the
#      image must reach the root serial prompt, but the published
#      artifact stays pristine — booting writes logs/state.
#   3. Compress + upload the three artifacts under browser-images/<uuid>/.
#   4. Download the previous img-catalog.json (for the retired uuid).
#   5. Generate the new img-catalog.json (browser payload magic + boot files).
#   6. Upload it with a 1-second cache expiry.
#   7. Smoke-test the published catalog + artifacts from the CDN.
#   8. Delete the previous build's objects.
#
# Usage:
#   ./scripts/publish-browser-image.sh <path-to-bromure>
#
# <path-to-bromure> is a PRE-BUILT bromure binary, signed with the
# virtualization entitlement — i.e. the one inside the app bundle
# `./build.sh bromure` produces. This script deliberately does NOT build
# the binary itself (build.sh/package.sh own that); Jenkinsfile.browser-image
# runs build.sh first and passes the path in.
#
# Required env (Jenkins injects the secrets; the rest come from
# Jenkinsfile.browser-image):
#   DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_REGION
#   DO_SPACES_BUCKET DO_SPACES_PUBLIC_BASE
# Optional:
#   DRY_RUN        (1 = build + verify + compress, but skip every upload/delete)
#   KEEP_PREVIOUS  (1 = don't delete the previous image after publishing)
set -euo pipefail

# Resolve the binary argument to an absolute path BEFORE cd'ing to the
# repo root — callers pass paths relative to their own cwd.
BROMURE="${1:-}"
if [ -z "$BROMURE" ] || [ ! -x "$BROMURE" ]; then
    echo "usage: $0 <path-to-bromure>" >&2
    echo "  e.g.: ./build.sh bromure && \\" >&2
    echo "        $0 '.build/arm64-apple-macosx/release/Bromure.app/Contents/MacOS/bromure'" >&2
    exit 2
fi
BROMURE="$(cd "$(dirname "$BROMURE")" && pwd)/$(basename "$BROMURE")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# The image build + boot check run Virtualization.framework, which needs
# the com.apple.security.virtualization entitlement on the signed binary
# (build.sh applies it). Warn early instead of failing 10 minutes in.
if ! codesign -d --entitlements - "$BROMURE" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    echo "WARNING: $BROMURE doesn't appear to carry the virtualization entitlement — the VM steps will likely fail." >&2
fi

enabled() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac }
DRY_RUN="${DRY_RUN:-0}"
KEEP_PREVIOUS="${KEEP_PREVIOUS:-0}"

if ! enabled "$DRY_RUN"; then
    : "${DO_SPACES_KEY:?}" "${DO_SPACES_SECRET:?}" "${DO_SPACES_ENDPOINT:?}"
    : "${DO_SPACES_REGION:?}" "${DO_SPACES_BUCKET:?}" "${DO_SPACES_PUBLIC_BASE:?}"
    # Catalog signing key (same credential that signs Sparkle updates).
    # Clients refuse unsigned production catalogs, so publishing without
    # it would brick every new installation's download path.
    : "${SPARKLE_PRIVATE_KEY:?}"
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

put() {  # local key [contentType] [cacheControl]
    node tools/spaces-put.mjs "$1" "$2" "${3:-}" "${4:-}"
}

gz_compress() {  # src dest
    if command -v pigz >/dev/null 2>&1; then
        pigz -9 -c "$1" > "$2"
    else
        gzip -9 -c "$1" > "$2"
    fi
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. Build the free-software image -----------------------------------
echo "=== Building free-software browser image (latest Alpine packages) ==="
IMAGE_DIR="$STAGING/image"
"$BROMURE" init-foss-image --output "$IMAGE_DIR"

BASE_IMG="$IMAGE_DIR/linux-base.img"
KERNEL="$IMAGE_DIR/vmlinuz"
INITRD="$IMAGE_DIR/initrd"
BUILD_INFO="$IMAGE_DIR/build-info.json"
for f in "$BASE_IMG" "$KERNEL" "$INITRD" "$BUILD_INFO"; do
    [ -f "$f" ] || { echo "ERROR: $f missing after build"; exit 1; }
done

# --- 2. Boot-check a clone -----------------------------------------------
# `cp -c` = clonefile(2): instant APFS copy-on-write. The boot dirties the
# clone (logs, state); the original stays byte-identical to what gets
# checksummed + uploaded below. The kernel/initrd are read-only inputs.
echo "=== Boot-checking the image (on a disposable clone) ==="
VERIFY_IMG="$STAGING/verify.img"
cp -c "$BASE_IMG" "$VERIFY_IMG"
"$BROMURE" verify-image --disk "$VERIFY_IMG" --kernel "$KERNEL" --initrd "$INITRD" --timeout 300
rm -f "$VERIFY_IMG"

# --- 3. Compress + upload the artifacts -----------------------------------
echo "=== Compressing artifacts ==="
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
PREFIX="browser-images/$UUID"

DISK_RAW_BYTES=$(stat -f%z "$BASE_IMG")
DISK_GZ="$STAGING/base.img.gz"
gz_compress "$BASE_IMG" "$DISK_GZ"
DISK_GZ_BYTES=$(stat -f%z "$DISK_GZ")
DISK_SHA256=$(sha256_of "$DISK_GZ")

KERNEL_RAW_BYTES=$(stat -f%z "$KERNEL")
KERNEL_GZ="$STAGING/vmlinuz.gz"
gz_compress "$KERNEL" "$KERNEL_GZ"
KERNEL_GZ_BYTES=$(stat -f%z "$KERNEL_GZ")
KERNEL_SHA256=$(sha256_of "$KERNEL_GZ")

INITRD_RAW_BYTES=$(stat -f%z "$INITRD")
INITRD_GZ="$STAGING/initrd.gz"
gz_compress "$INITRD" "$INITRD_GZ"
INITRD_GZ_BYTES=$(stat -f%z "$INITRD_GZ")
INITRD_SHA256=$(sha256_of "$INITRD_GZ")

echo "image uuid:   $UUID"
echo "disk:         $DISK_GZ_BYTES bytes gz (from $DISK_RAW_BYTES raw) sha256=$DISK_SHA256"
echo "vmlinuz:      $KERNEL_GZ_BYTES bytes gz (from $KERNEL_RAW_BYTES raw) sha256=$KERNEL_SHA256"
echo "initrd:       $INITRD_GZ_BYTES bytes gz (from $INITRD_RAW_BYTES raw) sha256=$INITRD_SHA256"

if enabled "$DRY_RUN"; then
    echo "=== DRY_RUN — stopping before any upload ==="
    exit 0
fi

echo "=== Uploading artifacts ($PREFIX/) ==="
put "$DISK_GZ"   "$PREFIX/base.img.gz" "application/gzip"
put "$KERNEL_GZ" "$PREFIX/vmlinuz.gz"  "application/gzip"
put "$INITRD_GZ" "$PREFIX/initrd.gz"   "application/gzip"

# --- 4. Download the previous catalog ------------------------------------
# Needed only to learn which build to retire in step 8. A 404 (first ever
# publish) is fine.
echo "=== Fetching previous browser img-catalog.json ==="
PREV_CATALOG="$STAGING/img-catalog.prev.json"
PREV_UUID=""
if curl -fsSL "$DO_SPACES_PUBLIC_BASE/browser-images/img-catalog.json" -o "$PREV_CATALOG"; then
    PREV_UUID=$(node tools/make-img-catalog.mjs --print-image-uuid "$PREV_CATALOG")
    echo "previous image uuid: ${PREV_UUID:-<none>}"
else
    echo "no previous catalog (first publish?)"
fi

# --- 5. Generate the new catalog ------------------------------------------
echo "=== Generating img-catalog.json ==="
NEW_CATALOG="$STAGING/img-catalog.json"
node tools/make-img-catalog.mjs \
    --baseline "Sources/SandboxEngine/Resources/browser-img-catalog.json" \
    --build-info "$BUILD_INFO" \
    --uuid "$UUID" \
    --disk-key "$PREFIX/base.img.gz" \
    --sha256 "$DISK_SHA256" \
    --compressed-bytes "$DISK_GZ_BYTES" \
    --uncompressed-bytes "$DISK_RAW_BYTES" \
    --boot "name=vmlinuz,path=$PREFIX/vmlinuz.gz,sha256=$KERNEL_SHA256,compressedBytes=$KERNEL_GZ_BYTES,uncompressedBytes=$KERNEL_RAW_BYTES" \
    --boot "name=initrd,path=$PREFIX/initrd.gz,sha256=$INITRD_SHA256,compressedBytes=$INITRD_GZ_BYTES,uncompressedBytes=$INITRD_RAW_BYTES" \
    --payload-magic "bromure-browser-img-catalog-v1" \
    --out "$NEW_CATALOG"

# --- 6. Upload the catalog (1s cache expiry) ------------------------------
# The 1s TTL is what makes "always download the latest catalog first"
# meaningful for clients — a weekly publish is visible immediately.
echo "=== Uploading img-catalog.json (1s CDN TTL) ==="
put "$NEW_CATALOG" "browser-images/img-catalog.json" "application/json" "public, max-age=1, must-revalidate"

# --- 7. Smoke-test ---------------------------------------------------------
# Every artifact must be confirmed live BEFORE the old build is deleted,
# or a bad publish would leave new installers with nothing.
echo "=== Smoke-testing published catalog + artifacts ==="

catalog_uuid() {  # url → prints the catalog's image uuid, or nothing
    curl -fsSL -H 'Cache-Control: no-cache' "$1" 2>/dev/null \
        | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).image.uuid)}catch{}})' \
        || true
}

# 7a. Origin first (straight to Spaces, no CDN in the way): proves the
# uploads themselves landed. Fails fast — nothing here is eventually
# consistent enough to warrant retries.
ORIGIN_BASE="https://${DO_SPACES_BUCKET}.${DO_SPACES_ENDPOINT#https://}"
ORIGIN_UUID=$(catalog_uuid "$ORIGIN_BASE/browser-images/img-catalog.json")
[ "$ORIGIN_UUID" = "$UUID" ] \
    || { echo "ERROR: origin doesn't serve the new catalog (got '${ORIGIN_UUID:-<empty>}')"; exit 1; }
for key in "$PREFIX/base.img.gz" "$PREFIX/vmlinuz.gz" "$PREFIX/initrd.gz"; do
    curl -fsSIL "$ORIGIN_BASE/$key" >/dev/null \
        || { echo "ERROR: artifact not reachable at origin ($ORIGIN_BASE/$key)"; exit 1; }
done
echo "origin OK ($ORIGIN_BASE)."

# 7b. Public CDN propagation: this is what real clients fetch, and the
# edge (Cloudflare) can keep serving the previous catalog for a while
# despite the 1s max-age. Poll for up to an hour — the previous build is
# only deleted after this passes, so clients stay fully served while we
# wait.
CATALOG_URL="$DO_SPACES_PUBLIC_BASE/browser-images/img-catalog.json"
OK=""
CDN_ATTEMPTS=120   # × 30s = 1 hour
for i in $(seq 1 "$CDN_ATTEMPTS"); do
    LIVE_UUID=$(catalog_uuid "$CATALOG_URL")
    if [ "$LIVE_UUID" = "$UUID" ]; then OK=1; break; fi
    echo "  CDN not propagated yet (got '${LIVE_UUID:-<empty>}'), attempt $i/$CDN_ATTEMPTS — retrying in 30s…"
    sleep 30
done
[ -n "$OK" ] || { echo "ERROR: CDN still serves the old catalog after 1 hour"; exit 1; }
for key in "$PREFIX/base.img.gz" "$PREFIX/vmlinuz.gz" "$PREFIX/initrd.gz"; do
    curl -fsSIL "$DO_SPACES_PUBLIC_BASE/$key" >/dev/null \
        || { echo "ERROR: published artifact not reachable at $key"; exit 1; }
done
echo "smoke-test passed."

# --- 8. Retire the previous build -----------------------------------------
if enabled "$KEEP_PREVIOUS"; then
    echo "=== KEEP_PREVIOUS set — leaving ${PREV_UUID:-<none>} in place ==="
elif [ -n "$PREV_UUID" ] && [ "$PREV_UUID" != "$UUID" ]; then
    echo "=== Deleting previous build (browser-images/$PREV_UUID/) ==="
    node tools/spaces-delete.mjs --prefix "browser-images/$PREV_UUID/"
else
    echo "=== No previous build to delete ==="
fi

echo ""
echo "=== Done ==="
echo "Catalog: $DO_SPACES_PUBLIC_BASE/browser-images/img-catalog.json"
echo "Disk:    $DO_SPACES_PUBLIC_BASE/$PREFIX/base.img.gz"
