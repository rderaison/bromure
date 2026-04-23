// Bromure Corporate Guard — service worker.

console.log("[corporate-guard] SW module load");

try { importScripts("common.js"); } catch (e) { console.error("[corporate-guard] importScripts failed:", e); }

// Never re-declare names that common.js puts on the global scope
// (BUILT_IN_ALLOWLIST const, normalizeHost/isCorporateHost/isInterestingURL
// function declarations). A `const` collision during importScripts kills
// the service worker before any listener registers. Reference common.js
// exports via self.CorpGuard instead of destructuring.
const CG = self.CorpGuard;
if (!CG) console.error("[corporate-guard] common.js did not export CorpGuard");

const REDIRECT_RULE_ID = 1;
const BLOCKED_URL = chrome.runtime.getURL("blocked.html");

async function readPolicy() {
  try {
    // Pull ALL managed keys so we can tell "policy not yet delivered"
    // (empty object) from "policy explicitly omits these keys".
    // Chromium delivers chrome.storage.managed asynchronously after SW
    // start, so the first read on install can be empty for a beat.
    const stored = await chrome.storage.managed.get(null);
    console.log("[corporate-guard] policy:", stored);
    return {
      loaded: Object.keys(stored).length > 0,
      corporateWebsites: Array.isArray(stored.corporateWebsites) ? stored.corporateWebsites : [],
      openExternalInPrivate: stored.openExternalInPrivate === true,
      tracingEnabled: stored.tracingEnabled === true,
    };
  } catch (e) {
    console.warn("[corporate-guard] storage.managed.get threw:", e);
    return { loaded: false, corporateWebsites: [], openExternalInPrivate: false, tracingEnabled: false };
  }
}

async function syncRules() {
  const policy = await readPolicy();

  // Treat "no managed storage yet" as "don't touch the rule" — removing
  // it on a cold start before policy is delivered would briefly let
  // out-of-scope navs through. onChanged will re-fire syncRules once
  // Chromium finishes pushing the 3rdparty policy.
  if (!policy.loaded) {
    console.log("[corporate-guard] managed storage not yet populated; leaving rule state alone");
    return;
  }

  const remove = { removeRuleIds: [REDIRECT_RULE_ID] };

  if (!policy.openExternalInPrivate) {
    try { await chrome.declarativeNetRequest.updateDynamicRules(remove); } catch (e) { console.warn("[corporate-guard] updateDynamicRules(remove) failed:", e); }
    console.log("[corporate-guard] openExternalInPrivate is false → no redirect rule");
    return;
  }

  const excluded = [
    ...BUILT_IN_ALLOWLIST,
    ...policy.corporateWebsites.map((h) => CG.normalizeHost(h)).filter(Boolean),
  ];

  const rule = {
    id: REDIRECT_RULE_ID,
    priority: 1,
    action: { type: "redirect", redirect: { url: BLOCKED_URL } },
    condition: {
      resourceTypes: ["main_frame"],
      urlFilter: "|http",
      excludedRequestDomains: excluded,
    },
  };

  try {
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: [REDIRECT_RULE_ID],
      addRules: [rule],
    });
    const active = await chrome.declarativeNetRequest.getDynamicRules();
    console.log("[corporate-guard] dNR rules after install:", active);
  } catch (e) {
    console.error("[corporate-guard] updateDynamicRules failed:", e, "rule=", rule);
  }
}

chrome.runtime.onInstalled.addListener(() => { console.log("[corporate-guard] onInstalled"); syncRules(); });
chrome.runtime.onStartup.addListener(() => { console.log("[corporate-guard] onStartup"); syncRules(); });
chrome.storage.onChanged.addListener((_changes, area) => {
  if (area === "managed") { console.log("[corporate-guard] managed storage changed → re-sync"); syncRules(); }
});
syncRules();

// ---------------------------------------------------------------------
// Handoff to the host
// ---------------------------------------------------------------------

// Reuse LinkSender's native messaging host + vsock bridge, with the
// exact same long-lived connectNative pattern link-sender uses. One
// persistent port means no per-click process spawn, no SW-idle race
// mid-handoff, and no 3-second reconnect loop in link-agent.py adding
// minutes of perceived latency.
const NATIVE_HOST = "com.bromure.link_sender";

let nativePort = null;

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[corporate-guard] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener((msg) => {
    console.log("[corporate-guard] host response:", msg);
  });

  nativePort.onDisconnect.addListener(() => {
    console.log(
      "[corporate-guard] native host disconnected",
      chrome.runtime.lastError?.message || ""
    );
    nativePort = null;
    setTimeout(connectNative, 3000);
  });
}

connectNative();

function sendExternalToHost(url) {
  if (!nativePort) {
    connectNative();
    if (!nativePort) {
      console.error("[corporate-guard] cannot reach host");
      return;
    }
  }
  nativePort.postMessage({ type: "open_in_profile", url });
}

async function handleBeforeNavigate(details) {
  if (details.frameId !== 0) return;
  if (!CG || !CG.isInterestingURL(details.url)) return;
  if (details.url.startsWith(BLOCKED_URL)) return;

  const policy = await readPolicy();
  if (!policy.openExternalInPrivate) return;

  let targetHost;
  try { targetHost = new URL(details.url).hostname; } catch (_) { return; }
  if (CG.isCorporateHost(targetHost, policy.corporateWebsites)) return;

  console.log("[corporate-guard] out-of-scope nav →", details.url);
  sendExternalToHost(details.url);
}

chrome.webNavigation.onBeforeNavigate.addListener(handleBeforeNavigate);
console.log("[corporate-guard] listeners registered; BLOCKED_URL =", BLOCKED_URL);
