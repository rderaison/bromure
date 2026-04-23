// Bromure Corporate Guard — service worker.
//
// Reads corporateWebsites + openExternalInPrivate + tracingEnabled from
// chrome.storage.managed (delivered per-session by config-agent via the
// `3rdparty.extensions.<ext-id>` path of /etc/chromium/policies/managed/).
//
// Behavior (MV3):
//
//   openExternalInPrivate = true
//     On every top-frame nav to a non-corporate HTTPS/HTTP host in the
//     current managed session: cancel the original navigation (redirect
//     to about:blank) and hand the URL off to the host via native
//     messaging. The host decides where to open it — typically routing
//     into an existing Bromure private-browsing profile session if one
//     is open, otherwise spawning a new one. Same mechanism the
//     link-sender extension uses for user-initiated cross-profile
//     opens; corporate-guard does it automatically for out-of-policy
//     hosts.
//
//   openExternalInPrivate = false (+ tracingEnabled)
//     Redirect path is a no-op. The content script handles the amber
//     banner on non-corporate pages.

try { importScripts("common.js"); } catch (e) { console.error("[corporate-guard] importScripts failed:", e); }

const { normalizeHost, isCorporateHost, isInterestingURL } = self.CorpGuard;

// Default-safe policy. Overridden by chrome.storage.managed.
let policy = {
  corporateWebsites: [],
  openExternalInPrivate: false,
  tracingEnabled: false,
};

async function loadPolicy() {
  try {
    const stored = await chrome.storage.managed.get([
      "corporateWebsites",
      "openExternalInPrivate",
      "tracingEnabled",
    ]);
    policy = {
      corporateWebsites: Array.isArray(stored.corporateWebsites) ? stored.corporateWebsites : [],
      openExternalInPrivate: stored.openExternalInPrivate === true,
      tracingEnabled: stored.tracingEnabled === true,
    };
  } catch (e) {
    // Managed storage might simply be empty (unmanaged session). Keep
    // the safe defaults.
  }
}

chrome.runtime.onInstalled.addListener(loadPolicy);
chrome.runtime.onStartup.addListener(loadPolicy);
chrome.storage.onChanged.addListener((_changes, area) => {
  if (area === "managed") loadPolicy();
});

// Warm-load: a service worker woken by a webNavigation event needs the
// policy in memory, but onStartup/onInstalled won't fire on every wake.
loadPolicy();

// ---------------------------------------------------------------------
// Handoff to the host
// ---------------------------------------------------------------------

// Name must match the native-messaging host manifest at
// /etc/chromium/native-messaging-hosts/com.bromure.corporate_guard.json.
const NATIVE_HOST = "com.bromure.corporate_guard";

function sendExternalToHost(url) {
  try {
    chrome.runtime.sendNativeMessage(
      NATIVE_HOST,
      { type: "open_external", url },
      () => {
        // Intentionally ignore errors — the native messaging host may
        // not be registered in unmanaged sessions, and we don't want
        // the extension's service worker to crash-loop over that.
        const err = chrome.runtime.lastError;
        if (err) console.warn("[corporate-guard] native message failed:", err.message);
      }
    );
  } catch (e) {
    console.warn("[corporate-guard] sendNativeMessage threw:", e);
  }
}

async function handleBeforeNavigate(details) {
  // Only top-frame navigations. Sub-frame gating would break sites that
  // embed third-party content (ads, analytics, auth widgets) — those
  // don't need the bouncer.
  if (details.frameId !== 0) return;
  if (!policy.openExternalInPrivate) return;
  if (!isInterestingURL(details.url)) return;

  let tab;
  try { tab = await chrome.tabs.get(details.tabId); } catch (_) { return; }
  if (!tab) return;

  let targetHost;
  try { targetHost = new URL(details.url).hostname; } catch (_) { return; }

  if (isCorporateHost(targetHost, policy.corporateWebsites)) return;

  // Non-corporate nav in the managed session. Hand the URL to the host
  // for opening in a private Bromure profile, then redirect the original
  // tab to about:blank so the external URL doesn't render here. We
  // don't close the tab (closing the last tab in a window closes the
  // whole window, which surprises users mid-session).
  try {
    sendExternalToHost(details.url);
    await chrome.tabs.update(details.tabId, { url: "about:blank" });
  } catch (e) {
    console.warn("[corporate-guard] failed to hand off nav:", e);
  }
}

chrome.webNavigation.onBeforeNavigate.addListener(handleBeforeNavigate);
