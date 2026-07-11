#!/usr/bin/env bash
#
# test-browser-image-publish-local.sh — full rehearsal of the browser
# prebuilt-image pipeline WITHOUT touching DigitalOcean Spaces. Builds the
# image and the catalog into a local directory laid out like the CDN,
# then runs the real client install against it over file:// URLs. Use
# this to validate changes to setup.sh / postinstall.sh / the catalog /
# the download path without cycling multi-GB uploads.
#
#   publisher side                        client side
#   ──────────────                        ───────────
#   init-foss-image            →  init --download-only
#   verify-image (boot check, clone)      (BROMURE_IMAGE_CATALOG_BASE
#   gzip + sha256 (disk+kernel+initrd)     points at the staging dir)
#   make-img-catalog.mjs
#
# Asserts, in order:
#   1. The free-software image builds (strict kernel-module gate) and
#      BOOTS (on an APFS clone).
#   2. The generated img-catalog.json is well-formed (boot artifacts
#      included).
#   3. A pristine client install downloads the catalog + all three
#      artifacts over the override base, verifies the checksums, expands
#      them, runs the personalisation + font copy + every postinstall
#      step (Cloudflare WARP — network needed).
#   4. The installed state is right: version stamp matches the app
#      constant, and image-state.json records the image uuid + all step
#      uuids.
#   5. The final client image (with postinstall applied) still boots.
#
# Needs ~15 GB free disk and takes ~15-25 min (two image provisions + a
# gzip of the disk). Not run in CI by default — it's the manual/
# pre-release rehearsal for Jenkinsfile.browser-image.
#
# Usage:
#   ./scripts/test-browser-image-publish-local.sh <path-to-bromure>
#
# <path-to-bromure> is a PRE-BUILT bromure binary signed with the
# virtualization entitlement — i.e. the one inside the app bundle
# `./build.sh bromure` produces. This script deliberately does NOT build
# the binary itself (build.sh/package.sh own that).
#
# Optional env:
#   KEEP_STAGING=1  keep the staging dir (path printed) for inspection
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

if ! codesign -d --entitlements - "$BROMURE" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    echo "WARNING: $BROMURE doesn't appear to carry the virtualization entitlement — the VM steps will likely fail." >&2
fi

