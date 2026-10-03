#!/usr/bin/env bash
# publish-sentry-modules.sh — publish kernel sentry modules built by
# scripts/openshell-guest/sentry/ci-build.sh to the DigitalOcean Space behind
# https://dl.bromure.io (bucket bromure-dl), under:
#
#   sentry/<sourceHash>/catalog.json                          signed, 60 s TTL
#   sentry/<sourceHash>/<kernel>/bromure_sentry-<kernel>-<sha12>.ko   immutable
#   sentry/<sourceHash>/<kernel>/bromure_sentry-<kernel>-<sha12>.txt  build record
#   sentry/<sourceHash>/<kernel>/bromure_sentry-<kernel>-<sha12>.ko.sig
#       the module's own signature (Sparkle key, domain-separated statement)
#
# Additive only: kernels already in the published catalog stay (a rebuilt
# kernel gets a new sha-named object, never an overwrite), and nothing is ever
# deleted — an app release in the field keeps finding every module its source
# was ever built for.
#
# Usage: publish-sentry-modules.sh <ci-build out dir>
#   (the directory `docker cp`'d out of the build container: manifest.json,
#   modules/, and previous-catalog.json when something was already published)
#
# Env: DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_REGION
#      DO_SPACES_BUCKET DO_SPACES_PUBLIC_BASE SPARKLE_PRIVATE_KEY
#      SENTRY_CATALOG_PUBLIC_KEY (default: the app's pinned SUPublicEDKey)
#      DRY_RUN=1 builds + signs the catalog but uploads nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: publish-sentry-modules.sh <ci-build out dir>}"
DRY_RUN="${DRY_RUN:-0}"
enabled() { case "${1:-}" in 1|true|TRUE|yes) return 0;; *) return 1;; esac; }
# Must match ImageCatalogStore.pinnedPublicKeyBase64 / SUPublicEDKey.
SENTRY_CATALOG_PUBLIC_KEY="${SENTRY_CATALOG_PUBLIC_KEY:-G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8=}"

json() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],j);process.stdout.write(Array.isArray(v)?v.join(" "):String(v??""))' "$1" "$2"; }

HASH=$(json "$OUT/manifest.json" sourceHash)
BUILT=$(json "$OUT/manifest.json" built)
FAILED=$(json "$OUT/manifest.json" failed)
echo "source $HASH — built: ${BUILT:-none}; failed: ${FAILED:-none}"

if [ -z "$BUILT" ]; then
    echo "nothing new to publish."
    exit 0
fi

if ! enabled "$DRY_RUN"; then
    : "${DO_SPACES_KEY:?}" "${DO_SPACES_SECRET:?}" "${DO_SPACES_ENDPOINT:?}"
    : "${DO_SPACES_REGION:?}" "${DO_SPACES_BUCKET:?}" "${DO_SPACES_PUBLIC_BASE:?}"
    : "${SPARKLE_PRIVATE_KEY:?}"
fi

CATALOG="$OUT/catalog.json"
PREVIOUS=()
[ -f "$OUT/previous-catalog.json" ] && PREVIOUS=(--previous "$OUT/previous-catalog.json")
SIGN=()
enabled "$DRY_RUN" && [ -z "${SPARKLE_PRIVATE_KEY:-}" ] && SIGN=(--allow-unsigned)
node tools/make-sentry-catalog.mjs --source-hash "$HASH" --modules "$OUT/modules" \
    ${PREVIOUS[@]+"${PREVIOUS[@]}"} --public-key "$SENTRY_CATALOG_PUBLIC_KEY" --out "$CATALOG" ${SIGN[@]+"${SIGN[@]}"}

put() { node tools/spaces-put.mjs "$@"; }
IMMUTABLE="public, max-age=31536000, immutable"

# Modules first, catalog last: a client that sees the new catalog must be able
# to fetch everything it names.
for k in $BUILT; do
    key=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(c.modules.find(m=>m.kernel===process.argv[2]).path)' "$CATALOG" "$k")
    if enabled "$DRY_RUN"; then
        echo "DRY_RUN: would upload $k → $key"
        continue
    fi
    put "$OUT/modules/bromure_sentry-$k.ko" "$key" application/octet-stream "$IMMUTABLE"
    put "$OUT/modules/bromure_sentry-$k.ko.sig" "$key.sig" application/json "$IMMUTABLE"
    [ -f "$OUT/modules/bromure_sentry-$k.txt" ] && \
        put "$OUT/modules/bromure_sentry-$k.txt" "${key%.ko}.txt" "text/plain; charset=utf-8" "$IMMUTABLE"
done

if enabled "$DRY_RUN"; then
    echo "DRY_RUN: would upload the catalog → sentry/$HASH/catalog.json"
    cat "$CATALOG"
    exit 0
fi
put "$CATALOG" "sentry/$HASH/catalog.json" application/json "public, max-age=60, must-revalidate"

# --- Smoke test: origin, then the CDN clients actually use -----------------
SIGNED_AT=$(json "$CATALOG" signature.signedAt)
signed_at_of() { curl -fsSL -H 'Cache-Control: no-cache' "$1" 2>/dev/null \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).signature.signedAt)}catch{}})' || true; }

ORIGIN_BASE="https://${DO_SPACES_BUCKET}.${DO_SPACES_ENDPOINT#https://}"
[ "$(signed_at_of "$ORIGIN_BASE/sentry/$HASH/catalog.json")" = "$SIGNED_AT" ] \
    || { echo "ERROR: origin doesn't serve the new catalog"; exit 1; }

OK=""
for i in $(seq 1 40); do   # × 15 s = 10 min (60 s TTL at the edge)
    [ "$(signed_at_of "$DO_SPACES_PUBLIC_BASE/sentry/$HASH/catalog.json")" = "$SIGNED_AT" ] && { OK=1; break; }
    echo "  CDN not propagated yet, attempt $i/40 — retrying in 15s…"
    sleep 15
done
[ -n "$OK" ] || { echo "ERROR: the CDN still serves the previous catalog after 10 minutes"; exit 1; }

for k in $BUILT; do
    want=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const m=c.modules.find(m=>m.kernel===process.argv[2]);process.stdout.write(m.path+" "+m.sha256)' "$CATALOG" "$k")
    got=$(curl -fsSL "$DO_SPACES_PUBLIC_BASE/${want% *}" | sha256sum | cut -d' ' -f1)
    [ "$got" = "${want#* }" ] || { echo "ERROR: $k from the CDN has sha256 $got, catalog says ${want#* }"; exit 1; }
    curl -fsSL "$DO_SPACES_PUBLIC_BASE/${want% *}.sig" | grep -q "\"sha256\": \"${want#* }\"" \
        || { echo "ERROR: $k's signature file is missing or names another sha256"; exit 1; }
done
echo "published and verified from the CDN: $BUILT"
