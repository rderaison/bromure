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
npx vite build --base=/client/ --outDir .build-qa >/dev/null 2>&1 && node electron/build.mjs >/dev/null || exit 1
pkill -f "scripts/fake-cloud.mjs" 2>/dev/null; sleep 0.5
FAKE_CLOUD_STATIC="$(pwd)/.build-qa" node scripts/fake-cloud.mjs >"$LOG" 2>&1 & FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1
# The page is served by the fake cloud itself (same origin as /api, like
# bromure.io/client), so the httpOnly-cookie device identity works for real.
RES=$(node scripts/shot.mjs "$OUT" --web --url http://127.0.0.1:5190/client/index.html --query "devRelay=ws://127.0.0.1:5179" --delay 5000 --after 26000 --js "void (async()=>{
  const A = window.__bromure.account;
  sessionStorage.setItem('bromure.enroll.state', JSON.stringify({state:'S1', api:'http://127.0.0.1:5190/api'}));
  await A.complete('#enroll?code=X&api=https://evil.example&state=S1');
  console.error('E2E foreign-api-refused=' + !A.get().record);
  sessionStorage.setItem('bromure.enroll.state', JSON.stringify({state:'S2', api:'http://127.0.0.1:5190/api'}));
  await A.complete('#enroll?code=TESTCODE&state=S2');
  console.error('E2E enrolled=' + !!A.get().record);
  console.error('E2E token-not-readable=' + (A.get().record?.deviceToken === '' && !document.cookie.includes('bromure_device')));
  await new Promise(r => setTimeout(r, 3000));
  // As after a reload: the CSRF token is gone from memory and the Path=/api
  // cookie can't be read — the dial's POST must re-learn it (heartbeat) first.
  window.__bromure.forgetCsrf();
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // The server menu's items, clicked as a user would (menus act on mouseup).
  const pick = async label => {
    document.querySelector('.tb-server').click(); await sleep(300);
    const it = [...document.querySelectorAll('.menu-item')].find(e => e.textContent.includes(label));
    it?.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); await sleep(1500);
    return !!it;
  };
  const mirrored = () => !!document.querySelector('.hw-sidebar');
  location.hash = '#/peer/srv-demo-0001';
  await sleep(8000);
  console.error('E2E mirrored=' + mirrored());
  console.error('E2E menu-connect-another=' + ((await pick('Connect to Another Server')) && !mirrored() && !!document.querySelector('.cx-picker')));
  location.hash = '#/peer/srv-demo-0001';
  await sleep(4000);
  console.error('E2E menu-disconnect=' + (mirrored() && (await pick('Disconnect')) && !mirrored() && !!document.querySelector('.cx-picker')));
})()" 2>&1)
echo "$RES" | grep -o 'E2E [a-z-]*=[a-z]*'
grep -q 'relay paired' "$LOG" && echo "E2E relay-paired=true" || echo "E2E relay-paired=false"
grep -q 'cookie delivery' "$LOG" && echo "E2E cookie-delivery=true" || echo "E2E cookie-delivery=false"
grep -q 'CSRF rejected' "$LOG" && echo "E2E csrf-ok=false" || echo "E2E csrf-ok=true"
grep -q 'csrf fetched' "$LOG" && echo "E2E csrf-refetched=true" || echo "E2E csrf-refetched=false"
echo "$RES" | grep -q 'mirrored=true' && grep -q 'menu-connect-another=true' <<<"$RES" && grep -q 'menu-disconnect=true' <<<"$RES" && grep -q 'refused=true' <<<"$RES" && grep -q 'token-not-readable=true' <<<"$RES" \
  && grep -q 'relay paired' "$LOG" && grep -q 'cookie delivery' "$LOG" && grep -q 'csrf fetched' "$LOG" && ! grep -q 'CSRF rejected' "$LOG"
