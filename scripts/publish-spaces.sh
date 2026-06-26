#!/usr/bin/env bash
#
# publish-spaces.sh — build the vllm-mlx engine wheel and populate the
# DigitalOcean Space that the app pulls from at runtime.
#
# Publishes, under https://dl.bromure.io/ (the `bromure-dl` bucket):
#
#   mlx/catalog.json                          ← the live model catalog
#   mlx/simple/vllm-mlx/index.html            ← PEP 503 index
#   mlx/simple/vllm-mlx/vllm_mlx-<ver>-*.whl  ← the prebuilt engine wheel
#
# `EngineProvisioner` installs the engine with
#   uv pip install --extra-index-url https://dl.bromure.io/mlx/simple/ vllm-mlx
# (mlx / mlx-lm resolve from PyPI as vllm-mlx's deps). Models are pulled
# anonymously from Hugging Face — never hosted here — so this stays tiny.
#
# Uploads reuse the same S3 path as release-upload.mjs via tools/spaces-put.mjs.
#
# Required env (Jenkins injects the secrets; the rest come from Jenkinsfile.spaces):
#   DO_SPACES_KEY DO_SPACES_SECRET DO_SPACES_ENDPOINT DO_SPACES_REGION
#   DO_SPACES_BUCKET DO_SPACES_PUBLIC_BASE
# Optional:
#   VLLM_MLX_REPO  (default https://github.com/waybarrios/vllm-mlx)
#   VLLM_MLX_REF   (git tag/sha to pin; default: default branch HEAD)
#   PUBLISH_CATALOG (1 = also upload catalog.json; default 1)
#   PUBLISH_WHEEL   (1 = build + upload the wheel;   default 1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

VLLM_MLX_REPO="${VLLM_MLX_REPO:-https://github.com/waybarrios/vllm-mlx}"
VLLM_MLX_REF="${VLLM_MLX_REF:-}"
PREFIX="mlx"

# Accept "1"/"true"/"yes" from either CLI env or Jenkins booleanParam.
enabled() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac }
PUBLISH_CATALOG="${PUBLISH_CATALOG:-1}"
PUBLISH_WHEEL="${PUBLISH_WHEEL:-1}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

put() {  # local key [contentType]
    node tools/spaces-put.mjs "$1" "$2" "${3:-}"
}

# Ensure uv is available (it builds the wheel and provisions Python).
if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
echo "uv: $(uv --version)"

# --- 1. Catalog ---------------------------------------------------------
if enabled "$PUBLISH_CATALOG"; then
    echo "=== Publishing catalog.json ==="
    # The bundled catalog IS the canonical source — upload it verbatim so
    # the shipped baseline and the remote manifest can never drift.
    put "Sources/AgentCoding/Resources/catalog.json" "$PREFIX/catalog.json" "application/json"
fi

# --- 2. Build + publish the vllm-mlx wheel ------------------------------
if enabled "$PUBLISH_WHEEL"; then
    echo "=== Building vllm-mlx wheel ==="
    SRC="$STAGING/src"
    git clone --depth 1 ${VLLM_MLX_REF:+--branch "$VLLM_MLX_REF"} "$VLLM_MLX_REPO" "$SRC" 2>/dev/null \
        || git clone "$VLLM_MLX_REPO" "$SRC"
    if [ -n "$VLLM_MLX_REF" ]; then ( cd "$SRC" && git checkout "$VLLM_MLX_REF" ); fi
    ( cd "$SRC" && uv build --wheel --out-dir "$STAGING/dist" )

    WHEEL_PATH="$(ls "$STAGING"/dist/*.whl | head -1)"
    WHEEL_FILE="$(basename "$WHEEL_PATH")"
    echo "Built $WHEEL_FILE"

    WHEEL_KEY="$PREFIX/wheels/$WHEEL_FILE"
    WHEEL_URL="${DO_SPACES_PUBLIC_BASE}/$WHEEL_KEY"

    # `--find-links` page: a single HTML file (NOT a directory) listing the
    # wheel by ABSOLUTE URL. DigitalOcean Spaces doesn't serve index.html
    # for a trailing-slash directory request (a PEP 503 `--extra-index-url`
    # would 403), so we point uv at this exact file instead.
    cat > "$STAGING/find-links.html" <<HTML
<!DOCTYPE html>
<html><head><title>Bromure MLX engine wheels</title></head>
<body>
<a href="$WHEEL_URL">$WHEEL_FILE</a><br>
</body></html>
HTML

    echo "=== Publishing wheel + find-links ==="
    put "$WHEEL_PATH"               "$WHEEL_KEY"            "application/zip"
    put "$STAGING/find-links.html"  "$PREFIX/find-links.html" "text/html; charset=utf-8"

    # Smoke-test the exact runtime install path: provision a throwaway venv
    # and install vllm-mlx from the just-published find-links URL (mlx/mlx-lm
    # resolve from PyPI). Fails the build loudly if the wheel isn't
    # installable — the same command EngineProvisioner runs on the user's Mac.
    if enabled "${SMOKE_TEST:-1}"; then
        echo "=== Smoke-test: install from published find-links ==="
        FL_URL="${DO_SPACES_PUBLIC_BASE}/$PREFIX/find-links.html"
        # Allow a few seconds for CDN propagation.
        for i in 1 2 3 4 5; do curl -fsSL "$FL_URL" >/dev/null 2>&1 && break || sleep 5; done
        SMOKE="$STAGING/smoke"
        uv venv "$SMOKE" --python 3.12 --python-preference only-managed
        uv pip install --python "$SMOKE/bin/python" --find-links "$FL_URL" vllm-mlx
        "$SMOKE/bin/python" -c "import vllm_mlx; print('vllm_mlx import OK')"
        echo "Smoke-test passed."
    fi
fi

echo ""
echo "=== Done ==="
echo "Catalog:     ${DO_SPACES_PUBLIC_BASE}/$PREFIX/catalog.json"
echo "Find-links:  ${DO_SPACES_PUBLIC_BASE}/$PREFIX/find-links.html"
