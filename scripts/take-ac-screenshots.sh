#!/bin/bash
# take-ac-screenshots.sh — Capture Bromure Agentic Coding's editor
# screenshots in every locale × every category.
#
# Usage: ./scripts/take-ac-screenshots.sh
#
# Prerequisites:
#   - Bromure Agentic Coding.app built at .build/.../
#       (run `./build.sh bromure-ac` first)
#   - Screen Recording + Accessibility granted to Terminal so AppleScript
#     can drive the app via System Events and screencapture can read the
#     editor window's pixels.

set -euo pipefail

APP_NAME="Bromure Agentic Coding"
APP_BUNDLE="$(pwd)/.build/arm64-apple-macosx/release/${APP_NAME}.app"
BIN="${APP_BUNDLE}/Contents/MacOS/bromure-ac"
OUTPUT_DIR="$(pwd)/Resources/ac"
PROFILE="Screenshot"

mkdir -p "$OUTPUT_DIR"

if [ ! -x "$BIN" ]; then
    echo "ERROR: ${BIN} not found. Run ./build.sh bromure-ac first." >&2
    exit 1
fi

# Editor sidebar entries that the AppleScript bridge accepts. Order
# matches the on-screen sidebar so the loop reads top-to-bottom.
CATEGORIES=(general agent folders credentials tracing appearance resources)

# (locale-code  filename-suffix). Locale codes are what
# `defaults write -AppleLanguages` understands; suffix is what gets
# appended to each output file.
LOCALES=(
    "en       en"
    "fr       fr"
    "de       de"
    "es       es"
    "pt       pt"
    "ja       ja"
    "zh-Hans  zh-CN"
    "zh-Hant  zh-TW"
)

# ----------------------------------------------------------------------
# Drive the app via osascript.
# ----------------------------------------------------------------------

ac_tell() {
    osascript -e "tell application \"${APP_NAME}\" to $1" 2>/dev/null
}

ensure_profile() {
    # Create the screenshot profile if it doesn't already exist. The
    # `create ac profile` command is idempotent in spirit — duplicates
    # of the same name are tolerated by the script (we look up by name).
    local id
    id=$(ac_tell "create ac profile \"$PROFILE\"" || true)
    if [ -z "$id" ] || [[ "$id" == error* ]]; then
        echo "  (using existing $PROFILE profile)"
    fi
}

editor_window_id() {
    ac_tell "get editor window id" || echo "0"
}

capture_window_id() {
    local outfile="$1"
    local wid="$2"
    [ -z "$wid" ] || [ "$wid" = "0" ] && return 1
    rm -f "$outfile"
    screencapture -x -o -l "$wid" "$outfile" 2>/dev/null
    [ -s "$outfile" ]
}

# ----------------------------------------------------------------------
# Main loop.
# ----------------------------------------------------------------------

echo "=== Bromure AC Screenshot Tool ==="
echo "Output: $OUTPUT_DIR/"
echo ""

for entry in "${LOCALES[@]}"; do
    locale=$(echo "$entry" | awk '{print $1}')
    suffix=$(echo "$entry" | awk '{print $2}')

    echo "--- Locale: $locale ---"
    pkill -x bromure-ac 2>/dev/null || true
    sleep 2

    "$BIN" -AppleLanguages "($locale)" >/dev/null 2>&1 &

    # Wait for the app to register its scripting interface.
    for _ in $(seq 1 30); do
        sleep 0.5
        state=$(ac_tell "get app state" 2>/dev/null || true)
        [ -n "$state" ] && break
    done
    sleep 0.5

    ensure_profile

    # Open editor for the screenshot profile.
    ac_tell "open ac profile editor \"$PROFILE\"" >/dev/null
    sleep 1

    wid=$(editor_window_id)
    if [ -z "$wid" ] || [ "$wid" = "0" ]; then
        echo "  WARN: editor window didn't open"
        continue
    fi

    for category in "${CATEGORIES[@]}"; do
        ac_tell "select editor category \"$category\"" >/dev/null
        sleep 0.6
        outfile="$OUTPUT_DIR/editor_${category}_${suffix}.png"
        if capture_window_id "$outfile" "$wid"; then
            printf "  %-12s → %s\n" "$category" "$(basename "$outfile")"
        else
            echo "  $category SKIP (capture failed)"
        fi
    done

    ac_tell "close ac profile editor" >/dev/null
    sleep 0.4
done

# Tidy: kill the app and clear the AppleLanguages override so the next
# normal launch picks the user's macOS preferred language again.
pkill -x bromure-ac 2>/dev/null || true
sleep 1
defaults delete io.bromure.agentic-coding AppleLanguages 2>/dev/null || true

echo ""
echo "=== Done ==="
count=$(find "$OUTPUT_DIR" -name "editor_*.png" -type f | wc -l | tr -d ' ')
echo "$count screenshots captured under $OUTPUT_DIR/"
