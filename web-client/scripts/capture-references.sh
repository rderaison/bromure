#!/bin/bash
# capture-references.sh — offscreen renders of the NATIVE macOS windows, from
# the demo server (scripts/demo-server.sh start), as pixel targets for the web
# client. Output: web-client/.reference/<name>.png (gitignored).
#   APPEARANCE=dark is set at demo-server start time, not here.
set -u
cd "$(dirname "$0")/.."
OUT="$(pwd)/.reference${REF_SUFFIX:-}"
mkdir -p "$OUT"
BASE="http://127.0.0.1:${DEMO_API_PORT:-9323}"
SEED=/private/tmp/brmW-state/seed.json
sid() { python3 -c "import json,sys; print(json.load(open('$SEED'))['sessions'][sys.argv[1]])" "$1"; }
editor() { curl -fsS -m 30 -X POST -H 'Content-Type: application/json' -d "{\"action\":\"$1\"${2:+,$2}}" "$BASE/debug/editor" >/dev/null; }
fatclient() { curl -fsS -m 30 -X POST -d "{\"action\":\"$1\"${2:+,$2}}" "$BASE/debug/fatclient" >/dev/null; }
shoot() {   # shoot WHICH NAME [settle]
  local png="$OUT/$2.png"
  curl -fsS -m 30 "$BASE/debug/ui-shot?which=$1&path=$png" >/dev/null 2>&1; sleep "${3:-2}"
  rm -f "$png"
  curl -fsS -m 30 "$BASE/debug/ui-shot?which=$1&path=$png" >/dev/null 2>&1
  [ -s "$png" ] && echo "  $2" || echo "  FAILED $2" >&2
}
for s in "Add Apple Pay to checkout:session-working" "Fix double charge on checkout:session-question" \
         "Refund webhook retries:session-branch" "Stream the nightly CSV export:session-paused" \
         "Switchboard:switchboard" "Upgrade to React 19:session-working2" "Tighten the onboarding copy:session-archived" \
         "Checkout load test:session-ready"; do
  shoot "session:$(sid "${s%%:*}")" "${s##*:}" 3
done
rid=$(python3 -c "import json; print(json.load(open('/private/tmp/brmW/Library/Application Support/BromureAC/rooms.json'))[0]['id'])" 2>/dev/null)
if [ -n "$rid" ]; then
  fatclient room-show "\"room\":\"$rid\""; sleep 4; shoot default room-stage 3
  fatclient room-zoom "\"session\":\"$(sid 'Add Apple Pay to checkout')\""; sleep 2; shoot default room-zoom 3
  fatclient room-zoom
fi
editor sidebar; sleep 1; shoot "session:$(sid 'Upgrade to React 19')" sidebar-rail 3; editor sidebar; sleep 1
shoot newsession new-session 3
shoot machines machines 3
shoot newcluster kube-new-cluster 3
shoot newregistry registry-new 3
shoot board automation-board 3
shoot tasks task-board 3
shoot timeline security-overview 3
editor open '"profile":"Web app"'; sleep 1.5
for cat in general appearance models fusion squelch folders environment mcp browser resources credentials tracing guardrails sandboxpolicy supplychain promptinjection piiprotection; do
  editor category "\"category\":\"$cat\""; sleep 1
  shoot editor "editor-$cat" 1
done
editor close; sleep 1
shoot preferences preferences 2
for cat in general models automation; do
  editor category "\"category\":\"preferences:$cat\""; sleep 1.2
  shoot preferences "preferences-$cat" 1
done
# ⌘K last: nothing closes it remotely, so it stays open over the main window.
shoot palette command-palette 2
echo "done: $(ls "$OUT" | wc -l | tr -d ' ') images in $OUT"
