#!/bin/bash
# hosted-e2e.sh — the hosted (browser) client's whole bromure.io path, end to end,
# against scripts/fake-cloud.mjs (the agreed infra contract) and the demo server:
# sign-in callback (state + API bound at sign-in; a foreign `api=` is refused) →
# Ed25519 enrollment → SSH key publish → directory → grant → signaling offer
# (bearer in Sec-WebSocket-Protocol) → ws-relay → SSH end to end → mirror.
# The page runs WITHOUT the Electron bridge (BROMURE_AS_WEB), i.e. as the hosted app.
set -u
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bromure-hosted-e2e.png}
LOG=$(mktemp)
npx vite build --outDir .build-qa >/dev/null 2>&1 && node electron/build.mjs >/dev/null || exit 1
pkill -f "scripts/fake-cloud.mjs" 2>/dev/null; sleep 0.5
node scripts/fake-cloud.mjs >"$LOG" 2>&1 & FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1
RES=$(node scripts/shot.mjs "$OUT" --web --dist .build-qa --query "devRelay=ws://127.0.0.1:5179" --delay 5000 --after 12000 --js "void (async()=>{
  const A = window.__bromure.account;
  sessionStorage.setItem('bromure.enroll.state', JSON.stringify({state:'S1', api:'http://127.0.0.1:5190'}));
  await A.complete('#enroll?code=X&api=https://evil.example&state=S1');
  console.error('E2E foreign-api-refused=' + !A.get().record);
  sessionStorage.setItem('bromure.enroll.state', JSON.stringify({state:'S2', api:'http://127.0.0.1:5190'}));
  await A.complete('#enroll?code=TESTCODE&state=S2');
  console.error('E2E enrolled=' + !!A.get().record);
  await new Promise(r => setTimeout(r, 3000));
  location.hash = '#/peer/srv-demo-0001';
  setTimeout(() => console.error('E2E mirrored=' + !!document.querySelector('.hw-sidebar')), 8000);
})()" 2>&1)
echo "$RES" | grep -o 'E2E [a-z-]*=[a-z]*'
grep -q 'relay paired' "$LOG" && echo "E2E relay-paired=true" || echo "E2E relay-paired=false"
echo "$RES" | grep -q 'mirrored=true' && grep -q 'refused=true' <<<"$RES" && grep -q 'relay paired' "$LOG"
