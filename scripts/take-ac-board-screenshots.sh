#!/bin/bash
# take-ac-board-screenshots.sh — Capture the two kanban boards (Automations,
# Coding Tasks) for the manual, across all 8 locales.
#
# Mechanics are identical to take-ac-screenshots.sh: relaunch the app per
# locale with -AppleLanguages and BROMURE_DEBUG_CLAUDE=1, drive the loopback
# control server, and let the app render its own windows offscreen via
# /debug/ui-shot. The boards are populated with a demo fixture
# (/debug/editor seed-board-demo) and cleaned up afterwards — no VM, no
# agent, no network is involved.
#
# Output: manual/images/automation-board.<suffix>.jpg
#         manual/images/task-board.<suffix>.jpg

set -u

BIN="$(pwd)/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
BASE="http://127.0.0.1:9223"
PROFILE="Screenshot"
OUTPUT_DIR="$(pwd)/manual/images"

if [ ! -x "$BIN" ]; then
    echo "ERROR: ${BIN} not found. Run ./build.sh bromure-ac first." >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"
SHOT_HOME="/tmp/bromure-ac-board-shots-home"
rm -rf "$SHOT_HOME"
mkdir -p "$SHOT_HOME"

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

editor() {
    local action="$1" extra="${2:-}"
    curl -fsS -m 15 -X POST -H "Content-Type: application/json" \
        -d "{\"action\":\"$action\"${extra:+,$extra}}" "${BASE}/debug/editor"
}

capture() {
    curl -fsS -m 15 "${BASE}/debug/ui-shot?which=$1&path=$2" | grep -q '"png"'
}

shoot() {   # shoot WHICH FILENAME-BASE SUFFIX
    local which="$1" base="$2" suffix="$3"
    local tmp="/tmp/ac-board-${base}-${suffix}.png"
    local outfile="$OUTPUT_DIR/${base}.${suffix}.jpg"
    for attempt in 1 2 3; do
        rm -f "$tmp"
        if capture "$which" "$tmp" && [ -s "$tmp" ]; then
            if sips -s format jpeg "$tmp" --out "$outfile" >/dev/null 2>&1 && [ -s "$outfile" ]; then
                rm -f "$tmp"
                printf "  %-16s → %s\n" "$which" "$(basename "$outfile")"
                return 0
            fi
        fi
        echo "  $which capture failed (attempt $attempt), retrying…" >&2
        sleep 0.6
    done
    echo "  $which FAILED after 3 attempts ($suffix)" >&2
    return 1
}

echo "=== Bromure AC Board Screenshot Tool ==="
echo "Output: $OUTPUT_DIR/"
echo ""

for entry in "${LOCALES[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    locale="$1"; suffix="$2"

    echo "--- Locale: $locale ---"
    pkill -x bromure-ac 2>/dev/null || true
    sleep 1

    # Isolated home: the capture instance must never show the user's real
    # workspaces, tasks, or automations — CFFIXED_USER_HOME relocates the
    # support dir and defaults to a scratch home holding only the demo
    # fixture. The control server is opt-in via defaults, and the scratch
    # defaults start empty — seed the plist before launch (the CLI parser
    # rejects extra launch arguments).
    mkdir -p "$SHOT_HOME/Library/Preferences"
    defaults write "$SHOT_HOME/Library/Preferences/io.bromure.agentic-coding.plist" \
        automation.enabled -bool true
    BROMURE_DEBUG_CLAUDE=1 CFFIXED_USER_HOME="$SHOT_HOME" \
        "$BIN" -AppleLanguages "($locale)" >/dev/null 2>&1 &

    ready=false
    for _ in $(seq 1 60); do
        sleep 0.5
        if curl -fsS -m 2 "${BASE}/health" >/dev/null 2>&1; then ready=true; break; fi
    done
    if ! $ready; then echo "  ERROR: app not ready after 30s" >&2; continue; fi
    sleep 0.5

    if ! editor ensure-profile "\"name\":\"$PROFILE\"" >/dev/null; then
        echo "  ERROR: couldn't ensure $PROFILE workspace" >&2; continue
    fi
    if ! editor seed-board-demo "\"profile\":\"$PROFILE\"" >/dev/null; then
        echo "  ERROR: couldn't seed the board demo fixture" >&2; continue
    fi
    sleep 0.4

    shoot board automation-board "$suffix"
    sleep 0.4
    shoot tasks task-board "$suffix"

    editor clear-board-demo >/dev/null || true
    sleep 0.3
done

pkill -x bromure-ac 2>/dev/null || true

echo ""
echo "=== Done ==="
missing=0
for entry in "${LOCALES[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    suffix="$2"
    for base in automation-board task-board; do
        f="$OUTPUT_DIR/${base}.${suffix}.jpg"
        [ -s "$f" ] || { echo "MISSING: $f" >&2; missing=$((missing+1)); }
    done
done
if [ "$missing" -gt 0 ]; then
    echo "ERROR: $missing screenshot(s) missing." >&2
    exit 1
fi
echo "All $(( ${#LOCALES[@]} * 2 )) board screenshots present (${#LOCALES[@]} locales × 2 boards)."
