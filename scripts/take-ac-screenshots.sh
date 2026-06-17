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

# Editor sidebar entries to capture, top-to-bottom in on-screen order.
# Each item is "filekey" or "filekey:selectkey". The AppleScript bridge
# matches selectkey against the EditorCategory rawValue (case- and
# space-insensitive); filekey is the token baked into the output filename.
# They differ only for the Agents pane: its rawValue is "Agents" (so the
# select key must be "agents"), but the on-disk screenshot keeps its
# historical "agent" filename so existing references stay valid.
CATEGORIES=(general agent:agents fusion folders credentials environment mcp tracing guardrails supplychain promptinjection appearance resources)

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
    # `|| true` is load-bearing: this script runs under `set -e`, so without
    # it a `state=$(ac_tell …)` command substitution that fails (osascript
    # exits non-zero) aborts the WHOLE run on the spot — which is exactly why
    # the readiness loop "immediately failed instead of retrying" on the
    # -2753 "terminology not ready" error right after launch. Callers detect
    # failures from the returned STRING via ac_response_ok and retry, so
    # suppressing the exit code here loses nothing and makes the loop work.
    osascript -e "tell application \"${APP_NAME}\" to $1" 2>&1 || true
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
    ' 2>/dev/null) || true
    # (`|| true`: don't let an osascript failure abort the run under set -e.
    # Empty `rect` is handled below as a capture failure. Currently this runs
    # set -e-exempt anyway — it's called from an `if` — but this keeps it safe
    # if that ever changes.)
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

    # First gate on the HTTP automation server (port 9223). Its /health is a
    # plain GET that — unlike AppleScript — doesn't depend on the app's
    # scripting terminology being loaded, so it's a deterministic "the process
    # is up" signal. Waiting here first means the AppleScript loop below isn't
    # spammed with -2753 while the app is still booting.
    for _ in $(seq 1 60); do
        sleep 0.5
        if curl -fsS -m 2 http://127.0.0.1:9223/health >/dev/null 2>&1; then
            break
        fi
    done

    # Then wait for the AppleScript bridge: terminology loaded AND
    # NSApp.delegate is the ACAppDelegate. Before that, the bridge returns a
    # -2753 terminology error or an "error: app not ready" string — both
    # caught by ac_response_ok, so the loop retries (ac_tell swallows the
    # non-zero exit so `set -e` can't abort us mid-retry).
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

    for cat_entry in "${CATEGORIES[@]}"; do
        category="${cat_entry%%:*}"    # filename token
        selkey="${cat_entry##*:}"      # AppleScript select key (== category if no colon)
        outfile="$OUTPUT_DIR/editor_${category}_${suffix}.jpg"
        # Retry the select+capture a few times: a single AXRaise race or a
        # transient screencapture miss used to drop one tile silently and
        # ship a partial grid (e.g. supplychain_en went missing this way).
        captured=false
        for attempt in 1 2 3; do
            sel=$(ac_tell "select editor category \"$selkey\"")
            if [[ "$sel" == error* ]]; then
                echo "  $category select failed (attempt $attempt): $sel" >&2
                sleep 0.6
                continue
            fi
            sleep 0.6
            if capture_editor_window "$outfile"; then
                printf "  %-12s → %s\n" "$category" "$(basename "$outfile")"
                captured=true
                break
            fi
            echo "  $category capture failed (attempt $attempt), retrying…" >&2
            sleep 0.6
        done
        if ! $captured; then
            echo "  $category FAILED after 3 attempts ($suffix)" >&2
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

# Completeness gate: assert every locale × category tile exists on disk.
# Scanning the filesystem (rather than trusting an in-run counter) also
# catches whole-locale skips from the `continue` statements above — e.g.
# an "app not ready" timeout that aborts a locale before any capture.
# Without this gate a partial grid commits silently; with it the Jenkins
# job fails loudly and the bad run can be retried.
missing=()
for entry in "${LOCALES[@]}"; do
    suffix=$(echo "$entry" | awk '{print $2}')
    for cat_entry in "${CATEGORIES[@]}"; do
        category="${cat_entry%%:*}"   # filename token (strip any :selectkey)
        f="$OUTPUT_DIR/editor_${category}_${suffix}.jpg"
        [ -s "$f" ] || missing+=("$(basename "$f")")
    done
done

expected=$(( ${#LOCALES[@]} * ${#CATEGORIES[@]} ))
if [ ${#missing[@]} -gt 0 ]; then
    echo "" >&2
    echo "ERROR: ${#missing[@]} of $expected expected tiles are missing:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi
echo "All $expected expected tiles present (${#LOCALES[@]} locales × ${#CATEGORIES[@]} categories)."
