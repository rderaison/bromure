#!/bin/bash
# take-ac-board-screenshots.sh — Capture the two kanban boards (Automations,
# Coding Tasks) for the manual, across all 8 locales.
#
# Mechanics are identical to take-manual-screenshots.sh: relaunch the app per
# locale with -AppleLanguages and BROMURE_DEBUG_CLAUDE=1 on a scratch state
# (BROMURE_STATE_DIR: its own data, settings and an ephemeral control port, so
# a Bromure AC you work in can stay open), drive the control server, and let
# the app render its own windows offscreen via /debug/ui-shot. The boards are populated with a demo fixture
# (/debug/editor seed-board-demo) and cleaned up afterwards — no VM, no
# agent, no network is involved.
#
# Output: manual/images/automation-board.<suffix>.jpg
#         manual/images/task-board.<suffix>.jpg

set -u

BIN="$(pwd)/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
BASE=""          # http://127.0.0.1:<ephemeral port>, learnt from /health at each launch
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
# The instance's state (data + control socket); its settings are the suite
# <bundle id>.state.<folder name>, wiped with it.
STATE="$SHOT_HOME/board-state"
SOCK="$STATE/control.sock"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$(dirname "$BIN")/../Info.plist")
SUITE="$BUNDLE_ID.state.$(basename "$STATE")"
APP_PID=""

# Stop our instance through its control socket (the menu's drain, no dialog).
# Never pkill: another Bromure AC may be running on its own state.
stop_app() {
    [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null || { APP_PID=""; return 0; }
    curl -fsS -m 5 --unix-socket "$SOCK" -X POST -d '{"vms":"shutdown"}' "http://x/app/quit" >/dev/null 2>&1
    for _ in $(seq 1 60); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
    APP_PID=""
}
trap 'stop_app; defaults delete "$SUITE" >/dev/null 2>&1' EXIT
defaults delete "$SUITE" >/dev/null 2>&1

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
            if sips -s format jpeg -s formatOptions best "$tmp" --out "$outfile" >/dev/null 2>&1 && [ -s "$outfile" ]; then
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
    stop_app
    defaults delete "$SUITE" >/dev/null 2>&1

    # A scratch state: the capture instance must never show the user's real
    # workspaces, tasks, or automations. BROMURE_STATE_DIR gives it its own
    # data folder and settings; port 0 turns the control server on, on an
    # ephemeral loopback port, without touching anyone's defaults.
    rm -rf "$STATE"; mkdir -p "$STATE"
    BROMURE_DEBUG_CLAUDE=1 CFFIXED_USER_HOME="$SHOT_HOME" \
        BROMURE_STATE_DIR="$STATE" BROMURE_AC_AUTOMATION_PORT=0 \
        "$BIN" -AppleLanguages "($locale)" >/dev/null 2>&1 &
    APP_PID=$!

    ready=false
    for _ in $(seq 1 60); do
        sleep 0.5
        port=$(curl -fsS -m 2 --unix-socket "$SOCK" "http://x/health" 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin).get("automationPort", ""))' 2>/dev/null)
        if [ -n "$port" ]; then BASE="http://127.0.0.1:$port"; ready=true; break; fi
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

stop_app

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
