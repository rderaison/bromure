#!/usr/bin/env bash
#
# fetch-pii-model.sh — obtain the Rampart PII detector model that ships inside
# Bromure Agentic Coding (Contents/Resources/pii-rampart/), pinned and checked.
#
# Rampart (github.com/nationaldesignstudio/rampart) is National Design Studio's
# on-device PII token classifier: MiniLM-L6, 4-bit ONNX, ~15 MB, CC BY 4.0.
# PIIDetector loads it from the app bundle (falling back to Application
# Support), so PII protection works offline from the first launch.
#
# Downloaded once from Hugging Face at a fixed revision into a cache; every
# file is verified against its SHA-256 (fresh download or cache) so a
# substituted artifact fails the build. Update the revision and hashes together.
#
# Usage:
#   scripts/fetch-pii-model.sh [DEST_DIR]
#     DEST_DIR — optional directory to copy model.onnx, vocab.txt and
#                config.json into (e.g. .../Contents/Resources/pii-rampart)
#   Prints the cache directory on stdout.
set -euo pipefail

REV="b1993e4e68b082835b80ffc65acc03325ea2e501"
BASE="https://huggingface.co/nationaldesignstudio/rampart/resolve/$REV"

# local name | path in the repo | SHA-256
FILES="model.onnx|onnx/model_q4.onnx|9f27d24949b0581701071ea5ef522d77ccd3f50c525cc91eac4d265b0fc2afe5
vocab.txt|vocab.txt|0fbe6b50061feabb9be68af471e9aa6df07a4bc428bdca4b0eff1fcd3612dee5
config.json|config.json|003b84bbcd489f5e782fe5cad8f3249c3653ec880089abb1ccc398a0d895e3e6"

CACHE_DIR="${BROMURE_PII_CACHE:-$HOME/Library/Caches/io.bromure.build/pii-rampart}/$REV"
mkdir -p "$CACHE_DIR"

while IFS='|' read -r name remote sha; do
    cached="$CACHE_DIR/$name"
    if [ ! -f "$cached" ] || [ "$(shasum -a 256 "$cached" | awk '{print $1}')" != "$sha" ]; then
        echo "fetch-pii-model: downloading ${remote}…" >&2
        curl -fsSL "$BASE/$remote" -o "$cached.part"
        got="$(shasum -a 256 "$cached.part" | awk '{print $1}')"
        if [ "$got" != "$sha" ]; then
            echo "fetch-pii-model: SHA-256 mismatch for $remote" >&2
            echo "  got  $got" >&2
            echo "  want $sha" >&2
            rm -f "$cached.part"
            exit 1
        fi
        mv "$cached.part" "$cached"
    fi
done <<< "$FILES"

if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    mkdir -p "$1"
    while IFS='|' read -r name _ _; do
        cp "$CACHE_DIR/$name" "$1/$name"
    done <<< "$FILES"
fi
echo "$CACHE_DIR"
