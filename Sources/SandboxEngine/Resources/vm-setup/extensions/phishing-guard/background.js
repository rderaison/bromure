"use strict";

// ---------------------------------------------------------------------------
// Popular domains database (loaded from top-domains.json at startup)
// Source: Tranco list (https://tranco-list.eu) — top 100,000 most popular
// domains aggregated from multiple ranking providers.
// ---------------------------------------------------------------------------

let POPULAR_DOMAINS = new Set();

// Load the domain list on startup. The promise is awaited before processing
// any password-field messages to avoid false positives on popular sites.
const domainsReady = fetch(chrome.runtime.getURL("top-domains.json"))
  .then((r) => r.json())
  .then((domains) => {
    POPULAR_DOMAINS = new Set(domains);
    console.log(
      `[Phishing Guard] Loaded ${POPULAR_DOMAINS.size} popular domains`
    );
  })
  .catch((err) => {
    console.error("[Phishing Guard] Failed to load domain list:", err);
  });

// ---------------------------------------------------------------------------
// Blocklist: regex patterns for obvious phishing domains
// ---------------------------------------------------------------------------

const BLOCKLIST_PATTERNS = [
  /paypa[li1]-(?:secure|login|verify)/i,
  /app[li1]e-(?:id|support|verify)/i,
  /micr[o0]s[o0]ft-(?:login|secure|verify)/i,
  /g[o0]{2}g[li1]e-(?:login|secure|verify)/i,
  /amaz[o0]n-(?:secure|login|verify)/i,
  /netf[li1]ix-(?:login|secure|verify)/i,
  /faceb[o0]{2}k-(?:login|secure|verify)/i,
  /chasebank-(?:secure|login|verify)/i,
  /wellsfarg[o0]-(?:secure|login|verify)/i,
  /bankofamerica-(?:secure|login)/i,
  // Login/secure subdomains on disposable TLDs
  /(?:secure|login|verify|account)\..*\.(?:xyz|tk|ml|ga|cf|top|buzz|icu)$/i,
];

// Pending warnings: tabId -> { domain, url, verdict }
const pendingWarnings = new Map();

// ---------------------------------------------------------------------------
// Domain matching
// ---------------------------------------------------------------------------

function getRegistrableDomain(hostname) {
  const h = hostname.replace(/^www\./, "");
  const parts = h.split(".");
  if (parts.length <= 2) return h;

  const twoPartTLDs = [
    "co.uk", "org.uk", "com.au", "co.jp", "co.kr", "co.nz",
    "com.br", "com.mx", "co.in", "co.za", "com.cn", "com.tw",
    "co.id", "com.sg", "com.ar", "com.co", "com.tr", "com.hk",
  ];
  const lastTwo = parts.slice(-2).join(".");
  if (twoPartTLDs.includes(lastTwo)) {
    return parts.slice(-3).join(".");
  }

  return parts.slice(-2).join(".");
}

function isDomainPopular(hostname) {
  const reg = getRegistrableDomain(hostname);
  if (POPULAR_DOMAINS.has(reg)) return true;
  // Also check the full hostname (some entries include subdomains)
  if (POPULAR_DOMAINS.has(hostname.replace(/^www\./, ""))) return true;
  return false;
}

function isDomainBlocked(domain) {
  return BLOCKLIST_PATTERNS.some((pattern) => pattern.test(domain));
}

// ---------------------------------------------------------------------------
// Trusted domains (user-approved via "I know this site")
// ---------------------------------------------------------------------------

async function getTrustedDomains() {
  const result = await chrome.storage.local.get("trustedDomains");
  return result.trustedDomains || [];
}

async function addTrustedDomain(domain) {
  const trusted = await getTrustedDomains();
  if (!trusted.includes(domain)) {
    trusted.push(domain);
    await chrome.storage.local.set({ trustedDomains: trusted });
  }
}

// ---------------------------------------------------------------------------
// Message handling
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "passwordFieldDetected") {
    handlePasswordDetection(message, sender).then((verdict) => {
      sendResponse({ verdict, domain: message.domain });
    });
    return true; // async response
  }

  if (message.type === "trustDomain") {
    addTrustedDomain(message.domain).then(() => {
      const tabId = sender.tab?.id;
      if (tabId) {
        pendingWarnings.delete(tabId);
        chrome.action.setBadgeText({ text: "", tabId });
      }
      sendResponse({ ok: true });
    });
    return true;
  }

  if (message.type === "blockDomain") {
    const tabId = sender.tab?.id;
    if (tabId && pendingWarnings.has(tabId)) {
      const info = pendingWarnings.get(tabId);
      pendingWarnings.delete(tabId);
      redirectToBlocked(tabId, info.domain);
    }
    sendResponse({ ok: true });
    return false;
  }

  if (message.type === "getPendingWarning") {
    chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
      const tabId = tabs[0]?.id;
      const info = tabId ? pendingWarnings.get(tabId) : null;
      sendResponse(info || null);
    });
    return true;
  }

  if (message.type === "proceedAnyway") {
    addTrustedDomain(message.domain).then(() => {
      sendResponse({ ok: true });
    });
    return true;
  }

  return false;
});

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

async function handlePasswordDetection(message, sender) {
  const { domain } = message;
  const tabId = sender.tab?.id;
  if (!tabId) return "safe";

  // Wait for the domain list to finish loading
  await domainsReady;

  // 1. User-trusted domains
  const trusted = await getTrustedDomains();
  if (
    trusted.includes(domain) ||
    trusted.includes(getRegistrableDomain(domain))
  ) {
    return "safe";
  }

  // 2. Known-blocked (phishing patterns)
  if (isDomainBlocked(domain)) {
    pendingWarnings.set(tabId, { domain, url: message.url, verdict: "blocked" });
    redirectToBlocked(tabId, domain);
    return "blocked";
  }

  // 3. Popular domains (Tranco top 10k)
  if (isDomainPopular(domain)) {
    return "safe";
  }

  // 4. First-time domain — show informational notice
  pendingWarnings.set(tabId, { domain, url: message.url, verdict: "unknown" });
  chrome.action.setBadgeText({ text: "!", tabId });
  chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
  return "unknown";
}

function redirectToBlocked(tabId, domain) {
  const blockedUrl =
    chrome.runtime.getURL("blocked.html") +
    "?domain=" +
    encodeURIComponent(domain);
  chrome.tabs.update(tabId, { url: blockedUrl });
}

// Clear pending warning when tab navigates away
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url) {
    pendingWarnings.delete(tabId);
    chrome.action.setBadgeText({ text: "", tabId });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  pendingWarnings.delete(tabId);
});
