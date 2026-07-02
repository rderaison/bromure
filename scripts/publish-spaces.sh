#!/usr/bin/env bash
#
# publish-spaces.sh — publish the model catalog to the DigitalOcean Space
# the app pulls from at runtime.
#
# Publishes, under https://dl.bromure.io/ (the `bromure-dl` bucket):
#
#   mlx/catalog.json   ← the live model catalog
#
# The inference engine is in-process MLX-Swift now, so there is no Python
# wheel to build or host anymore. Models are pulled anonymously from
# Hugging Face — never hosted here — so this stays tiny.
#
# Uploads reuse the same S3 path as release-upload.mjs via tools/spaces-put.mjs.
#
# Required env (Jenkins injects the secrets; the rest come from Jenkinsfile.spaces):
#   DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_REGION
#   DO_SPACES_BUCKET DO_SPACES_PUBLIC_BASE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

PREFIX="mlx"
CATALOG="Sources/AgentCoding/Resources/catalog.json"

# Refuse to publish a manifest the app can't decode — CatalogStore requires
# an integer version plus id/repo on every model, and a malformed upload
# would silently knock every install back to its bundled baseline.
node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (!Number.isInteger(c.version)) throw new Error("version must be an integer");
    if (!Array.isArray(c.models) || c.models.length === 0) throw new Error("models must be a non-empty array");
    for (const m of c.models) {
        if (typeof m.id !== "string" || typeof m.repo !== "string")
            throw new Error(`model missing id/repo: ${JSON.stringify(m).slice(0, 80)}`);
    }
' "$CATALOG"

echo "=== Publishing catalog.json ==="
# The bundled catalog IS the canonical source — upload it verbatim so
# the shipped baseline and the remote manifest can never drift.
node tools/spaces-put.mjs "$CATALOG" "$PREFIX/catalog.json" "application/json"

echo ""
echo "=== Done ==="
echo "Catalog: ${DO_SPACES_PUBLIC_BASE}/$PREFIX/catalog.json"
