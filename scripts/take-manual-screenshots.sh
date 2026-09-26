#!/bin/bash
# take-manual-screenshots.sh — every screenshot in manual/images, in all 8
# locales, from a synthetic fixture: no VM boots, no agent runs, nothing of
# the user's is shown.
#
# Usage: ./scripts/take-manual-screenshots.sh [locale-suffix …]   (default: all)
#        SHOTS="sessions-home room-stage" ./scripts/take-manual-screenshots.sh en
#
# How: the app is launched with an isolated home (CFFIXED_USER_HOME) and the
# debug routes on (BROMURE_DEBUG_CLAUDE=1), then driven over its loopback
# control server; each window renders itself offscreen (/debug/ui-shot), so
# no Screen Recording / Accessibility permission is involved.
#   1. a fresh home: the first-run wizard's steps (BROMURE_DEBUG_WIZARD);
#   2. the demo fixture (scripts/manual-demo/make-fixture.py → seed-demo):
#      the main window — sessions, chat, room, Switchboard — plus the
#      machines list, sheets, connector, security timeline and the boards;
#   3. the settings: every workspace-editor pane and Preferences › Models.
#
# CAUTION: CFFIXED_USER_HOME does not relocate UserDefaults — the real
# io.bromure.agentic-coding preferences are backed up first and restored at
# the end. Quit any running Bromure Agentic Coding before running this.

set -u
cd "$(dirname "$0")/.."

BIN="$(pwd)/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
BASE="http://127.0.0.1:9223"
OUT="$(pwd)/manual/images"
H=/tmp/bromure-manual-home
FIXTURE=/tmp/bromure-manual-demo
TMP=/tmp/bromure-manual-shots
PREFS="$HOME/Library/Preferences/io.bromure.agentic-coding.plist"
SOCK="$H/Library/Application Support/BromureAC/control.sock"

[ -x "$BIN" ] || { echo "Build first: ./build.sh bromure-ac" >&2; exit 1; }
if pgrep -x bromure-ac >/dev/null; then
    echo "Quit Bromure Agentic Coding first (the shots run their own instance)." >&2; exit 1
fi
mkdir -p "$OUT" "$TMP"
python3 scripts/manual-demo/make-fixture.py "$FIXTURE" >/dev/null || exit 1

# Preferences are shared with the isolated instance: restore them on exit.
PREFS_BACKUP="$TMP/prefs-backup.plist"
[ -f "$PREFS" ] && cp "$PREFS" "$PREFS_BACKUP"
restore_prefs() {
    pkill -x bromure-ac 2>/dev/null; sleep 1
    if [ -f "$PREFS_BACKUP" ]; then cp "$PREFS_BACKUP" "$PREFS"; defaults read io.bromure.agentic-coding >/dev/null 2>&1; fi
}
trap restore_prefs EXIT

ALL_LOCALES=("en en" "fr fr" "de de" "es es" "pt pt" "ja ja" "zh-Hans zh-CN" "zh-Hant zh-TW")
WANT_SUFFIXES=("$@")
WANT_SHOTS="${SHOTS:-}"

want() {   # want SHOT-BASE — honours $SHOTS
    [ -z "$WANT_SHOTS" ] && return 0
    case " $WANT_SHOTS " in *" $1 "*) return 0;; esac
    return 1
}

# ── App control ─────────────────────────────────────────────────────────

launch() {   # launch LOCALE [ENV=VAL …] — fresh isolated home
    local loc="$1"; shift
    pkill -x bromure-ac 2>/dev/null
    for _ in $(seq 1 20); do pgrep -x bromure-ac >/dev/null || break; sleep 0.5; done
    rm -rf "$H"; mkdir -p "$H"
    # Credentials for the wizard's import step to find (all fake).
    mkdir -p "$H/.aws" "$H/.config/gh"
    printf '[default]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\nregion = us-east-1\n' > "$H/.aws/credentials"
    printf 'github.com:\n    oauth_token: gho_demo0000000000000000000000000000\n    user: example-dev\n    git_protocol: https\n' > "$H/.config/gh/hosts.yml"
    env "$@" BROMURE_DEBUG_CLAUDE=1 BROMURE_AC_APPEARANCE="${APPEARANCE:-light}" CFFIXED_USER_HOME="$H" \
        "$BIN" -AppleLanguages "($loc)" > "$TMP/app.log" 2>&1 &
    for _ in $(seq 1 60); do curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
    echo "  app did not come up" >&2; return 1
}

