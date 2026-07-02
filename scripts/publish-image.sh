#!/usr/bin/env bash
#
# publish-image.sh — build the free-software base image and publish it to
# the DigitalOcean Space that Bromure Agentic Coding downloads from at
# install time. Jenkins runs this weekly (Jenkinsfile.image) so new
# installations always start from an image with current Ubuntu packages.
#
# Publishes, under https://dl.bromure.io/ (the `bromure-dl` bucket):
#
#   images/img-catalog.json          ← the live image manifest (1s CDN TTL)
#   images/<uuid>/base.img.gz        ← the compressed prebuilt disk image
#
# <uuid> is random per build. The catalog's postinstall steps come verbatim
# from Sources/AgentCoding/Resources/img-catalog.json (the canonical
# source) — that's where the non-free software (Claude Code, Codex, Grok,
# gcloud) is declared, since the published image must contain free
# software only.
#
# Sequence (mirrors the design):
#   1. Build the image with the latest Ubuntu packages
#      (bromure-ac init-foss-image — no agents, no Apple fonts).
#   2. Boot-check an APFS CLONE of the image (bromure-ac verify-image):
#      the disk must reach the serial login prompt, but the published
#      artifact stays pristine — booting writes machine-id/journal.
#   3. Compress + upload the image under images/<uuid>/.
#   4. Download the previous img-catalog.json (for the retired uuid).
#   5. Generate the new img-catalog.json.
#   6. Upload it with a 1-second cache expiry.
#   7. Smoke-test the published catalog + image from the CDN.
#   8. Delete the previous image objects.
#
# Usage:
#   ./scripts/publish-image.sh <path-to-bromure-ac>
#
# <path-to-bromure-ac> is a PRE-BUILT bromure-ac binary, signed with the
# virtualization entitlement — i.e. the one inside the app bundle
# `./build.sh bromure-ac` produces. This script deliberately does NOT
# build the binary itself (build.sh/package.sh own that); Jenkinsfile.image
# runs build.sh first and passes the path in.
#
# Required env (Jenkins injects the secrets; the rest come from
# Jenkinsfile.image):
#   DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_REGION
#   DO_SPACES_BUCKET DO_SPACES_PUBLIC_BASE
# Optional:
#   DRY_RUN        (1 = build + verify + compress, but skip every upload/delete)
#   KEEP_PREVIOUS  (1 = don't delete the previous image after publishing)
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

# The image build + boot check run Virtualization.framework, which needs
# the com.apple.security.virtualization entitlement on the signed binary
# (build.sh applies it). Warn early instead of failing 10 minutes in.
if ! codesign -d --entitlements - "$AC" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    echo "WARNING: $AC doesn't appear to carry the virtualization entitlement — the VM steps will likely fail." >&2
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

# --- 1. Build the free-software image -----------------------------------
echo "=== Building free-software base image (latest Ubuntu packages) ==="
IMAGE_DIR="$STAGING/image"
"$AC" init-foss-image --output "$IMAGE_DIR"

BASE_IMG="$IMAGE_DIR/base.img"
BUILD_INFO="$IMAGE_DIR/build-info.json"
[ -f "$BASE_IMG" ] || { echo "ERROR: $BASE_IMG missing after build"; exit 1; }
[ -f "$BUILD_INFO" ] || { echo "ERROR: $BUILD_INFO missing after build"; exit 1; }

# --- 2. Boot-check a clone -----------------------------------------------
# `cp -c` = clonefile(2): instant APFS copy-on-write. The boot dirties the
# clone (journal, machine-id); the original stays byte-identical to what
# gets checksummed + uploaded below.
echo "=== Boot-checking the image (on a disposable clone) ==="
VERIFY_IMG="$STAGING/verify.img"
cp -c "$BASE_IMG" "$VERIFY_IMG"
"$AC" verify-image --disk "$VERIFY_IMG" --timeout 300
rm -f "$VERIFY_IMG"

# --- 3. Compress + upload the image --------------------------------------
echo "=== Compressing image ==="
UNCOMPRESSED_BYTES=$(stat -f%z "$BASE_IMG")
GZ="$STAGING/base.img.gz"
if command -v pigz >/dev/null 2>&1; then
    pigz -9 -c "$BASE_IMG" > "$GZ"
else
    gzip -9 -c "$BASE_IMG" > "$GZ"
fi
COMPRESSED_BYTES=$(stat -f%z "$GZ")
SHA256=$(shasum -a 256 "$GZ" | awk '{print $1}')
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
DISK_KEY="images/$UUID/base.img.gz"
echo "image uuid:   $UUID"
echo "compressed:   $COMPRESSED_BYTES bytes (from $UNCOMPRESSED_BYTES logical)"
echo "sha256:       $SHA256"

if enabled "$DRY_RUN"; then
    echo "=== DRY_RUN — stopping before any upload ==="
    exit 0
fi

echo "=== Uploading image ($DISK_KEY) ==="
put "$GZ" "$DISK_KEY" "application/gzip"

