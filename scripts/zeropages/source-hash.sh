#!/bin/sh
# Print the bromure_zeropages module's source hash: the identity a prebuilt
# module is published and looked up under
# (https://dl.bromure.io/zeropages/<hash>/catalog.json).
#
# sha256 over Makefile, bromure_zeropages.c, sorted by name, each as
# `name\n<byte length>\n<bytes>` — the sentry's framing
# (scripts/openshell-guest/sentry/source-hash.sh). The image build's
# vm-setup/scripts/fetch-guest-module.py computes the identical value (as will
# the Agentic Coding host store, when it fetches this module); change all or
# none.
#
#   ./source-hash.sh [dir]   (default: the module source in the browser's vm-setup)
set -eu
DIR="${1:-$(cd "$(dirname "$0")/../../Sources/SandboxEngine/Resources/vm-setup/zeropages" && pwd)}"
{
    for f in Makefile bromure_zeropages.c; do
        printf '%s\n%s\n' "$f" "$(wc -c < "$DIR/$f" | tr -d ' ')"
        cat "$DIR/$f"
    done
} | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1
