#!/usr/bin/env bash
#
# publish-image-amd64.sh — the amd64 counterpart of publish-image.sh: the
# free-software Firecracker image a Linux server's `bromure-ac image
# install` downloads. Prepared, not wired into Jenkins.
#
# A DRY RUN unless --push is given: it bakes (or takes --image-dir),
# compresses, checksums and writes an UNSIGNED preview catalog, then prints
# what it would upload and delete. Nothing leaves this machine.
#
# With --push (and the publish env, as publish-image.sh's), under
# $DO_SPACES_PUBLIC_BASE:
#
#   images/<major>/amd64/img-catalog.json   ← the amd64 manifest (1s CDN TTL),
#                                              signed with the same key as
#                                              the arm64 one, magic
#                                              bromure-img-catalog-amd64-v1
#                                              (ImageDistribution.agentCodingAmd64)
#   images/<major>/amd64/<uuid>/base.img.gz ← the compressed disk
#
# Only the disk is published: a client's postinstall boot (the Alpine
# netboot) extracts the kernel and initrd from it. The steps come verbatim
# from Sources/AgentCoding/Resources/img-catalog.json, as arm64's.
#
# Usage:
#   scripts/publish-image-amd64.sh <path-to-linux-bromure-ac> [--image-dir <dir>] [--out <dir>] [--push]
#
#   --image-dir  an image already baked with --no-agent-clis (base.img,
#                base.version): skips the bake
#   --out        keep the artifacts and preview catalog there (default: a
#                temp dir, removed at exit)
#   --push       upload, retire the previous image (unless KEEP_PREVIOUS=1)
set -euo pipefail

AC="${1:-}"
if [ -z "$AC" ] || [ ! -x "$AC" ]; then
    echo "usage: $0 <path-to-linux-bromure-ac> [--image-dir <dir>] [--out <dir>] [--push]" >&2
    exit 2
fi
AC="$(cd "$(dirname "$AC")" && pwd)/$(basename "$AC")"
shift
PUSH=0
IMAGE_DIR=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=1 ;;
        --image-dir) IMAGE_DIR="$(cd "$2" && pwd)"; shift ;;
        --out) mkdir -p "$2"; OUT="$(cd "$2" && pwd)"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

enabled() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac }
KEEP_PREVIOUS="${KEEP_PREVIOUS:-0}"
if [ "$PUSH" = 1 ]; then
    : "${DO_SPACES_KEY:?}" "${DO_SPACES_SECRET:?}" "${DO_SPACES_ENDPOINT:?}"
    : "${DO_SPACES_REGION:?}" "${DO_SPACES_BUCKET:?}" "${DO_SPACES_PUBLIC_BASE:?}"
    # Clients refuse an unsigned production catalog.
    : "${SPARKLE_PRIVATE_KEY:?}"
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
[ -n "$OUT" ] || OUT="$STAGING/out"
mkdir -p "$OUT"

# --- 1. The free-software image ------------------------------------------
if [ -z "$IMAGE_DIR" ]; then
    echo "=== Baking the free-software amd64 image (no agent CLIs) ==="
    IMAGE_DIR="$STAGING/image"
    # An empty config home: never a customize script from this user's defaults.
    mkdir -p "$STAGING/config"
    XDG_CONFIG_HOME="$STAGING/config" "$AC" image bake --out "$IMAGE_DIR" --no-agent-clis \
        --vm-setup Sources/AgentCoding/Resources/vm-setup
fi
BASE_IMG="$IMAGE_DIR/base.img"
[ -f "$BASE_IMG" ] && [ -f "$IMAGE_DIR/base.version" ] || { echo "ERROR: no base.img/base.version in $IMAGE_DIR"; exit 1; }
if ! python3 -I -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("appliedStepUUIDs",[])==[] else 1)' "$IMAGE_DIR/image-state.json" 2>/dev/null; then
    echo "ERROR: $IMAGE_DIR's image has catalog steps applied (bake it with --no-agent-clis): it must be free software only"
    exit 1
fi

