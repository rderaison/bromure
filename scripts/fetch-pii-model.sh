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

# SHA-256 of a file: shasum (macOS, Perl) or sha256sum (coreutils). Checked
# before anything is downloaded.
if command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
else
    echo "fetch-pii-model: neither shasum nor sha256sum is installed" >&2
    exit 1
fi
mkdir -p "$CACHE_DIR"

while IFS='|' read -r name remote sha; do
    cached="$CACHE_DIR/$name"
    if [ ! -f "$cached" ] || [ "$(sha256 "$cached")" != "$sha" ]; then
        echo "fetch-pii-model: downloading ${remote}…" >&2
        # Downloaded into a fresh private directory (mktemp), never through
        # a name someone else could have planted (a symlink at .part in a
        # shared cache), then moved into the cache once it checks out.
        tmp="$(mktemp -d "$CACHE_DIR/.fetch.XXXXXX")"
        curl -fsSL "$BASE/$remote" -o "$tmp/$name"
        got="$(sha256 "$tmp/$name")"
        if [ "$got" != "$sha" ]; then
            echo "fetch-pii-model: SHA-256 mismatch for $remote" >&2
            echo "  got  $got" >&2
            echo "  want $sha" >&2
            rm -rf "$tmp"
            exit 1
        fi
        # A link planted at the name (to a directory, mv would move into it)
        # goes first.
        rm -f "$cached"
        mv -f "$tmp/$name" "$cached"
        rmdir "$tmp"
    fi
done <<< "$FILES"

if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    mkdir -p "$1"
    # Each copy checked where it landed (the cache may be writable by
    # someone else between its check and the copy), copied first into a
    # fresh private directory beside the destination, then moved into place.
    while IFS='|' read -r name _ sha; do
        tmp="$(mktemp -d "$1/.copy.XXXXXX")"
        cp "$CACHE_DIR/$name" "$tmp/$name"
        got="$(sha256 "$tmp/$name")"
        if [ "$got" != "$sha" ]; then
            echo "fetch-pii-model: SHA-256 mismatch for the copy of $name in $1" >&2
            rm -rf "$tmp"
            exit 1
        fi
        rm -f "$1/$name"
        mv -f "$tmp/$name" "$1/$name"
        rmdir "$tmp"
    done <<< "$FILES"
fi
echo "$CACHE_DIR"
