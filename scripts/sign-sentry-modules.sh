#!/usr/bin/env bash
# sign-sentry-modules.sh — sign a sentry module catalog on the machine that
# holds the Sparkle key, for publish-sentry-modules.sh PRESIGNED=1 to upload
# from another (which then never sees the key).
#
# Usage: sign-sentry-modules.sh <ci-build out dir> <private key file>
#   Writes <out dir>/catalog.json and <out dir>/modules/*.ko.sig, then checks
#   them against the app's pinned public key. Refuses a key that doesn't match.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: sign-sentry-modules.sh <ci-build out dir> <private key file>}"
KEY_FILE="${2:?usage: sign-sentry-modules.sh <ci-build out dir> <private key file>}"
# Must match ImageCatalogStore.pinnedPublicKeyBase64 / SUPublicEDKey.
SENTRY_CATALOG_PUBLIC_KEY="${SENTRY_CATALOG_PUBLIC_KEY:-G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8=}"

# The out dir comes from the build container (`docker cp` keeps symlinks):
# a planted link would be signed/published as a module, or written through.
LINK=$(find "$OUT" -type l -print -quit)
[ -z "$LINK" ] || { echo "ERROR: $LINK is a symlink — the out dir must hold real files only"; exit 1; }

HASH=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sourceHash)' "$OUT/manifest.json")
PREVIOUS=()
[ -f "$OUT/previous-catalog.json" ] && PREVIOUS=(--previous "$OUT/previous-catalog.json")

SPARKLE_PRIVATE_KEY="$(tr -d ' \n\r' < "$KEY_FILE")" \
    node tools/make-sentry-catalog.mjs --source-hash "$HASH" --modules "$OUT/modules" \
        ${PREVIOUS[@]+"${PREVIOUS[@]}"} --public-key "$SENTRY_CATALOG_PUBLIC_KEY" --out "$OUT/catalog.json"
# Signed with the wrong key = rejected by every app in the field; catch it here.
# Exit 3 is that (the signatures don't verify against the pinned key): the
# outputs are useless and removed. Any other failure is the verifier's own
# (its message is above) — the outputs are kept to look at.
rc=0
node tools/make-sentry-catalog.mjs --verify "$OUT/catalog.json" --source-hash "$HASH" \
    --modules "$OUT/modules" --public-key "$SENTRY_CATALOG_PUBLIC_KEY" || rc=$?
if [ "$rc" -eq 3 ]; then
    rm -f "$OUT/catalog.json" "$OUT"/modules/*.ko.sig
    echo "ERROR: that key isn't the app's pinned Sparkle key — the signatures don't verify against it; nothing kept"
    exit 1
elif [ "$rc" -ne 0 ]; then
    echo "ERROR: the signed catalog didn't verify (see above); $OUT/catalog.json and the .ko.sig files are kept"
    exit 1
fi
