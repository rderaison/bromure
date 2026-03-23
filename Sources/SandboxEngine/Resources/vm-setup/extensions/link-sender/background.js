"use strict";

/**
 * Background service worker — adds a "Send link to other Bromure session"
 * context menu item on links and forwards the URL to the host via native
 * messaging (link-agent.py → vsock).
 */

const NATIVE_HOST = "com.bromure.link_sender";

let nativePort = null;

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[LinkSender] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener((msg) => {
    // Host may send acknowledgements — nothing to do with them for now.
    console.log("[LinkSender] host response:", msg);
  });

  nativePort.onDisconnect.addListener(() => {
    console.log(
      "[LinkSender] native host disconnected",
      chrome.runtime.lastError?.message || ""
    );
    nativePort = null;
    setTimeout(connectNative, 3000);
  });
}

connectNative();

// Create context menu item on links
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "send-link-to-bromure",
    title: "Open link in another Bromure profile",
    contexts: ["link"],
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== "send-link-to-bromure") return;

  const url = info.linkUrl;
  if (!url) return;

  if (!nativePort) {
    connectNative();
    if (!nativePort) {
      console.error("[LinkSender] cannot reach host");
      return;
    }
  }

  nativePort.postMessage({ type: "open_in_profile", url });
});
