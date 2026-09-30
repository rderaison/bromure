#!/bin/bash
# take-web-manual-screenshots.sh — every screenshot in manual-web/images, in
# all 8 locales, for the Bromure (web browser) user manual.
#
# Usage: ./scripts/take-web-manual-screenshots.sh [locale-suffix …]   (default: all)
#        SHOTS="profile-general settings-storage" ./scripts/take-web-manual-screenshots.sh en
#
# How: each window is rendered offscreen by the app itself
# (`bromure __shot-ui <shot> <png>`, Sources/Browser/ManualShots.swift):
# no VM boots, no base image is needed, and no Screen Recording or
# Accessibility permission is involved. Profiles shown are demo data and app
# preferences are masked with their defaults, so nothing of yours appears —
# and it's safe to run while Bromure is open. Build first: ./build.sh
#
# Re-run it in the same change whenever a settings pane, the setup window or
# another pictured window changes, so text and images are reviewed together.

set -u
cd "$(dirname "$0")/.."

BIN="$(pwd)/.build/arm64-apple-macosx/release/Bromure.app/Contents/MacOS/bromure"
OUT="$(pwd)/manual-web/images"
TMP="$(mktemp -d /tmp/bromure-web-shots.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
JOBS="${JOBS:-4}"

[ -x "$BIN" ] || { echo "Build first: ./build.sh" >&2; exit 1; }
mkdir -p "$OUT"

ALL_SHOTS=(
    setup-welcome setup-progress setup-error starting new-profile
    profile-general profile-performance profile-media profile-file-transfer
    profile-host-isolation profile-network-isolation profile-privacy profile-extensions
    profile-vpn-ads profile-enterprise profile-advanced
    settings-general settings-hardware settings-input settings-display settings-network
    settings-automation settings-managed settings-storage
    enrollment phishing-consent warp-eula trace-viewer
)
# "AppleLanguages value  file suffix" — the suffixes match manual/images.
ALL_LOCALES=("en en" "fr fr" "de de" "es es" "pt pt" "ja ja" "zh-Hans zh-CN" "zh-Hant zh-TW")

read -r -a SHOTS_LIST <<< "${SHOTS:-${ALL_SHOTS[*]}}"
WANT=("$@")

# One job per (locale, shot): render to PNG, convert to JPEG like manual/.
jobs_file="$TMP/jobs"
for entry in "${ALL_LOCALES[@]}"; do
    set -- $entry; loc="$1"; sfx="$2"
    if [ ${#WANT[@]} -gt 0 ] && [[ ! " ${WANT[*]} " == *" $sfx "* ]]; then continue; fi
    for shot in "${SHOTS_LIST[@]}"; do echo "$loc $sfx $shot"; done
done > "$jobs_file"

render() {   # render LOC SFX SHOT
    local loc="$1" sfx="$2" shot="$3" png="$TMP/$3.$2.png"
    for attempt in 1 2; do
        rm -f "$png"
        if "$BIN" __shot-ui "$shot" "$png" light -AppleLanguages "($loc)" >/dev/null 2>&1 && [ -s "$png" ] \
           && sips -s format jpeg -s formatOptions 85 "$png" --out "$OUT/$shot.$sfx.jpg" >/dev/null 2>&1; then
            printf "  %-28s %s\n" "$shot" "$sfx"; return 0
        fi
    done
    echo "  FAILED $shot ($sfx)" >&2; return 1
}
export -f render
export BIN OUT TMP

total=$(wc -l < "$jobs_file" | tr -d ' ')
echo "Rendering $total screenshots ($JOBS at a time)…"
xargs -P "$JOBS" -L 1 bash -c 'render "$0" "$1" "$2"' < "$jobs_file"
status=$?
echo "Done: $(ls "$OUT"/*.jpg 2>/dev/null | wc -l | tr -d ' ') images in manual-web/images"
exit $status