# --- 2. Compress, checksum ------------------------------------------------
echo "=== Compressing image ==="
UNCOMPRESSED_BYTES=$(stat -c%s "$BASE_IMG")
GZ="$OUT/base.img.gz"
if command -v pigz >/dev/null 2>&1; then pigz -9 -c "$BASE_IMG" > "$GZ"; else gzip -9 -c "$BASE_IMG" > "$GZ"; fi
COMPRESSED_BYTES=$(stat -c%s "$GZ")
SHA256=$(sha256sum "$GZ" | awk '{print $1}')
UUID=$(cat /proc/sys/kernel/random/uuid)
STAMP=$(tr -d '[:space:]' < "$IMAGE_DIR/base.version")
IMAGE_MAJOR="${STAMP%%.*}"
[ -n "$IMAGE_MAJOR" ] || { echo "ERROR: empty base.version"; exit 1; }
DESCRIPTION="$(sed -n 's/^ *public static let imageDescription = "\(.*\)"$/\1/p' Sources/AgentCoding/UbuntuImageManager.swift) (amd64)"
CHANNEL="images/$IMAGE_MAJOR/amd64"
DISK_KEY="$CHANNEL/$UUID/base.img.gz"
BUILD_INFO="$OUT/build-info.json"
python3 -I -c 'import json,sys,datetime
json.dump({"version": sys.argv[1], "description": sys.argv[2], "arch": "amd64",
           "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
          open(sys.argv[3], "w"), indent=2, sort_keys=True)' "$IMAGE_MAJOR" "$DESCRIPTION" "$BUILD_INFO"
echo "image:   $STAMP ($DESCRIPTION), $UNCOMPRESSED_BYTES bytes, $COMPRESSED_BYTES compressed, sha256 $SHA256"
echo "channel: $CHANNEL"

# --- 3. The catalog -------------------------------------------------------
CATALOG="$OUT/img-catalog.json"
SIGN_ARGS=()
[ "$PUSH" = 1 ] || SIGN_ARGS=(--allow-unsigned)
node tools/make-img-catalog.mjs \
    --baseline "Sources/AgentCoding/Resources/img-catalog.json" \
    --build-info "$BUILD_INFO" \
    --uuid "$UUID" \
    --disk-key "$DISK_KEY" \
    --sha256 "$SHA256" \
    --compressed-bytes "$COMPRESSED_BYTES" \
    --uncompressed-bytes "$UNCOMPRESSED_BYTES" \
    --payload-magic bromure-img-catalog-amd64-v1 \
    "${SIGN_ARGS[@]}" \
    --out "$CATALOG"

if [ "$PUSH" != 1 ]; then
    echo ""
    echo "=== DRY RUN: nothing uploaded. With --push this would: ==="
    echo "  upload $GZ -> $DISK_KEY"
    echo "  upload $CATALOG (signed) -> $CHANNEL/img-catalog.json (Cache-Control: public, max-age=1, must-revalidate)"
    echo "  smoke-test the origin and the CDN, then retire the previous image under $CHANNEL/<previous uuid>/$(enabled "$KEEP_PREVIOUS" && echo ' (KEEP_PREVIOUS: kept)')"
    echo "Artifacts and the unsigned preview catalog: $OUT"
    exit 0
fi

put() { node tools/spaces-put.mjs "$1" "$2" "${3:-}" "${4:-}"; }

# --- 4. Upload the disk, then the catalog ---------------------------------
echo "=== Uploading image ==="
put "$GZ" "$DISK_KEY" "application/gzip"
PREV_CATALOG="$STAGING/img-catalog.prev.json"
PREV_UUID=""
if curl -fsSL "$DO_SPACES_PUBLIC_BASE/$CHANNEL/img-catalog.json" -o "$PREV_CATALOG"; then
    PREV_UUID=$(node tools/make-img-catalog.mjs --print-image-uuid "$PREV_CATALOG")
fi
echo "=== Uploading img-catalog.json (1s CDN TTL) ==="
put "$CATALOG" "$CHANNEL/img-catalog.json" "application/json" "public, max-age=1, must-revalidate"

# --- 5. Smoke-test before retiring anything --------------------------------
catalog_uuid() {
    curl -fsSL -H 'Cache-Control: no-cache' "$1" 2>/dev/null \
        | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).image.uuid)}catch{}})' \
        || true
}
ORIGIN_BASE="https://${DO_SPACES_BUCKET}.${DO_SPACES_ENDPOINT#https://}"
[ "$(catalog_uuid "$ORIGIN_BASE/$CHANNEL/img-catalog.json")" = "$UUID" ] || { echo "ERROR: origin doesn't serve the new catalog"; exit 1; }
curl -fsSIL "$ORIGIN_BASE/$DISK_KEY" >/dev/null || { echo "ERROR: disk not reachable at origin"; exit 1; }
OK=""
for i in $(seq 1 120); do
    [ "$(catalog_uuid "$DO_SPACES_PUBLIC_BASE/$CHANNEL/img-catalog.json")" = "$UUID" ] && { OK=1; break; }
    echo "  CDN not propagated yet, attempt $i/120 — retrying in 30s…"
    sleep 30
done
[ -n "$OK" ] || { echo "ERROR: CDN still serves the old catalog after 1 hour"; exit 1; }
curl -fsSIL "$DO_SPACES_PUBLIC_BASE/$DISK_KEY" >/dev/null || { echo "ERROR: published disk not reachable"; exit 1; }

# --- 6. Retire the previous image ------------------------------------------
if enabled "$KEEP_PREVIOUS"; then
    echo "=== KEEP_PREVIOUS set — leaving ${PREV_UUID:-<none>} in place ==="
elif [ -n "$PREV_UUID" ] && [ "$PREV_UUID" != "$UUID" ]; then
    node tools/spaces-delete.mjs --prefix "$CHANNEL/$PREV_UUID/"
fi
echo "Catalog: $DO_SPACES_PUBLIC_BASE/$CHANNEL/img-catalog.json"
