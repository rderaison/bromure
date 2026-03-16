#!/bin/bash
# take-screenshots.sh — Capture profile settings screenshots in all locales.
#
# Usage: ./scripts/take-screenshots.sh
#
# Prerequisites:
#   - Bromure.app built at .build/.../Bromure.app
#   - Screen Recording permission granted to Terminal

set -euo pipefail

PROFILE="Private Browsing"
OUTPUT_DIR="Resources"
mkdir -p "$OUTPUT_DIR"

CATEGORIES=(general performance media fileTransfer privacy network vpnAds enterprise advanced)
LOCALES=(en fr de es pt ja zh_TW zh_CN)
LOCALE_NAMES=(en fr de es pt ja zh-TW zh-CN)

capture_settings_window() {
    local outfile="$1"
    local rect
    # The settings window is always the non-"Bromure" window (main window is just "Bromure")
    # In any locale, the settings window title contains "—" (em dash) and the profile name
    rect=$(osascript -e '
        tell application "Bromure" to activate
        delay 0.3
        tell application "System Events"
            tell process "Bromure"
                repeat with w in windows
                    if name of w is not "Bromure" then
                        perform action "AXRaise" of w
                        delay 0.2
                        set p to position of w
                        set s to size of w
                        return "" & (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s)
                    end if
                end repeat
            end tell
        end tell
    ' 2>/dev/null)
    if [ -n "$rect" ]; then
        screencapture -x -t jpg -R "$rect" "$outfile" 2>/dev/null
        return 0
    fi
    return 1
}

echo "=== Bromure Screenshot Tool ==="
echo "Profile: $PROFILE"
echo "Output: $OUTPUT_DIR/"
echo ""

for locale_idx in "${!LOCALES[@]}"; do
    locale="${LOCALES[$locale_idx]}"
    locale_name="${LOCALE_NAMES[$locale_idx]}"

    echo "--- Locale: $locale ---"

    osascript -e 'tell application "Bromure" to quit' 2>/dev/null || true
    sleep 3
    open -a "$(pwd)/.build/arm64-apple-macosx/release/Bromure.app" --args -AppleLanguages "($locale)"

    # Wait for ready
    for i in $(seq 1 30); do
        state=$(osascript -e 'tell application "Bromure" to get app state' 2>/dev/null || echo '{}')
        if echo "$state" | grep -q '"ready"'; then break; fi
        sleep 1
    done
    sleep 1

    for category in "${CATEGORIES[@]}"; do
        echo -n "  $category... "

        osascript -e "tell application \"Bromure\" to open profile settings \"$PROFILE\" category \"$category\"" 2>/dev/null
        sleep 1.5

        outfile="$OUTPUT_DIR/prefs_${category}_${locale_name}.jpg"
        if capture_settings_window "$outfile"; then
            echo "OK → $outfile"
        else
            echo "SKIP (window not found)"
        fi

        # Close settings window
        osascript -e '
            tell application "System Events"
                tell process "Bromure"
                    if (count of windows) > 1 then
                        keystroke "w" using command down
                    end if
                end tell
            end tell
        ' 2>/dev/null || true
        sleep 0.5
    done
    echo ""
done

# Restore English
osascript -e 'tell application "Bromure" to quit' 2>/dev/null || true
sleep 2
open -a "$(pwd)/.build/arm64-apple-macosx/release/Bromure.app"

echo "=== Done ==="
ls -1 "$OUTPUT_DIR"/prefs_*_*.jpg 2>/dev/null | wc -l | xargs -I{} echo "{} screenshots captured"
