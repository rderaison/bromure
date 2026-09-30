#!/bin/sh
# Print the sentry module's source hash: the identity a prebuilt module is
# published and looked up under (https://dl.bromure.io/sentry/<hash>/).
#
# A module is only ever loaded by a host whose staged source has the same hash,
# so a build from other source (an older or newer release) is never picked.
#
# sha256 over Makefile, bromure_sentry.c, bromure_sentry.h, sorted by name,
# each as `name\n<byte length>\n<bytes>`. SentryModuleStore.sourceHash(of:) in
# the app computes the identical value; change both or neither.
#
#   ./source-hash.sh [dir]      (default: this script's directory)
set -eu
DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
{
    for f in Makefile bromure_sentry.c bromure_sentry.h; do
        printf '%s\n%s\n' "$f" "$(wc -c < "$DIR/$f" | tr -d ' ')"
        cat "$DIR/$f"
    done
} | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1
