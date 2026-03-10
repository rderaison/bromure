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

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type !== "credential-request") return false;

  const payload = JSON.parse(message.payload);

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
