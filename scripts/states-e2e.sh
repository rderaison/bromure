#!/bin/bash
# states-e2e.sh — two instances of one build on two states, side by side.
#
#   scripts/states-e2e.sh [<build>]      default: stable
#
# Checks (plan, Phase 1/2 tests): both answer /health on their own control
# socket with their own pid, distinct ephemeral automation ports, distinct
# persisted VM subnets (vmnet.switch.subnetBase172 in each state's settings
# suite), the instance lock refuses a third launch on a busy state, each
# quits over its own socket, and `state rm` cleans up. No VM is booted; the
# user's work state is never touched (the states start with work's images
# cloned in, nothing else). Everything goes through the build's own CLI:
# `state`, `instance`.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-stable}"
SUPPORT="$HOME/Library/Application Support"
# The builds folder is named after the build's data folder (dev flavor:
# BromureACDev), so read that off the bundle rather than guess it.
resolve_app() {
    local b="$1"
    if [ -d "$b/Contents/MacOS" ]; then echo "$b"; return; fi
    local f
    for f in "$SUPPORT"/*-builds/"$b"/*.app; do [ -d "$f" ] && { echo "$f"; return; }; done
    return 1
}
APP=$(resolve_app "$BUILD") || { echo "no build '$BUILD'" >&2; exit 1; }
BIN="$APP/Contents/MacOS/bromure-ac"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
STAMP=$(date +%H%M%S)
A="e2e-a-$STAMP"; B="e2e-b-$STAMP"
fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=$((fail+1)); fi; }

cleanup() {
    for s in "$A" "$B"; do "$BIN" instance stop "$s" >/dev/null 2>&1 || true; done
    for s in "$A" "$B"; do "$BIN" state rm "$s" -f >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

echo "== create two states with work's assets"
"$BIN" state create "$A" >/dev/null
"$BIN" state create "$B" >/dev/null
DIR_A=$("$BIN" state path "$A"); DIR_B=$("$BIN" state path "$B")
check "both listed" '"$BIN" state ls --no-size | grep -q "$A" && "$BIN" state ls --no-size | grep -q "$B"'

echo "== start two hidden instances of $BUILD"
"$BIN" instance start "$A" --build "$APP" --hidden
"$BIN" instance start "$B" --build "$APP" --hidden
HA=$("$BIN" instance health "$A"); HB=$("$BIN" instance health "$B")
field() { echo "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2"; }
PA=$(field "$HA" pid); PB=$(field "$HB" pid)
PORTA=$(field "$HA" automationPort); PORTB=$(field "$HB" automationPort)
echo "  $A: pid $PA port $PORTA   $B: pid $PB port $PORTB"
check "distinct pids" '[ -n "$PA" ] && [ -n "$PB" ] && [ "$PA" != "$PB" ]'
check "distinct ephemeral automation ports" '[ -n "$PORTA" ] && [ -n "$PORTB" ] && [ "$PORTA" != "$PORTB" ] && [ "$PORTA" != 9223 ]'
check "/health names the state" '[ "$(field "$HA" state)" = "$A" ] && [ "$(field "$HB" state)" = "$B" ]'
check "TCP /health on each port" 'curl -fsS -m 3 "http://127.0.0.1:$PORTA/health" >/dev/null && curl -fsS -m 3 "http://127.0.0.1:$PORTB/health" >/dev/null'

SA=$(defaults read "$BUNDLE_ID.state.$A" vmnet.switch.subnetBase172 2>/dev/null || echo none)
SB=$(defaults read "$BUNDLE_ID.state.$B" vmnet.switch.subnetBase172 2>/dev/null || echo none)
echo "  subnet bases: $A=$SA $B=$SB"
check "each state persisted its own VM subnet" '[ "$SA" != none ] && [ "$SB" != none ] && [ "$SA" != "$SB" ]'
check "work's settings untouched by the instances" '! defaults read "$BUNDLE_ID" 2>/dev/null | grep -q "state\.$A\|state\.$B"'

echo "== a third launch on a busy state is refused"
set +e
BROMURE_STATE="$A" "$BIN" run --headless 2>/tmp/states-e2e-third.err; rc=$?
set -e
check "exit 75 with the holder named" '[ "$rc" = 75 ] && grep -q "in use by pid $PA" /tmp/states-e2e-third.err'
set +e
"$BIN" instance start "$A" --build "$APP" --hidden >/dev/null 2>/tmp/states-e2e-again.err; rc=$?
set -e
check "instance start on a busy state is refused" '[ "$rc" != 0 ] && grep -q "already running" /tmp/states-e2e-again.err'

echo "== instance records"
check "instance.json has pid, build, port" 'python3 - "$DIR_A/instance.json" "$PA" "$PORTA" <<EOF
import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["pid"]==int(sys.argv[2]) and d["automationPort"]==int(sys.argv[3]) and d["build"] else 1)
EOF'
LS=$("$BIN" instance ls)   # into a variable: grep -q under pipefail would read as a failure
check "instance ls shows both" 'echo "$LS" | grep -c "^$A \|^$B " | grep -qx 2'
check "instance bin-path names the serving build" '[ "$("$BIN" instance bin-path "$A")" = "$BIN" ]'
check "instance cli reaches the state" '"$BIN" instance cli "$A" -- vm ls >/dev/null'

echo "== sync and quit over each socket"
check "POST /app/sync answers" 'curl -fsS -m 10 --unix-socket "$DIR_A/control.sock" -X POST -d "{}" http://x/app/sync | grep -q "\"ok\""'
"$BIN" instance stop "$A"
check "A gone, B alive" '! kill -0 "$PA" 2>/dev/null && kill -0 "$PB" 2>/dev/null'
check "A's instance.json removed, lock free" '[ ! -f "$DIR_A/instance.json" ]'
"$BIN" instance stop "$B"
check "B gone" '! kill -0 "$PB" 2>/dev/null'

echo "== remove"
"$BIN" state rm "$A" -f >/dev/null; "$BIN" state rm "$B" -f >/dev/null
check "states removed" '! "$BIN" state ls --no-size | grep -q "$A\|$B"'
# cfprefsd may keep (or recreate) an empty plist for a removed domain; what
# matters is that no setting survives.
empty_domain() { local v; v=$(defaults read "$1" 2>/dev/null | tr -d ' \n'); [ -z "$v" ] || [ "$v" = "{}" ]; }
check "settings suites emptied" 'empty_domain "$BUNDLE_ID.state.$A" && empty_domain "$BUNDLE_ID.state.$B"'

echo
if [ "$fail" = 0 ]; then echo "states-e2e: all checks passed"; else echo "states-e2e: $fail check(s) FAILED"; exit 1; fi
