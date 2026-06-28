#!/bin/bash
# take-ac-screenshots.sh — Capture Bromure Agentic Coding's settings-editor
# screenshots in every locale × every category.
#
# Usage: ./scripts/take-ac-screenshots.sh
#
# Prerequisites:
#   - Bromure Agentic Coding.app built at .build/.../  (run `./build.sh
#     bromure-ac` first).
#   - That's it. No Screen Recording / Accessibility permission, no AppleScript,
#     no LaunchServices registration. The app renders each editor window to a
#     PNG itself (the same built-in `/debug/ui-shot` used for layout debugging),
#     driven entirely over the loopback control server (port 9223). This is far
#     more robust than the old `osascript` + `screencapture` approach, which
#     depended on Screen Recording, the frontmost window, AXRaise timing, and
#     the app's scripting terminology being loaded.

set -euo pipefail

APP_NAME="Bromure Agentic Coding"
APP_BUNDLE="$(pwd)/.build/arm64-apple-macosx/release/${APP_NAME}.app"
BIN="${APP_BUNDLE}/Contents/MacOS/bromure-ac"
OUTPUT_DIR="$(pwd)/Resources/ac"
PROFILE="Claude Dev"
BASE="http://127.0.0.1:9223"

mkdir -p "$OUTPUT_DIR"

if [ ! -x "$BIN" ]; then
    echo "ERROR: ${BIN} not found. Run ./build.sh bromure-ac first." >&2
    exit 1
fi

# Editor sidebar entries to capture, top-to-bottom in on-screen order.
# Each item is "filekey" or "filekey:selectkey". selectkey is matched against
# the EditorCategory rawValue (case- and space-insensitive); filekey is the
# token baked into the output filename. They differ only for the Agents pane
# (rawValue "Agents", but the on-disk file keeps its historical "agent" name).
CATEGORIES=(general agent:agents fusion folders credentials environment mcp tracing guardrails supplychain promptinjection appearance resources)

# (locale-code  filename-suffix). Locale codes are what -AppleLanguages
# understands; suffix is appended to each output file.
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
# Control-server helpers (loopback HTTP, port 9223).
# ----------------------------------------------------------------------

# editor ACTION [extra-json]  → POST /debug/editor {"action":…, …}
editor() {
    local action="$1" extra="${2:-}"
    curl -fsS -m 15 -X POST -H "Content-Type: application/json" \
        -d "{\"action\":\"$action\"${extra:+,$extra}}" "${BASE}/debug/editor"
}

# capture WHICH PNG-PATH  → GET /debug/ui-shot; true if a png was written.
capture() {
    curl -fsS -m 15 "${BASE}/debug/ui-shot?which=$1&path=$2" | grep -q '"png"'
}

# ----------------------------------------------------------------------
# Main loop.
# ----------------------------------------------------------------------

echo "=== Bromure AC Screenshot Tool ==="
echo "Output: $OUTPUT_DIR/"
echo ""

for entry in "${LOCALES[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    locale="$1"; suffix="$2"

    echo "--- Locale: $locale ---"
    pkill -x bromure-ac 2>/dev/null || true
    sleep 1

    # Launch this build with the locale as a launch arg (NSArgumentDomain — not
    # persisted, so nothing to clean up) and the debug endpoints enabled so the
    # /debug/* routes answer on the loopback control server.
    BROMURE_DEBUG_CLAUDE=1 "$BIN" -AppleLanguages "($locale)" >/dev/null 2>&1 &

    # Wait for the control server. /health is a plain GET — a deterministic
    # "process is up" signal with no scripting/terminology dependency.
    ready=false
    for _ in $(seq 1 60); do
        sleep 0.5
        if curl -fsS -m 2 "${BASE}/health" >/dev/null 2>&1; then ready=true; break; fi
    done
    if ! $ready; then echo "  ERROR: app not ready after 30s" >&2; continue; fi
    sleep 0.5

    # Find-or-create the screenshot workspace, then open its editor. A saved
    # workspace (vs. a brand-new unsaved one) makes the resources / ssh panes
    # render their real content.
    if ! editor ensure-profile "\"name\":\"$PROFILE\"" >/dev/null; then
        echo "  ERROR: couldn't ensure $PROFILE workspace" >&2; continue
    fi
    if ! editor open "\"profile\":\"$PROFILE\"" >/dev/null; then
        echo "  ERROR: couldn't open editor" >&2; continue
    fi
    sleep 0.6

    for cat_entry in "${CATEGORIES[@]}"; do
        category="${cat_entry%%:*}"   # filename token
        selkey="${cat_entry##*:}"     # category key (== category if no colon)
        outfile="$OUTPUT_DIR/editor_${category}_${suffix}.jpg"
        tmp="/tmp/ac-shot-${category}-${suffix}.png"

        captured=false
        for attempt in 1 2 3; do
            if ! editor category "\"category\":\"$selkey\"" >/dev/null; then
                echo "  $category select failed (attempt $attempt)" >&2; sleep 0.5; continue
            fi
            sleep 0.6   # let SwiftUI re-render the selected category
            rm -f "$tmp"
            if capture editor "$tmp" && [ -s "$tmp" ]; then
                # The renderer emits PNG; docs use JPG. sips converts with no
                # extra permissions.
                if sips -s format jpeg "$tmp" --out "$outfile" >/dev/null 2>&1 && [ -s "$outfile" ]; then
                    rm -f "$tmp"
                    printf "  %-12s → %s\n" "$category" "$(basename "$outfile")"
                    captured=true
                    break
                fi
            fi
            echo "  $category capture failed (attempt $attempt), retrying…" >&2
            sleep 0.5
        done
        $captured || echo "  $category FAILED after 3 attempts ($suffix)" >&2
    done

    editor close >/dev/null || true
    sleep 0.3
done

pkill -x bromure-ac 2>/dev/null || true

echo ""
echo "=== Done ==="
count=$(find "$OUTPUT_DIR" -name "editor_*.jpg" -type f | wc -l | tr -d ' ')
echo "$count screenshots captured under $OUTPUT_DIR/"

# Completeness gate: assert every locale × category tile exists on disk, so a
# partial grid fails the CI job loudly instead of committing silently.
missing=()
for entry in "${LOCALES[@]}"; do
    suffix=$(echo "$entry" | awk '{print $2}')
    for cat_entry in "${CATEGORIES[@]}"; do
        category="${cat_entry%%:*}"
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
