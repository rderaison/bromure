#!/bin/bash
# demo-server.sh — run an ISOLATED bromure-ac as a fat-client server loaded with
# the manual's synthetic demo fixture, for developing/testing the web client
# against the real protocol (and for reference renders via /debug/ui-shot).
#
#   web-client/scripts/demo-server.sh start [pubkey-file]   # launch + seed + enable SSH
#   web-client/scripts/demo-server.sh stop
#   web-client/scripts/demo-server.sh shot WHICH OUT.png    # offscreen render of a native window
#
# Isolation: CFFIXED_USER_HOME (support dir), BROMURE_AC_AUTOMATION_PORT,
# BROMURE_AC_REMOTE_PORT. UserDefaults are NOT relocated by CFFIXED_USER_HOME,
# so the real preferences plist is backed up on start and restored on stop.
# Never run while the user's own Bromure Agentic Coding is up on this Mac.

set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BIN="$ROOT/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
H=${DEMO_HOME:-/private/tmp/brmW}
APORT=${DEMO_API_PORT:-9323}
RPORT=${DEMO_SSH_PORT:-2399}
BASE="http://127.0.0.1:$APORT"
SUP="$H/Library/Application Support/BromureAC"
SOCK="$SUP/control.sock"
REAL="$HOME/Library/Application Support/BromureAC"
PREFS="$HOME/Library/Preferences/io.bromure.agentic-coding.plist"
STATE=${DEMO_STATE:-/private/tmp/brmW-state}
mkdir -p "$STATE"

pids() {   # bromure-ac processes whose env carries our isolated home
  for p in $(pgrep -f 'MacOS/bromure-ac' 2>/dev/null); do
    ps eww -o command= -p "$p" 2>/dev/null | grep -q "CFFIXED_USER_HOME=$H" && echo "$p"
  done
}

case "${1:-}" in
start)
  [ -x "$BIN" ] || { echo "build first: ./build.sh bromure-ac" >&2; exit 1; }
  [ -n "$(pids)" ] && { echo "demo server already running"; exit 0; }
  [ -f "$PREFS" ] && [ ! -f "$STATE/prefs-backup.plist" ] && cp "$PREFS" "$STATE/prefs-backup.plist"
  rm -rf "$H"; mkdir -p "$SUP"
  for f in base.version image-state.json alpine-vmlinuz alpine-initramfs alpine-initramfs-shimmed catalog.json img-catalog.json; do
    [ -e "$REAL/$f" ] && cp "$REAL/$f" "$SUP/$f"
  done
  cp "$REAL/efivars.bin" "$SUP/efivars.bin"
  cp -c "$REAL/base.img" "$SUP/base.img"      # APFS clone: needed for the SSH front door
  python3 scripts/manual-demo/make-fixture.py "$STATE/fixture" >/dev/null
  env BROMURE_DEBUG_CLAUDE=1 BROMURE_AC_APPEARANCE="${APPEARANCE:-light}" CFFIXED_USER_HOME="$H" \
      BROMURE_AC_AUTOMATION_PORT=$APORT BROMURE_AC_REMOTE_PORT=$RPORT \
      "$BIN" run -AppleLanguages "(${DEMO_LOCALE:-en})" > "$STATE/app.log" 2>&1 &
  for _ in $(seq 1 80); do curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fsS -m 2 "$BASE/health" >/dev/null || { echo "app did not come up (see $STATE/app.log)" >&2; exit 1; }
  curl -fsS -m 30 -X POST -H 'Content-Type: application/json' \
       -d "{\"action\":\"seed-demo\",\"spec\":\"$STATE/fixture/spec.json\"}" "$BASE/debug/editor" > "$STATE/seed.json"
  curl -fsS -m 30 -X POST -H 'Content-Type: application/json' -d '{"action":"seed-board-demo","profile":"Web app"}' "$BASE/debug/editor" >/dev/null || true
  curl -fsS -m 30 -X POST -H 'Content-Type: application/json' -d '{"action":"seed-security-timeline"}' "$BASE/debug/editor" >/dev/null || true
  curl -fsS -m 10 --unix-socket "$SOCK" -X POST \
       -d "{\"enabled\":true,\"port\":$RPORT,\"bindAddress\":\"127.0.0.1\",\"pubkeyAuth\":true,\"passwordAuth\":false}" http://x/remote >/dev/null
  if [ -n "${2:-}" ]; then
    python3 -c 'import json,sys;print(json.dumps({"key":open(sys.argv[1]).read().strip()}))' "$2" \
      | curl -fsS -m 10 --unix-socket "$SOCK" -X POST -d @- http://x/remote/keys >/dev/null
  fi
  echo "demo server up: ssh 127.0.0.1:$RPORT user=$(whoami)  api=$BASE  sock=$SOCK"
  ;;
stop)
  for p in $(pids); do kill "$p" 2>/dev/null; done
  sleep 2
  for p in $(pids); do kill -9 "$p" 2>/dev/null; done
  if [ -f "$STATE/prefs-backup.plist" ]; then
    cp "$STATE/prefs-backup.plist" "$PREFS"; rm -f "$STATE/prefs-backup.plist"
    defaults read io.bromure.agentic-coding >/dev/null 2>&1
  fi
  echo stopped
  ;;
shot)
  curl -fsS -m 30 "$BASE/debug/ui-shot?which=$2&path=$3" >/dev/null; sleep "${4:-2}"
  curl -fsS -m 30 "$BASE/debug/ui-shot?which=$2&path=$3"
  ;;
*) echo "usage: $0 start [pubkey-file] | stop | shot WHICH OUT.png" >&2; exit 2 ;;
esac