# --- 4. Download the previous catalog ------------------------------------
# Needed only to learn which build to retire in step 8. A 404 (first ever
# publish) is fine.
echo "=== Fetching previous img-catalog.json ==="
PREV_CATALOG="$STAGING/img-catalog.prev.json"
PREV_UUID=""
if curl -fsSL "$DO_SPACES_PUBLIC_BASE/images/img-catalog.json" -o "$PREV_CATALOG"; then
    PREV_UUID=$(node tools/make-img-catalog.mjs --print-image-uuid "$PREV_CATALOG")
    echo "previous image uuid: ${PREV_UUID:-<none>}"
else
    echo "no previous catalog (first publish?)"
fi

# --- 5. Generate the new catalog ------------------------------------------
echo "=== Generating img-catalog.json ==="
NEW_CATALOG="$STAGING/img-catalog.json"
node tools/make-img-catalog.mjs \
    --baseline "Sources/AgentCoding/Resources/img-catalog.json" \
    --build-info "$BUILD_INFO" \
    --uuid "$UUID" \
    --disk-key "$DISK_KEY" \
    --sha256 "$SHA256" \
    --compressed-bytes "$COMPRESSED_BYTES" \
    --uncompressed-bytes "$UNCOMPRESSED_BYTES" \
    --out "$NEW_CATALOG"

# --- 6. Upload the catalog (1s cache expiry) ------------------------------
# The 1s TTL is what makes "always download the latest catalog first"
# meaningful for clients — a weekly publish is visible immediately.
echo "=== Uploading img-catalog.json (1s CDN TTL) ==="
put "$NEW_CATALOG" "images/img-catalog.json" "application/json" "public, max-age=1, must-revalidate"

# --- 7. Smoke-test ---------------------------------------------------------
# The image download must be confirmed live BEFORE the old one is deleted,
# or a bad publish would leave millions of installers with nothing.
echo "=== Smoke-testing published catalog + image ==="

catalog_uuid() {  # url → prints the catalog's image uuid, or nothing
    curl -fsSL -H 'Cache-Control: no-cache' "$1" 2>/dev/null \
        | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).image.uuid)}catch{}})' \
        || true
}

# 7a. Origin first (straight to Spaces, no CDN in the way): proves the
# uploads themselves landed. Fails fast — nothing here is eventually
# consistent enough to warrant retries.
ORIGIN_BASE="https://${DO_SPACES_BUCKET}.${DO_SPACES_ENDPOINT#https://}"
ORIGIN_UUID=$(catalog_uuid "$ORIGIN_BASE/images/img-catalog.json")
[ "$ORIGIN_UUID" = "$UUID" ] \
    || { echo "ERROR: origin doesn't serve the new catalog (got '${ORIGIN_UUID:-<empty>}')"; exit 1; }
curl -fsSIL "$ORIGIN_BASE/$DISK_KEY" >/dev/null \
    || { echo "ERROR: image not reachable at origin ($ORIGIN_BASE/$DISK_KEY)"; exit 1; }
echo "origin OK ($ORIGIN_BASE)."

# 7b. Public CDN propagation: this is what real clients fetch, and the
# edge (Cloudflare) can keep serving the previous catalog for a while
# despite the 1s max-age. Poll for up to an hour — the previous image is
# only deleted after this passes, so clients stay fully served while we
# wait. If this regularly takes long, a Cloudflare cache rule bypassing
# the edge cache for images/img-catalog.json is the real fix.
CATALOG_URL="$DO_SPACES_PUBLIC_BASE/images/img-catalog.json"
OK=""
CDN_ATTEMPTS=120   # × 30s = 1 hour
for i in $(seq 1 "$CDN_ATTEMPTS"); do
    LIVE_UUID=$(catalog_uuid "$CATALOG_URL")
    if [ "$LIVE_UUID" = "$UUID" ]; then OK=1; break; fi
    echo "  CDN not propagated yet (got '${LIVE_UUID:-<empty>}'), attempt $i/$CDN_ATTEMPTS — retrying in 30s…"
    sleep 30
done
[ -n "$OK" ] || { echo "ERROR: CDN still serves the old catalog after 1 hour"; exit 1; }
curl -fsSIL "$DO_SPACES_PUBLIC_BASE/$DISK_KEY" >/dev/null \
    || { echo "ERROR: published image not reachable at $DISK_KEY"; exit 1; }
echo "smoke-test passed."

# --- 8. Retire the previous image -----------------------------------------
if enabled "$KEEP_PREVIOUS"; then
    echo "=== KEEP_PREVIOUS set — leaving ${PREV_UUID:-<none>} in place ==="
elif [ -n "$PREV_UUID" ] && [ "$PREV_UUID" != "$UUID" ]; then
    echo "=== Deleting previous image (images/$PREV_UUID/) ==="
    node tools/spaces-delete.mjs --prefix "images/$PREV_UUID/"
else
    echo "=== No previous image to delete ==="
fi

echo ""
echo "=== Done ==="
echo "Catalog: $DO_SPACES_PUBLIC_BASE/images/img-catalog.json"
echo "Image:   $DO_SPACES_PUBLIC_BASE/$DISK_KEY"
