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

// ---------------------------------------------------------------------------
// Known auth/SSO provider domains — legitimate cross-domain login targets.
// Forms posting passwords to these domains from a different site are normal
// (OAuth, SSO, identity-as-a-service).
// ---------------------------------------------------------------------------

const AUTH_PROVIDER_DOMAINS = new Set([
  // Google
  "google.com", "googleapis.com", "gstatic.com",
  // Microsoft
  "microsoft.com", "microsoftonline.com", "live.com", "azure.com",
  // Apple
  "apple.com", "icloud.com",
  // Amazon / AWS
  "amazon.com", "amazonaws.com",
  // Meta
  "facebook.com", "instagram.com", "meta.com",
  // Identity-as-a-Service
  "auth0.com", "okta.com", "oktapreview.com", "onelogin.com",
  "duosecurity.com", "duo.com", "pingidentity.com",
  "forgerock.com", "cyberark.com",
  // Developer platforms
  "github.com", "gitlab.com", "bitbucket.org", "atlassian.com",
  // Social login
  "twitter.com", "x.com", "linkedin.com",
  // Payment (checkout auth)
  "paypal.com", "stripe.com", "braintreegateway.com",
  // Cloud / SaaS
  "salesforce.com", "force.com", "cloudflare.com",
  "firebase.com", "firebaseapp.com",
  // Other common auth endpoints
  "yahoo.com", "dropbox.com", "spotify.com", "shopify.com",
]);

// Pending warnings: tabId -> { domain, url, verdict }
const pendingWarnings = new Map();

// ---------------------------------------------------------------------------
// Service state
// ---------------------------------------------------------------------------

let serviceStatus = "ok"; // "ok" | "token_limit" | "degraded"

// ---------------------------------------------------------------------------
// Native messaging connection to phishing-agent (vsock relay to host)
// ---------------------------------------------------------------------------

let nativePort = null;
let nativeReconnectTimer = null;
const pendingAnalyses = new Map(); // requestId -> { tabId, domain }
const pendingRegistration = new Map(); // requestId -> resolve callback
let analysisIdCounter = 0;