editor() {   # editor ACTION [json-fields]
    curl -fsS -m 30 -X POST -H 'Content-Type: application/json' \
        -d "{\"action\":\"$1\"${2:+,$2}}" "$BASE/debug/editor"
}
fatclient() { curl -fsS -m 30 -X POST -d "{\"action\":\"$1\"${2:+,$2}}" "$BASE/debug/fatclient"; }
local_post() { curl -fsS -m 30 --unix-socket "$SOCK" -X POST -d "$2" "http://x$1"; }

# shoot WHICH BASE SUFFIX [settle-seconds] — render twice (SwiftUI needs a
# runloop pass to show a state change), convert to JPEG.
shoot() {
    local which="$1" base="$2" sfx="$3" settle="${4:-2}"
    want "$base" || return 0
    local png="$TMP/$base.$sfx.png" jpg="$OUT/$base.$sfx.jpg"
    curl -fsS -m 30 "$BASE/debug/ui-shot?which=$which&path=$png" >/dev/null 2>&1
    sleep "$settle"
    for attempt in 1 2 3; do
        rm -f "$png"
        if curl -fsS -m 30 "$BASE/debug/ui-shot?which=$which&path=$png" | grep -q '"png"' && [ -s "$png" ] \
           && sips -s format jpeg -s formatOptions 85 "$png" --out "$jpg" >/dev/null 2>&1; then
            printf "  %-26s %s\n" "$base" "$sfx"; return 0
        fi
        sleep 1
    done
    echo "  FAILED $base ($sfx)" >&2; return 1
}

# offline BASE SUFFIX LOCALE WHAT — a self-rendered view (__shot-ui), no app.
offline() {
    local base="$1" sfx="$2" loc="$3" what="$4"
    want "$base" || return 0
    local png="$TMP/$base.$sfx.png"
    rm -f "$png"
    "$BIN" __shot-ui "$what" "$png" -AppleLanguages "($loc)" >/dev/null 2>&1
    [ -s "$png" ] && sips -s format jpeg -s formatOptions 85 "$png" --out "$OUT/$base.$sfx.jpg" >/dev/null 2>&1 \
        && printf "  %-26s %s\n" "$base" "$sfx" || echo "  FAILED $base ($sfx)" >&2
}

session_id() { python3 -c "import json,sys; print(json.load(open('$TMP/seed.json'))['sessions'][sys.argv[1]])" "$1"; }

# ── Per locale ──────────────────────────────────────────────────────────

