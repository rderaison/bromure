/**
 * Background service worker — bridges Chrome extension messages to the
 * native messaging host (credential-agent.py).
 */

const NATIVE_HOST = "com.bromure.credential_bridge";

let nativePort = null;
const pendingCallbacks = new Map();

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[CredentialBridge] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener((msg) => {
    const requestId = msg.requestId;
    if (requestId && pendingCallbacks.has(requestId)) {
      const sendResponse = pendingCallbacks.get(requestId);
      pendingCallbacks.delete(requestId);
      sendResponse(msg);
    }
  });

  nativePort.onDisconnect.addListener(() => {
    console.log("[CredentialBridge] native host disconnected",
      chrome.runtime.lastError?.message || "");
    nativePort = null;
    // Reject all pending requests
    for (const [id, sendResponse] of pendingCallbacks) {
      sendResponse({ success: false, error: "disconnected", requestId: id });
    }
    pendingCallbacks.clear();
    // Reconnect after delay
    setTimeout(connectNative, 3000);
  });
}

// Connect on startup
connectNative();

/**
 * The page the request really comes from, as Chrome says — never what the
 * request claims. The relay forwards a DOM event, and any page script can
 * dispatch one: a page asked for accounts.google.com's passwords by
 * writing "domain" itself. https only (http for localhost).
 */
function senderOrigin(sender) {
  try {
    const u = new URL(sender.origin || sender.url || "");
    const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
    if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) return null;
    return { origin: u.origin, host: u.hostname };
  } catch (e) {
    return null;
  }
}

/** WebAuthn: an RP ID is the page's host or a parent domain of it. */
function rpIdAllowed(rpId, host) {
  if (typeof rpId !== "string" || rpId === "") return false;
  rpId = rpId.toLowerCase();
  return host === rpId || (rpId.includes(".") && host.endsWith("." + rpId));
}

/**
 * Pin every origin-bearing field to the sender's real origin; null when
 * the request names a site the page isn't (or the type is unknown).
 */
function pinToSender(payload, from) {
  if (!payload || typeof payload !== "object") return null;
  switch (payload.type) {
    case "password_get":
    case "password_fill":
    case "password_save":
      payload.origin = from.origin;
      payload.domain = from.host;
      return payload;
    case "passkey_get":
      if (!rpIdAllowed(payload.rpId, from.host)) return null;
      payload.origin = from.origin;
      return payload;
    case "passkey_create":
      if (!payload.rp || !rpIdAllowed(payload.rp.id, from.host)) return null;
      payload.origin = from.origin;
      return payload;
    default:
      return null;
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type !== "credential-request") return false;

  let payload;
  try {
    payload = JSON.parse(message.payload);
  } catch (e) {
    return false;
  }
  // Only the extension's own content script, in a tab, may ask.
  const from = sender.id === chrome.runtime.id && sender.tab ? senderOrigin(sender) : null;
  payload = from ? pinToSender(payload, from) : null;
  if (!payload) {
    sendResponse({ success: false, error: "origin_mismatch" });
    return false;
  }

  if (!nativePort) {
    connectNative();
    if (!nativePort) {
      sendResponse({ success: false, error: "not_available", requestId: payload.requestId });
      return false;
    }
  }

  pendingCallbacks.set(payload.requestId, sendResponse);
  nativePort.postMessage(payload);
  return true; // async response
});
