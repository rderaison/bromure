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

set -euxo pipefail

APP_NAME="Bromure Agentic Coding"
APP_BUNDLE="$(pwd)/.build/arm64-apple-macosx/release/${APP_NAME}.app"
BIN="${APP_BUNDLE}/Contents/MacOS/bromure-ac"
OUTPUT_DIR="$(pwd)/Resources/ac"
PROFILE="Claude Dev"

mkdir -p "$OUTPUT_DIR"

if [ ! -x "$BIN" ]; then
    echo "ERROR: ${BIN} not found. Run ./build.sh bromure-ac first." >&2
    exit 1
fi

# Re-register the freshly-built bundle with LaunchServices so AppleScript
# resolves THIS build's scripting definition (BromureAC.sdef). Rebuilding
# the .app in place leaves macOS's terminology cache pointing at the prior
# build; without this, `tell application … to get app state` can fail with
# "The variable state is not defined. (-2753)" until a reboot. Kill any
# running instance first — a live process keeps serving stale terminology.
#
# Unregister (-u) then re-register (-f): -u evicts the bundle's cached
# dictionary so -f reloads it fresh. (macOS 26's lsregister dropped the
# old `-kill` switch; -u/-f is the non-reboot equivalent for one bundle.)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
    pkill -x bromure-ac 2>/dev/null || true
    sleep 1
    "$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
    "$LSREGISTER" -f "$APP_BUNDLE" && echo "Re-registered $APP_NAME with LaunchServices."
    # Let LaunchServices propagate the new registration before the first
    # osascript call compiles `tell application …` and fetches terminology.
    sleep 5
fi

# Editor sidebar entries that the AppleScript bridge accepts. Order
# matches the on-screen sidebar so the loop reads top-to-bottom.
CATEGORIES=(general agent folders credentials environment mcp tracing guardrails appearance resources)

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
    osascript -e "tell application \"${APP_NAME}\" to $1" 2>&1
}

# True only when the response is real data — not osascript stderr noise
# and not one of the bridge's "error: …" sentinel strings. Used to drive
# the wait loop so we don't proceed before NSApp.delegate is the
# ACAppDelegate.
ac_response_ok() {
    local s="$1"
    [ -n "$s" ] && [[ "$s" != error* ]] && [[ "$s" != *"execution error"* ]]
}

ensure_profile() {
    # Check the live profile list first; only create if missing. The
    # `create ac profile` bridge does NOT dedupe by name, so calling it
    # blindly per locale would accumulate duplicate "Screenshot"
    # profiles in the on-disk store.
    local listing
    listing=$(ac_tell "list profiles")
    if echo "$listing" | grep -q "\"name\":\"$PROFILE\""; then
        echo "  (reusing existing $PROFILE profile)"
        return
    fi
    local id
    id=$(ac_tell "create ac profile \"$PROFILE\"")
    if ! ac_response_ok "$id"; then
        echo "  ERROR creating profile: $id" >&2
        return 1
    fi
    echo "  (created $PROFILE profile: $id)"
}

editor_window_id() {
    ac_tell "get editor window id" || echo "0"
}

# Mirrors take-screenshots.sh's capture_settings_window: activate the
# app, find the editor window via System Events, raise it, then
# screencapture -R the rect. Screen-rect capture is more reliable than
# `-l <windowID>` across macOS versions and respects Screen Recording
# permissions consistently.
capture_editor_window() {
    local outfile="$1"
    local rect
    rect=$(osascript -e '
        tell application "'"$APP_NAME"'" to activate
        delay 0.3
        tell application "System Events"
            tell process "bromure-ac"
                repeat with w in windows
                    if name of w is not "'"$APP_NAME"'" then
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
        rm -f "$outfile"
        screencapture -x -t jpg -R "$rect" "$outfile" 2>/dev/null
        [ -s "$outfile" ]
        return $?
    fi
    return 1
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

    # Wait for the app to register its scripting interface AND for
    # NSApp.delegate to be the ACAppDelegate. Before that, every bridge
    # command returns "error: app not ready" — non-empty, so a naive
    # `-n "$state"` check would race past the readiness gate.
    ready=false
    for _ in $(seq 1 60); do
        sleep 0.5
        state=$(ac_tell "get app state")
        if ac_response_ok "$state"; then
            ready=true
            break
        fi
    done
    if ! $ready; then
        echo "  ERROR: app not ready after 30s — last state: $state" >&2
        continue
    fi
    sleep 0.5

    ensure_profile || continue

    # Open editor for the screenshot profile. Fire and verify by side
    # effect (the editor window's ID) rather than the command's stdout —
    # older sdef revisions omitted the <result> declaration, which made
    # the bridge swallow the "ok" return value even on success. Only
    # treat an explicit "error: …" string as failure here.
    open_result=$(ac_tell "open ac profile editor \"$PROFILE\"")
    if [[ "$open_result" == error* ]]; then
        echo "  ERROR opening editor: $open_result" >&2
        continue
    fi
    sleep 1

    wid=$(editor_window_id)
    if [ -z "$wid" ] || [ "$wid" = "0" ]; then
        echo "  WARN: editor window didn't open (open_result: '$open_result')"
        continue
    fi

    for category in "${CATEGORIES[@]}"; do
        sel=$(ac_tell "select editor category \"$category\"")
        if [[ "$sel" == error* ]]; then
            echo "  $category SKIP (select failed: $sel)" >&2
            continue
        fi
        sleep 0.6
        outfile="$OUTPUT_DIR/editor_${category}_${suffix}.jpg"
        if capture_editor_window "$outfile"; then
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
count=$(find "$OUTPUT_DIR" -name "editor_*.jpg" -type f | wc -l | tr -d ' ')
echo "$count screenshots captured under $OUTPUT_DIR/"
