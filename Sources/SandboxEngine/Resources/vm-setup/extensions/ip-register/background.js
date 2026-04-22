// Bromure IP Register — managed-session heartbeat
//
// Posts a tiny request to analytics.bromure.io/register-ip every minute.
// The request body carries no IP; the server takes the egress IP off the
// TLS connection (via HAProxy's X-Forwarded-For). We rely on:
//
//   1. `fetch()` going through Chromium's network stack, so whatever VPN
//      / WARP / proxy the managed session is routing through is what
//      shows up on the wire. Critical correctness property — this is why
//      the heartbeat lives in the browser, not in the host Bromure.app.
//   2. The existing `AutoSelectCertificateForUrls` managed-policy entry
//      for https://analytics.bromure.io, which auto-presents the managed
//      profile's leaf cert during TLS handshake. No cert handling here.
//   3. MV3 alarms, which wake the service worker on their cadence even
//      after Chromium idles the worker out of memory. `setInterval`
//      wouldn't survive that.
//
// Only loaded for managed sessions (config-agent gates on cfg["mtls"]).

const ENDPOINT = "https://analytics.bromure.io/register-ip";
const ALARM_NAME = "bromure-ip-register";
const PERIOD_MINUTES = 1;
const BODY = JSON.stringify({ schemaVersion: 1 });

async function ping() {
  try {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: BODY,
      // Don't let cookies from other tabs pollute the connection reuse.
      credentials: "omit",
      cache: "no-store",
    });
    if (!res.ok && res.status !== 204) {
      console.warn("[ip-register] non-OK response:", res.status);
    }
  } catch (e) {
    console.warn("[ip-register] fetch failed:", (e && e.message) || e);
  }
}

function ensureAlarm() {
  // create() is idempotent by name; safe to call from multiple lifecycle
  // hooks without accumulating alarms.
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: PERIOD_MINUTES });
}

// Fire an immediate ping as soon as the service worker wakes, in both
// fresh-install and browser-launch cases. This matters because the very
// first thing the user does is often hit Workspace; we don't want to
// wait up to 60s for the first alarm tick.
chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  ping();
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  ping();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    ping();
  }
});