for entry in "${ALL_LOCALES[@]}"; do
    set -- $entry; loc="$1"; sfx="$2"
    if [ ${#WANT_SUFFIXES[@]} -gt 0 ] && [[ ! " ${WANT_SUFFIXES[*]} " == *" $sfx "* ]]; then continue; fi
    echo "── $loc ($sfx)"

    # 1. First-run wizard, one launch per step.
    for step in welcome scan pick models done; do
        case $step in
            welcome) base=onboarding-welcome ;; scan) base=onboarding-credentials ;;
            pick) base=onboarding-import ;; models) base=onboarding-models ;; done) base=onboarding-done ;;
        esac
        want "$base" || continue
        if [ "$step" = welcome ]; then launch "$loc" || continue
        else launch "$loc" BROMURE_DEBUG_WIZARD="$step" || continue; fi
        sleep 3
        shoot picker "$base" "$sfx" 3
    done

    # 2. The demo fixture.
    launch "$loc" || continue
    editor seed-demo "\"spec\":\"$FIXTURE/spec.json\"" > "$TMP/seed.json" || { echo "  seed failed" >&2; continue; }
    curl -fsS -m 10 -X PUT -d '{"providers":[{"provider":"anthropic","apiKey":"sk-ant-demo-0000000000","useSubscription":false},{"provider":"openai","apiKey":"sk-demo-0000000000","useSubscription":false},{"provider":"openrouter","apiKey":"sk-or-demo-0000000000","useSubscription":false}],"tiers":[],"agentTiers":[],"localRunModels":[]}' \
        "$BASE/models/settings" >/dev/null
    sleep 2

    if want automation-board || want task-board; then
        editor seed-board-demo '"profile":"Web app"' >/dev/null; sleep 1
        shoot board automation-board "$sfx" 3
        shoot tasks task-board "$sfx" 3
    fi
    shoot "session:$(session_id 'Add Apple Pay to checkout')"      sessions-home    "$sfx" 4
    shoot "session:$(session_id 'Fix double charge on checkout')"  session-question "$sfx" 4
    shoot "session:$(session_id 'Refund webhook retries')"         session-branch   "$sfx" 4
    shoot "session:$(session_id 'Stream the nightly CSV export')"  session-rest     "$sfx" 4
    shoot "session:$(session_id 'Switchboard')"                    switchboard      "$sfx" 4
    if want room-stage || want room-zoom; then
        rid=$(python3 -c "import json; print(json.load(open('$H/Library/Application Support/BromureAC/rooms.json'))[0]['id'])")
        fatclient room-show "\"room\":\"$rid\"" >/dev/null; sleep 5
        shoot default room-stage "$sfx" 4
        fatclient room-zoom "\"session\":\"$(session_id 'Add Apple Pay to checkout')\"" >/dev/null; sleep 2
        shoot default room-zoom "$sfx" 3
        fatclient room-zoom >/dev/null
    fi
    if want sidebar-rail; then
        editor sidebar >/dev/null; sleep 1
        shoot "session:$(session_id 'Upgrade to React 19')" sidebar-rail "$sfx" 3
        editor sidebar >/dev/null; sleep 1
    fi
    shoot newsession   new-session       "$sfx" 3
    shoot machines     machines          "$sfx" 3
    shoot newcluster   kube-new-cluster  "$sfx" 3
    shoot newregistry  registry-new      "$sfx" 3
    shoot "rewind:Web%20app" rewind-home   "$sfx" 3   # after the others: its sheet stays up
    if want connector-window; then
        local_post /connector '{"action":"window"}' >/dev/null; sleep 2
        shoot connector connector-window "$sfx" 2
    fi
    if want security-overview; then
        editor seed-security-timeline >/dev/null; sleep 1
        shoot timeline security-overview "$sfx" 3
    fi

    # ⌘K last: it stays open over the main window.
    shoot palette command-palette "$sfx" 2

    # 3. Settings: the workspace editor's panes, then Preferences › Models.
    editor open '"profile":"Web app"' >/dev/null; sleep 1.5
    # category key : file name (the manual's historical names)
    for pair in general:general appearance:appearance models:models fusion:fusion folders:folders \
                environment:environment mcp:mcp browser:browser resources:resources \
                credentials:credentials tracing:tracing guardrails:guardrails \
                supplychain:supply-chain promptinjection:prompt-injection piiprotection:pii-protection; do
        cat="${pair%%:*}"; name="editor-${pair##*:}"
        want "$name" || continue
        editor category "\"category\":\"$cat\"" >/dev/null; sleep 1
        shoot editor "$name" "$sfx" 1
    done
    editor close >/dev/null; sleep 1
    if want preferences-models || want preferences-automation; then
        shoot preferences preferences-models "$sfx" 2 >/dev/null   # opens it
        editor category '"category":"models"' >/dev/null; sleep 1.5
        shoot preferences preferences-models "$sfx" 1
        editor category '"category":"automation"' >/dev/null; sleep 1.5
        shoot preferences preferences-automation "$sfx" 1
    fi

    # Self-rendered views (no app window needed).
    offline security-timeline "$sfx" "$loc" timeline
done

echo "Done: $(ls "$OUT"/*.jpg 2>/dev/null | wc -l | tr -d ' ') images in manual/images"
