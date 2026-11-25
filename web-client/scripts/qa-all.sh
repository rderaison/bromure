#!/bin/bash
# qa-all.sh — render every surface that has a native reference, in light and
# dark, and print the mean-abs-diff table (0 = identical). Needs the demo
# server + dev relay (README) and the native references (capture-references.sh;
# REF_SUFFIX=-dark for .reference-dark with the server switched to dark).
#   scripts/qa-all.sh [OUTDIR]
set -u
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bromure-qa}; mkdir -p "$OUT"
npx vite build --outDir .build-qa >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }
node electron/build.mjs >/dev/null

# name | reference | query | js | w h
ROWS=(
"session-working|session-working|dev=demo|void __bromure.showSession('Add Apple Pay to checkout')|1320 944"
"session-question|session-question|dev=demo|void __bromure.showSession('Fix double charge on checkout')|1320 944"
"session-branch|session-branch|dev=demo|void __bromure.showSession('Refund webhook retries')|1320 944"
"session-paused|session-paused|dev=demo|void __bromure.showSession('Stream the nightly CSV export')|1320 944"
"session-ready|session-ready|dev=demo|void __bromure.showSession('Checkout load test')|1320 944"
"switchboard|switchboard|dev=demo|void __bromure.showSession('Switchboard')|1320 944"
"task-board|task-board|dev=demo|void __bromure.boards.taskBoard()|1320 944"
"automation-board|automation-board|dev=demo|void __bromure.boards.automationBoard('runs')|1320 944"
"new-session|new-session|dev=demo|void __bromure.newSession()|1320 944"
)
for c in general appearance models fusion squelch folders environment mcp browser resources credentials tracing guardrails sandboxpolicy supplychain promptinjection piiprotection; do
  ROWS+=("editor-$c|editor-$c|dev=demo&editor=Web%20app&editorCat=$c&editorInactive=1||880 872")
done

run() {   # run THEME
  local theme=$1 refdir=.reference; [ "$theme" = dark ] && refdir=.reference-dark
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name ref query js wh <<<"$row"
    set -- $wh
    [ -f "$refdir/$ref.png" ] || continue
    local png="$OUT/$name.$theme.png"
    node scripts/shot.mjs "$png" --dist .build-qa --query "$query" ${js:+--js "$js"} --w "$1" --h "$2" \
      $([ "$theme" = dark ] && echo --dark) --delay 8000 >/dev/null 2>&1 &
    while [ "$(jobs -r | wc -l)" -ge 4 ]; do sleep 1; done
  done
  wait
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name ref _ <<<"$row"
    [ -f "$refdir/$ref.png" ] && [ -f "$OUT/$name.$theme.png" ] || continue
    printf "%-28s %-5s %s\n" "$name" "$theme" "$(python3 scripts/compare.py "$refdir/$ref.png" "$OUT/$name.$theme.png" "$OUT/$name.$theme.cmp.png" --scale 0.33 | sed -E 's/.*diff: ([0-9.]+).*/\1/')"
  done
}
run light
run dark
