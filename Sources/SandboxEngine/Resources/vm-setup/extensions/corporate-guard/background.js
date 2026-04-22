// Bromure Corporate Guard — service worker.
//
// Reads corporateWebsites + openExternalInPrivate + tracingEnabled from
// chrome.storage.managed (delivered per-session by config-agent via the
// `3rdparty.extensions.<ext-id>` path of /etc/chromium/policies/managed/).
//
// Behavior (MV3):
//
//   openExternalInPrivate = true
//     On every top-frame nav to a non-corporate HTTPS/HTTP host in a
//     *non-incognito* tab: cancel the original navigation (redirect to
//     about:blank) and reopen the URL in an incognito tab. If an
//     incognito window already exists, the URL becomes a new tab in
//     that window; otherwise we create a fresh incognito window.
//     The current Chromium process (and VM) is reused — no new session
//     is spawned.
//
//   openExternalInPrivate = false (+ tracingEnabled)
//     Redirection path is a no-op. The content script handles the
//     amber banner on non-corporate pages.
//
// Any navigation already happening inside an incognito tab is skipped
// entirely so we don't ping-pong what we just created.

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
// Incognito routing
// ---------------------------------------------------------------------

async function openInIncognito(url) {
  // Prefer an existing incognito window so we don't scatter windows.
  const all = await chrome.windows.getAll({});
  const existing = all.find(w => w.incognito);
  if (existing) {
    await chrome.tabs.create({ windowId: existing.id, url, active: true });
    await chrome.windows.update(existing.id, { focused: true });
    return;
  }
  await chrome.windows.create({ incognito: true, url });
}

async function handleBeforeNavigate(details) {
  // Only top-frame navigations. Sub-frame gating would break most sites
  // that embed third-party content (ads, analytics, auth widgets) —
  // those don't need the bouncer.
  if (details.frameId !== 0) return;
  if (!policy.openExternalInPrivate) return;
  if (!isInterestingURL(details.url)) return;

  let tab;
  try { tab = await chrome.tabs.get(details.tabId); } catch (_) { return; }
  if (!tab) return;

  // Already in an incognito tab → let the navigation proceed.
  if (tab.incognito) return;

  let targetHost;
  try { targetHost = new URL(details.url).hostname; } catch (_) { return; }

  if (isCorporateHost(targetHost, policy.corporateWebsites)) return;

  // Non-corporate nav from a normal window. Swap it.
  //
  //   1. Open the URL in incognito (new tab in existing incog window, or
  //      spin up a fresh one).
  //   2. Redirect the original tab to about:blank so the external URL
  //      never renders in the normal context. We don't close the tab
  //      (closing the last tab in a window closes the whole window,
  //      which would surprise users mid-session).
  try {
    await openInIncognito(details.url);
    await chrome.tabs.update(details.tabId, { url: "about:blank" });
  } catch (e) {
    console.warn("[corporate-guard] failed to reopen in incognito:", e);
  }
}

chrome.webNavigation.onBeforeNavigate.addListener(handleBeforeNavigate);
