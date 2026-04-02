#!/bin/bash
# take-screenshots.sh — Capture profile settings screenshots in all locales.
#
# Usage: ./scripts/take-screenshots.sh
#
# Prerequisites:
#   - Bromure.app built at .build/.../Bromure.app
#   - Screen Recording permission granted to Terminal

set -euo pipefail

PROFILE="Work"
OUTPUT_DIR="/Users/jenkins/workspace/Bromure/bromure-screenshots/Resources"
mkdir -p "$OUTPUT_DIR"

CATEGORIES=(general performance media fileTransfer privacy network vpnAds enterprise advanced)
LOCALES=(en fr de es pt ja zh-Hant-TW zh-Hans-CN)
LOCALE_NAMES=(en fr de es pt ja zh-TW zh-CN)

capture_settings_window() {
    local outfile="$1"
    local wid
    # The settings window is always the non-"Bromure" window (main window is just "Bromure")
    osascript -e '
        tell application "Bromure" to activate
        delay 0.3
        tell application "System Events"
            tell process "Bromure"
                repeat with w in windows
                    if name of w is not "Bromure" then
                        perform action "AXRaise" of w
                    end if
                end repeat
            end tell
        end tell
    '
    sleep 0.2
    # Get the CGWindowID for the settings window
    wid=$(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, 0):
    if w.get('kCGWindowOwnerName') == 'Bromure' and w.get('kCGWindowName', '') != 'Bromure':
        print(w['kCGWindowNumber']); break
")
    if [ -n "$wid" ]; then
        echo "  windowID: $wid"
        screencapture -x -t jpg -l "$wid" "$outfile"
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

    pkill -x bromure 2>/dev/null || true
    sleep 3
    APP_BUNDLE="$(pwd)/.build/arm64-apple-macosx/release/Bromure.app"
    "$APP_BUNDLE/Contents/MacOS/bromure" -AppleLanguages "($locale)" &

    # Wait for ready via automation API
    for i in $(seq 1 60); do
        if curl -s http://127.0.0.1:9222/health 2>/dev/null | grep -q '"ok"'; then break; fi
        sleep 2
    done
    sleep 1

    for category in "${CATEGORIES[@]}"; do
        echo -n "  $category... "

        osascript -e "tell application \"Bromure\" to open profile settings \"$PROFILE\" category \"$category\""
        sleep 1.5

        outfile="$OUTPUT_DIR/prefs_${category}_${locale_name}.jpg"
        rm -f "$outfile"
        echo "  Writing to $outfile"
        capture_settings_window "$outfile"
        echo "OK → $outfile"

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
pkill -x bromure 2>/dev/null || true
sleep 2
"$(pwd)/.build/arm64-apple-macosx/release/Bromure.app/Contents/MacOS/bromure" &

echo "=== Done ==="
ls -1 "$OUTPUT_DIR"/prefs_*_*.jpg 2>/dev/null | wc -l | xargs -I{} echo "{} screenshots captured"
