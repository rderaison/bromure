#!/usr/bin/env bash
#
# test-image-publish-local.sh — full rehearsal of the prebuilt-image
# pipeline WITHOUT touching DigitalOcean Spaces. Builds the image and the
# catalog into a local directory laid out like the CDN, then runs the real
# client install against it over file:// URLs. Use this to validate
# changes to setup.sh / postinstall.sh / the catalog / the download path
# without cycling multi-GB uploads.
#
#   publisher side                        client side
#   ──────────────                        ───────────
#   init-foss-image            →  init --download-only
#   verify-image (boot check, clone)      (BROMURE_IMAGE_CATALOG_BASE
#   gzip + sha256                          points at the staging dir)
#   make-img-catalog.mjs
#
# Asserts, in order:
#   1. The free-software image builds and BOOTS (on an APFS clone).
#   2. The generated img-catalog.json is well-formed.
#   3. A pristine client install downloads the catalog + image over the
#      override base, verifies the checksum, expands it sparse, and runs
#      every postinstall step (Claude/Codex/Grok/gcloud — network needed).
#   4. The installed state is right: version stamp matches the build, and
#      image-state.json records the image uuid + all step uuids.
#   5. The final client image (with postinstall applied) still boots.
#
# Needs ~20 GB free disk and takes ~15-25 min (two image provisions + a
# gzip of the disk). Not run in CI by default — it's the manual/pre-release
# rehearsal for Jenkinsfile.image.
#
# Usage:
#   ./scripts/test-image-publish-local.sh <path-to-bromure-ac>
#
# <path-to-bromure-ac> is a PRE-BUILT bromure-ac binary signed with the
# virtualization entitlement — i.e. the one inside the app bundle
# `./build.sh bromure-ac` produces. This script deliberately does NOT
# build the binary itself (build.sh/package.sh own that).
#
# Optional env:
#   KEEP_STAGING=1  keep the staging dir (path printed) for inspection
set -euo pipefail

# Resolve the binary argument to an absolute path BEFORE cd'ing to the
# repo root — callers pass paths relative to their own cwd.
AC="${1:-}"
if [ -z "$AC" ] || [ ! -x "$AC" ]; then
    echo "usage: $0 <path-to-bromure-ac>" >&2
    echo "  e.g.: ./build.sh bromure-ac && \\" >&2
    echo "        $0 '.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac'" >&2
    exit 2
fi
AC="$(cd "$(dirname "$AC")" && pwd)/$(basename "$AC")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if ! codesign -d --entitlements - "$AC" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    echo "WARNING: $AC doesn't appear to carry the virtualization entitlement — the VM steps will likely fail." >&2
fi

STAGING="$(mktemp -d -t bromure-image-test)"
cleanup() {
    if [ "${KEEP_STAGING:-0}" = "1" ]; then
        echo "KEEP_STAGING=1 — staging left at $STAGING"
    else
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT
echo "staging: $STAGING"

# --- 1. Publisher side: build the free-software image ---------------------
echo "=== [publisher] Building free-software base image ==="
IMAGE_DIR="$STAGING/image"
"$AC" init-foss-image --output "$IMAGE_DIR"
BASE_IMG="$IMAGE_DIR/base.img"
BUILD_INFO="$IMAGE_DIR/build-info.json"

echo "=== [publisher] Boot-checking the image (clone) ==="
cp -c "$BASE_IMG" "$STAGING/verify.img"
"$AC" verify-image --disk "$STAGING/verify.img" --timeout 300
rm -f "$STAGING/verify.img"

# --- 2. Publisher side: fake-CDN layout ------------------------------------
echo "=== [publisher] Compressing + assembling local CDN dir ==="
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
CDN="$STAGING/cdn"
mkdir -p "$CDN/images/$UUID"

UNCOMPRESSED_BYTES=$(stat -f%z "$BASE_IMG")
GZ="$CDN/images/$UUID/base.img.gz"
if command -v pigz >/dev/null 2>&1; then
    pigz -9 -c "$BASE_IMG" > "$GZ"
else
    gzip -9 -c "$BASE_IMG" > "$GZ"
fi
COMPRESSED_BYTES=$(stat -f%z "$GZ")
SHA256=$(shasum -a 256 "$GZ" | awk '{print $1}')

node tools/make-img-catalog.mjs \
    --baseline "Sources/AgentCoding/Resources/img-catalog.json" \
    --build-info "$BUILD_INFO" \
    --uuid "$UUID" \
    --disk-key "images/$UUID/base.img.gz" \
    --sha256 "$SHA256" \
    --compressed-bytes "$COMPRESSED_BYTES" \
    --uncompressed-bytes "$UNCOMPRESSED_BYTES" \
    --out "$CDN/images/img-catalog.json"

# Sanity: the inspect mode must read back the uuid we just wrote.
ROUND_TRIP=$(node tools/make-img-catalog.mjs --print-image-uuid "$CDN/images/img-catalog.json")
[ "$ROUND_TRIP" = "$UUID" ] || { echo "ERROR: catalog round-trip uuid mismatch"; exit 1; }

# --- 3. Client side: real install against the local CDN -------------------
# --download-only: a fallback local build would silently mask a broken
# download path, which is the very thing under test.
echo "=== [client] Installing from the local catalog (download path) ==="
CLIENT="$STAGING/client"
BROMURE_IMAGE_CATALOG_BASE="file://$CDN/" \
    "$AC" init --download-only --storage-dir "$CLIENT"

# --- 4. Assertions ----------------------------------------------------------
echo "=== [client] Checking installed artifacts ==="
for f in base.img efivars.bin base.version image-state.json; do
    [ -e "$CLIENT/$f" ] || { echo "ERROR: missing $CLIENT/$f"; exit 1; }
done

EXPECTED_VERSION=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$BUILD_INFO")
INSTALLED_VERSION=$(tr -d '[:space:]' < "$CLIENT/base.version")
[ "$INSTALLED_VERSION" = "$EXPECTED_VERSION" ] \
    || { echo "ERROR: base.version '$INSTALLED_VERSION' != build '$EXPECTED_VERSION'"; exit 1; }

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
' "$CLIENT/image-state.json" "$UUID" "Sources/AgentCoding/Resources/img-catalog.json"

# The expanded image should be sparse — physical footprint well under the
# 24 GB logical size. Informational (compression/OS variance), not a gate.
PHYS=$(du -k "$CLIENT/base.img" | awk '{print $1}')
echo "client base.img: $((UNCOMPRESSED_BYTES / 1024 / 1024 / 1024)) GB logical, $((PHYS / 1024 / 1024)) GB physical"

# --- 5. Final boot check: image + postinstall still boots ------------------
echo "=== [client] Boot-checking the installed image (clone) ==="
cp -c "$CLIENT/base.img" "$STAGING/verify-client.img"
"$AC" verify-image --disk "$STAGING/verify-client.img" --timeout 300
rm -f "$STAGING/verify-client.img"

echo ""
echo "=== PASS — full publish + install pipeline verified locally ==="
echo "image uuid: $UUID  version: $EXPECTED_VERSION  compressed: $COMPRESSED_BYTES bytes"
