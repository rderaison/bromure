"use strict";

/**
 * Background service worker — bridges content script file pick requests
 * to the native messaging host (file-picker-host.py → vsock → host macOS).
 *
 * The host transfers the picked file to /home/chrome/ via file-agent (port 5100).
 * The native host returns the local file path via JSON (port 5600).
 * This SW uses chrome.debugger + DOM.setFileInputFiles to set the file
 * on the <input> by path — no base64, no data transfer through messaging.
 */

const NATIVE_HOST = "com.bromure.file_picker";

let nativePort = null;
const pendingRequests = new Map(); // requestId -> { tabId, frameId }

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[FilePicker] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener(async (msg) => {
    console.log("[FilePicker] native message:", msg.type, msg.requestId);

    if (msg.type !== "pick_result") return;

    const pending = pendingRequests.get(msg.requestId);
    if (!pending) {
      console.warn("[FilePicker] no pending request for", msg.requestId);
      return;
    }
    pendingRequests.delete(msg.requestId);

    if (msg.status === "cancelled") {
      chrome.tabs.sendMessage(pending.tabId, {
        type: "pick_cancelled",
        requestId: msg.requestId,
      }, { frameId: pending.frameId }).catch(() => {});
      return;
    }

    // Use chrome.debugger to set the file by path
    const filePath = msg.path;
    console.log("[FilePicker] setting file via debugger:", filePath);

    const target = { tabId: pending.tabId };
    try {
      await chrome.debugger.attach(target, "1.3");

      // Find the input element marked by the content script
      const doc = await chrome.debugger.sendCommand(target, "DOM.getDocument");
      const selector = `[data-bromure-pick="${msg.requestId}"]`;
      const result = await chrome.debugger.sendCommand(target, "DOM.querySelector", {
        nodeId: doc.root.nodeId,
        selector,
      });

      if (!result.nodeId) {
        console.error("[FilePicker] could not find input with selector:", selector);
        await chrome.debugger.detach(target);
        return;
      }

      await chrome.debugger.sendCommand(target, "DOM.setFileInputFiles", {
        files: [filePath],
        nodeId: result.nodeId,
      });

      console.log("[FilePicker] file set successfully:", filePath);
      await chrome.debugger.detach(target);

      // Tell content script to clean up the marker attribute
      chrome.tabs.sendMessage(pending.tabId, {
        type: "pick_complete",
        requestId: msg.requestId,
      }, { frameId: pending.frameId }).catch(() => {});

    } catch (err) {
      console.error("[FilePicker] debugger error:", err.message);
      try { await chrome.debugger.detach(target); } catch (_) {}
      chrome.tabs.sendMessage(pending.tabId, {
        type: "pick_cancelled",
        requestId: msg.requestId,
      }, { frameId: pending.frameId }).catch(() => {});
    }
  });

  nativePort.onDisconnect.addListener(() => {
    console.log(
      "[FilePicker] native host disconnected",
      chrome.runtime.lastError?.message || ""
    );
    nativePort = null;
    for (const [id, pending] of pendingRequests) {
      chrome.tabs.sendMessage(pending.tabId, {
        type: "pick_cancelled",
        requestId: id,
      }, { frameId: pending.frameId }).catch(() => {});
    }
    pendingRequests.clear();
    setTimeout(connectNative, 3000);
  });
}

connectNative();

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type !== "pick_file") return;

  console.log("[FilePicker] pick_file request from tab", sender.tab?.id,
    "frame", sender.frameId, "requestId:", msg.requestId);

  if (!nativePort) {
    connectNative();
    if (!nativePort) {
      sendResponse({ error: "native host unavailable" });
      return;
    }
  }

  const requestId = msg.requestId;
  pendingRequests.set(requestId, {
    tabId: sender.tab.id,
    frameId: sender.frameId,
  });

  nativePort.postMessage({
    type: "pick",
    accept: msg.accept || "",
    multiple: msg.multiple || false,
    requestId,
  });

  console.log("[FilePicker] sent pick request to native host:", requestId);
  sendResponse({ ok: true });
});