STAGING="$(mktemp -d -t bromure-browser-image-test)"
cleanup() {
    if [ "${KEEP_STAGING:-0}" = "1" ]; then
        echo "KEEP_STAGING=1 — staging left at $STAGING"
    else
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT
echo "staging: $STAGING"

gz_compress() {  # src dest
    if command -v pigz >/dev/null 2>&1; then
        pigz -9 -c "$1" > "$2"
    else
        gzip -9 -c "$1" > "$2"
    fi
}
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. Publisher side: build the free-software image ---------------------
echo "=== [publisher] Building free-software browser image ==="
IMAGE_DIR="$STAGING/image"
"$BROMURE" init-foss-image --output "$IMAGE_DIR"
BASE_IMG="$IMAGE_DIR/linux-base.img"
KERNEL="$IMAGE_DIR/vmlinuz"
INITRD="$IMAGE_DIR/initrd"
BUILD_INFO="$IMAGE_DIR/build-info.json"

echo "=== [publisher] Boot-checking the image (clone) ==="
cp -c "$BASE_IMG" "$STAGING/verify.img"
"$BROMURE" verify-image --disk "$STAGING/verify.img" --kernel "$KERNEL" --initrd "$INITRD" --timeout 300
rm -f "$STAGING/verify.img"

# --- 2. Publisher side: fake-CDN layout ------------------------------------
echo "=== [publisher] Compressing + assembling local CDN dir ==="
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
CDN="$STAGING/cdn"
mkdir -p "$CDN/browser-images/$UUID"

DISK_RAW_BYTES=$(stat -f%z "$BASE_IMG")
DISK_GZ="$CDN/browser-images/$UUID/base.img.gz"
gz_compress "$BASE_IMG" "$DISK_GZ"
DISK_GZ_BYTES=$(stat -f%z "$DISK_GZ")
DISK_SHA256=$(sha256_of "$DISK_GZ")

KERNEL_RAW_BYTES=$(stat -f%z "$KERNEL")
KERNEL_GZ="$CDN/browser-images/$UUID/vmlinuz.gz"
gz_compress "$KERNEL" "$KERNEL_GZ"
KERNEL_GZ_BYTES=$(stat -f%z "$KERNEL_GZ")
KERNEL_SHA256=$(sha256_of "$KERNEL_GZ")

INITRD_RAW_BYTES=$(stat -f%z "$INITRD")
INITRD_GZ="$CDN/browser-images/$UUID/initrd.gz"
gz_compress "$INITRD" "$INITRD_GZ"
INITRD_GZ_BYTES=$(stat -f%z "$INITRD_GZ")
INITRD_SHA256=$(sha256_of "$INITRD_GZ")

# --allow-unsigned: no signing key locally. The client side skips
# signature verification only because BROMURE_IMAGE_CATALOG_BASE is set —
# production fetches always require a valid signature.
node tools/make-img-catalog.mjs \
    --baseline "Sources/SandboxEngine/Resources/browser-img-catalog.json" \
    --build-info "$BUILD_INFO" \
    --uuid "$UUID" \
    --disk-key "browser-images/$UUID/base.img.gz" \
    --sha256 "$DISK_SHA256" \
    --compressed-bytes "$DISK_GZ_BYTES" \
    --uncompressed-bytes "$DISK_RAW_BYTES" \
    --boot "name=vmlinuz,path=browser-images/$UUID/vmlinuz.gz,sha256=$KERNEL_SHA256,compressedBytes=$KERNEL_GZ_BYTES,uncompressedBytes=$KERNEL_RAW_BYTES" \
    --boot "name=initrd,path=browser-images/$UUID/initrd.gz,sha256=$INITRD_SHA256,compressedBytes=$INITRD_GZ_BYTES,uncompressedBytes=$INITRD_RAW_BYTES" \
    --payload-magic "bromure-browser-img-catalog-v1" \
    --allow-unsigned \
    --out "$CDN/browser-images/img-catalog.json"

# Sanity: the inspect mode must read back the uuid we just wrote, and the
# catalog must carry both boot artifacts.
ROUND_TRIP=$(node tools/make-img-catalog.mjs --print-image-uuid "$CDN/browser-images/img-catalog.json")
[ "$ROUND_TRIP" = "$UUID" ] || { echo "ERROR: catalog round-trip uuid mismatch"; exit 1; }
node -e '
const cat = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const names = (cat.image.boot ?? []).map((f) => f.name).sort();
if (names.join(",") !== "initrd,vmlinuz") {
  console.error(`ERROR: catalog boot artifacts wrong: ${names}`);
  process.exit(1);
}
' "$CDN/browser-images/img-catalog.json"

# --- 3. Client side: real install against the local CDN -------------------
# --download-only: a fallback local build would silently mask a broken
# download path, which is the very thing under test.
echo "=== [client] Installing from the local catalog (download path) ==="
CLIENT="$STAGING/client"
BROMURE_IMAGE_CATALOG_BASE="file://$CDN/" \
    "$BROMURE" init --download-only --storage-dir "$CLIENT"

# --- 4. Assertions ----------------------------------------------------------
echo "=== [client] Checking installed artifacts ==="
for f in linux-base.img vmlinuz initrd image-version image-state.json; do
    [ -e "$CLIENT/$f" ] || { echo "ERROR: missing $CLIENT/$f"; exit 1; }
done

# The stamp is the app's own imageVersion constant (== build-info version
# on the same binary), never the catalog's — see downloadBaseImage.
EXPECTED_VERSION=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$BUILD_INFO")
INSTALLED_VERSION=$(tr -d '[:space:]' < "$CLIENT/image-version")
[ "$INSTALLED_VERSION" = "$EXPECTED_VERSION" ] \
    || { echo "ERROR: image-version '$INSTALLED_VERSION' != build '$EXPECTED_VERSION'"; exit 1; }

node -e '
const fs = require("fs");
const [statePath, expectedUuid, baselinePath] = process.argv.slice(1);
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
if (state.imageUUID !== expectedUuid) {
  console.error(`ERROR: image-state uuid ${state.imageUUID} != ${expectedUuid} (did the download fall back?)`);
  process.exit(1);
}
const applied = new Set(state.appliedStepUUIDs);
const missing = baseline.postinstall.filter((s) => !applied.has(s.uuid));
if (missing.length) {
  console.error("ERROR: postinstall steps not recorded as applied: " +
    missing.map((s) => s.description).join(", "));
  process.exit(1);
}
console.log(`image-state OK: uuid matches, ${baseline.postinstall.length} step(s) applied`);
' "$CLIENT/image-state.json" "$UUID" "Sources/SandboxEngine/Resources/browser-img-catalog.json"

# --- 5. Final boot check: image + postinstall still boots ------------------
echo "=== [client] Boot-checking the installed image (clone) ==="
cp -c "$CLIENT/linux-base.img" "$STAGING/verify-client.img"
"$BROMURE" verify-image --disk "$STAGING/verify-client.img" \
    --kernel "$CLIENT/vmlinuz" --initrd "$CLIENT/initrd" --timeout 300
rm -f "$STAGING/verify-client.img"

echo ""
echo "=== PASS — full browser publish + install pipeline verified locally ==="
echo "image uuid: $UUID  version: $EXPECTED_VERSION  disk gz: $DISK_GZ_BYTES bytes"