function connectNative() {
  if (nativePort) return;
  try {
    nativePort = chrome.runtime.connectNative("com.bromure.phishing_guard");
  } catch (err) {
    console.error("[Phishing Guard] Native connect failed:", err);
    scheduleReconnect();
    return;
  }

  nativePort.onMessage.addListener((msg) => {
    handleNativeResponse(msg);
  });

  nativePort.onDisconnect.addListener(() => {
    console.warn("[Phishing Guard] Native port disconnected:", chrome.runtime.lastError?.message);
    nativePort = null;
    pendingAnalyses.clear();
    pendingRegistration.clear();
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  if (nativeReconnectTimer) return;
  nativeReconnectTimer = setTimeout(() => {
    nativeReconnectTimer = null;
    connectNative();
  }, 5000);
}

function sendToNative(msg) {
  if (!nativePort) connectNative();
  if (nativePort) {
    try {
      nativePort.postMessage(msg);
    } catch (err) {
      console.error("[Phishing Guard] Native send error:", err);
      nativePort = null;
      scheduleReconnect();
    }
  }
}

function handleNativeResponse(msg) {
  // Registration responses
  if (msg.type === "registerResult") {
    const resolve = pendingRegistration.get(msg.requestId);
    pendingRegistration.delete(msg.requestId);
    if (resolve) resolve(msg);
    return;
  }

  if (msg.type !== "analysisResult") return;

  const info = pendingAnalyses.get(msg.requestId);
  pendingAnalyses.delete(msg.requestId);
  if (!info) return;

  const { tabId, domain } = info;

  // Handle rate limit / degraded responses
  if (msg.error === "token_limit") {
    serviceStatus = "token_limit";
    console.warn("[Phishing Guard] Daily limit reached for this token");
    chrome.tabs.sendMessage(tabId, {
      type: "llmServiceStatus",
      status: "token_limit",
      reason: msg.reason || "Daily analysis limit reached.",
    }).catch(() => {});
    return;
  }

  if (msg.error === "degraded") {
    serviceStatus = "degraded";
    console.warn("[Phishing Guard] Service in degraded mode");
    chrome.tabs.sendMessage(tabId, {
      type: "llmServiceStatus",
      status: "degraded",
      reason: msg.reason || "Service is temporarily in degraded mode.",
    }).catch(() => {});
    return;
  }

  // Server doesn't recognize our token — clear it and re-register
  if (msg.error === "invalid_token") {
    console.warn("[Phishing Guard] Token rejected, re-registering...");
    authToken = null;
    chrome.storage.local.remove("phishingToken").then(() => {
      ensureRegistered().then((ok) => {
        if (ok && info) {
          const retryId = "phish-" + (++analysisIdCounter);
          pendingAnalyses.set(retryId, { tabId, domain, payload: info.payload });
          sendToNative({
            type: "analyze",
            requestId: retryId,
            token: authToken,
            payload: info.payload,
          });
          setTimeout(() => pendingAnalyses.delete(retryId), 15000);
        }
      });
    });
    return;
  }

  // Reset status on successful responses
  if (msg.verdict && msg.verdict !== "error") {
    serviceStatus = "ok";
  }

  const verdict = msg.verdict; // "phishing", "suspicious", "safe", "error"

  console.log(`[Phishing Guard] LLM response for ${domain}:`, JSON.stringify(msg));

  const reason = msg.reason || "";

  if (verdict === "phishing") {
    pendingWarnings.delete(tabId);
    chrome.tabs.sendMessage(tabId, { type: "llmVerdict", verdict: "phishing", reason }).catch(() => {});
    redirectToBlocked(tabId, domain);
  } else if (verdict === "suspicious") {
    pendingWarnings.set(tabId, { domain, verdict: "suspicious", reason });
    chrome.action.setBadgeText({ text: "!", tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
    chrome.tabs.sendMessage(tabId, { type: "llmVerdict", verdict: "suspicious", reason, confidence: msg.confidence || 0.5 }).catch(() => {});
  } else if (verdict === "safe") {
    pendingWarnings.delete(tabId);
    chrome.action.setBadgeText({ text: "", tabId });
    chrome.tabs.sendMessage(tabId, { type: "llmVerdict", verdict: "safe", reason }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Registration: proof-of-work based token acquisition
// ---------------------------------------------------------------------------

let authToken = null;
let registering = false;

async function loadToken() {
  const result = await chrome.storage.local.get("phishingToken");
  if (result.phishingToken) {
    authToken = result.phishingToken;
    return true;
  }
  return false;
}

async function ensureRegistered() {
  if (authToken) return true;
  if (await loadToken()) return true;
  if (registering) return false;

  registering = true;
  try {
    // Step 1: request challenge via native messaging → host → server
    const challengeId = "reg-" + (++analysisIdCounter);
    const challengeResult = await new Promise((resolve) => {
      pendingRegistration.set(challengeId, resolve);
      sendToNative({ type: "register", requestId: challengeId });
      setTimeout(() => {
        pendingRegistration.delete(challengeId);
        resolve({ error: "timeout" });
      }, 30000);
    });

    if (challengeResult.error || !challengeResult.challenge) {
      console.error("[Phishing Guard] Registration challenge failed:", challengeResult.error);
      return false;
    }

    // Step 2: solve PoW
    console.log(`[Phishing Guard] Solving PoW (difficulty=${challengeResult.difficulty})...`);
    const nonce = await solvePoW(challengeResult.challenge, challengeResult.difficulty);
    console.log("[Phishing Guard] PoW solved, submitting...");

    // Step 3: submit solution
    const solveId = "reg-" + (++analysisIdCounter);
    const solveResult = await new Promise((resolve) => {
      pendingRegistration.set(solveId, resolve);
      sendToNative({
        type: "registerSolve",
        requestId: solveId,
        challengeId: challengeResult.challengeId,
        nonce: nonce,
      });
      setTimeout(() => {
        pendingRegistration.delete(solveId);
        resolve({ error: "timeout" });
      }, 15000);
    });

    if (solveResult.error || !solveResult.token) {
      console.error("[Phishing Guard] Registration solve failed:", solveResult.error);
      return false;
    }

    authToken = solveResult.token;
    await chrome.storage.local.set({ phishingToken: authToken });
    console.log("[Phishing Guard] Registered successfully");
    return true;
  } finally {
    registering = false;
  }
}

/**
 * Solve proof-of-work: find nonce such that SHA-256(challenge + nonce)
 * has `difficulty` leading zero bits. Runs in a chunked loop to avoid
 * blocking the service worker.
 */
async function solvePoW(challenge, difficulty) {
  const encoder = new TextEncoder();
  const batchSize = 50000;
  let nonce = 0;

  while (true) {
    for (let i = 0; i < batchSize; i++) {
      const data = encoder.encode(challenge + nonce);
      const hash = await crypto.subtle.digest("SHA-256", data);
      if (hasLeadingZeroBits(new Uint8Array(hash), difficulty)) {
        return nonce;
      }
      nonce++;
    }
    // Yield to event loop between batches
    await new Promise((r) => setTimeout(r, 0));
  }
}

function hasLeadingZeroBits(buf, bits) {
  let remaining = bits;
  for (let i = 0; i < buf.length && remaining > 0; i++) {
    if (remaining >= 8) {
      if (buf[i] !== 0) return false;
      remaining -= 8;
    } else {
      const mask = 0xff << (8 - remaining);
      if ((buf[i] & mask) !== 0) return false;
      remaining = 0;
    }
  }
  return true;
}

// Start registration eagerly on startup
loadToken().then((found) => {
  if (!found) ensureRegistered();
});

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
  // TODO: re-enable when phishing analysis is fully tested
  return false;
}

function isDomainBlocked(domain) {
  return BLOCKLIST_PATTERNS.some((pattern) => pattern.test(domain));
}

function isAuthProvider(hostname) {
  return AUTH_PROVIDER_DOMAINS.has(getRegistrableDomain(hostname));
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
    handlePasswordDetection(message, sender).then((result) => {
      sendResponse(result);
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

  if (message.type === "checkFormAction") {
    sendResponse({ isAuthProvider: isAuthProvider(message.actionDomain) });
    return false;
  }

  if (message.type === "analyzeWithLLM") {
    const tabId = sender.tab?.id;
    if (!tabId || !message.payload) return false;

    // Don't send requests if we've hit limits
    if (serviceStatus === "token_limit" || serviceStatus === "degraded") {
      chrome.tabs.sendMessage(tabId, {
        type: "llmServiceStatus",
        status: serviceStatus,
        reason: serviceStatus === "degraded"
          ? "Service is temporarily in degraded mode."
          : "Daily analysis limit reached.",
      }).catch(() => {});
      return false;
    }

    domainsReady.then(async () => {
      if (isDomainPopular(message.payload.domain)) return;

      // Ensure we have a token before analyzing
      const registered = await ensureRegistered();
      if (!registered) {
        console.warn("[Phishing Guard] Not registered, skipping LLM analysis");
        return;
      }

      const requestId = "phish-" + (++analysisIdCounter);
      pendingAnalyses.set(requestId, { tabId, domain: message.payload.domain, payload: message.payload });

      sendToNative({
        type: "analyze",
        requestId: requestId,
        token: authToken,
        payload: message.payload,
      });

      setTimeout(() => {
        pendingAnalyses.delete(requestId);
      }, 15000);
    });
    return false;
  }

  if (message.type === "getServiceStatus") {
    sendResponse({ status: serviceStatus });
    return false;
  }

  return false;
});

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

async function handlePasswordDetection(message, sender) {
  const { domain, formActionDomains } = message;
  const tabId = sender.tab?.id;
  if (!tabId) return { verdict: "safe", domain };

  // Wait for the domain list to finish loading
  await domainsReady;

  // 1. User-trusted domains — skip the warning banner but still run LLM analysis
  const trusted = await getTrustedDomains();
  console.log(`[Phishing Guard] handlePasswordDetection domain=${domain} trusted=[${trusted.join(",")}]`);
  const isTrusted = trusted.includes(domain) || trusted.includes(getRegistrableDomain(domain));
  if (isTrusted) {
    console.log(`[Phishing Guard] domain ${domain} is trusted`);
  }
  if (isTrusted) {
    // Still check form actions even if page domain is trusted
    const crossDomain = checkFormActions(domain, formActionDomains);
    if (crossDomain) {
      pendingWarnings.set(tabId, { domain, url: message.url, verdict: "cross-domain", actionDomain: crossDomain });
      chrome.action.setBadgeText({ text: "!", tabId });
      chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
      return { verdict: "cross-domain", domain, actionDomain: crossDomain };
    }
    return { verdict: "trusted", domain };
  }

  // 2. Known-blocked (phishing patterns)
  if (isDomainBlocked(domain)) {
    console.log(`[Phishing Guard] domain ${domain} matched blocklist — blocking`);
    pendingWarnings.set(tabId, { domain, url: message.url, verdict: "blocked" });
    redirectToBlocked(tabId, domain);
    return { verdict: "blocked", domain };
  }

  // 3. Check form action domains for cross-domain posting
  const crossDomain = checkFormActions(domain, formActionDomains);
  if (crossDomain) {
    pendingWarnings.set(tabId, { domain, url: message.url, verdict: "cross-domain", actionDomain: crossDomain });
    chrome.action.setBadgeText({ text: "!", tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
    return { verdict: "cross-domain", domain, actionDomain: crossDomain };
  }

  // 4. Popular domains (Tranco top 100k)
  if (isDomainPopular(domain)) {
    console.log(`[Phishing Guard] domain ${domain} is popular — safe`);
    return { verdict: "safe", domain };
  }

  console.log(`[Phishing Guard] domain ${domain} is unknown — will show warning`);
  // 5. First-time domain — show informational notice
  pendingWarnings.set(tabId, { domain, url: message.url, verdict: "unknown" });
  chrome.action.setBadgeText({ text: "!", tabId });
  chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
  return { verdict: "unknown", domain };
}

/**
 * Check if any form action domain is cross-domain and not an auth provider.
 * Returns the first suspicious action domain, or null if all are fine.
 */
function checkFormActions(pageDomain, formActionDomains) {
  if (!formActionDomains || formActionDomains.length === 0) return null;

  const pageReg = getRegistrableDomain(pageDomain);

  for (const actionDomain of formActionDomains) {
    const actionReg = getRegistrableDomain(actionDomain);

    // Same registrable domain is fine (www.ft.com → accounts.ft.com)
    if (actionReg === pageReg) continue;

    // Known auth/SSO provider is fine (any site → auth0.com)
    if (isAuthProvider(actionDomain)) continue;

    // Cross-domain to an unknown destination — suspicious
    return actionDomain;
  }

  return null;
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
