#!/usr/bin/env bash
#
# Regenerate the fully-pinned, hash-locked engine requirements for the local
# MLX inference engine (vllm-mlx + deps). Run this whenever the engine deps
# change (e.g. a new vllm-mlx wheel is published). The output is shipped in the
# app bundle and gives wide, deterministic distribution: every user installs
# exactly these artifacts (verified by hash) or the install fails.
#
# Usage:
#   scripts/lock-engine-requirements.sh           # lock the currently-installed venv
#   scripts/lock-engine-requirements.sh --from-index   # resolve fresh from vllm-mlx
#
# Requires `uv` (the bundled one under the built app, or one on PATH).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$SCRIPT_DIR/Sources/AgentCoding/Resources"
IN_FILE="$RES_DIR/engine-requirements.in"
OUT_FILE="$RES_DIR/engine-requirements.txt"
ENGINE="$HOME/Library/Application Support/BromureAC/engine"
FIND_LINKS="--find-links https://dl.bromure.io/mlx/find-links.html"
PYVER="3.12"

# Resolve uv: prefer the bundled binary, then PATH.
UV="$(find "$SCRIPT_DIR/.build" -name uv -path '*Resources/bin*' 2>/dev/null | head -1 || true)"
[ -z "$UV" ] && UV="$(command -v uv || true)"
[ -z "$UV" ] && { echo "error: uv not found (build the app or install uv)." >&2; exit 1; }
echo "Using uv: $UV ($("$UV" --version))"

mode="${1:---from-venv}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ "$mode" = "--from-index" ]; then
    # Resolve the whole tree fresh from just the top-level package.
    printf '%s\nvllm-mlx\n' "$FIND_LINKS" > "$TMP/in"
else
    # Reproduce exactly what's installed in the provisioned venv.
    [ -x "$ENGINE/bin/python" ] || { echo "error: engine venv not provisioned at $ENGINE." >&2; exit 1; }
    { echo "$FIND_LINKS"; "$UV" pip freeze --python "$ENGINE/bin/python" | sort; } > "$TMP/in"
fi
cp "$TMP/in" "$IN_FILE"

echo "Compiling hash-locked requirements (downloads/validates wheels)…"
"$UV" pip compile "$TMP/in" \
    --generate-hashes --prerelease allow --python-version "$PYVER" \
    --no-header --no-annotate \
    --output-file "$TMP/body"

{
    echo "# Bromure local MLX inference engine — fully pinned, hash-locked."
    echo "# Generated with: uv pip compile --generate-hashes --prerelease allow --python-version $PYVER"
    echo "# Regenerate after changing vllm-mlx: see scripts/lock-engine-requirements.sh"
    echo "# vllm-mlx is not on PyPI; it resolves from the Bromure wheel index below."
    echo "$FIND_LINKS"
    echo ""
    cat "$TMP/body"
} > "$OUT_FILE"

pkgs=$(grep -cE '^[a-zA-Z0-9._-]+==' "$OUT_FILE")
echo "Wrote $OUT_FILE ($pkgs pinned packages)."

echo "Validating with a hash-checked dry-run install…"
"$UV" venv "$TMP/venv" --python "$PYVER" --python-preference only-managed >/dev/null
"$UV" pip install --python "$TMP/venv/bin/python" --prerelease allow --require-hashes \
    -r "$OUT_FILE" --dry-run >/dev/null
echo "OK — lockfile resolves and all hashes verify."
