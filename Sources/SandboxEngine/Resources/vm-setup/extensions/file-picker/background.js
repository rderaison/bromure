"use strict";

/**
 * Background service worker — bridges content script file pick requests
 * to the native messaging host (file-picker-host.py → vsock → host macOS).
 *
 * Two flows:
 *   1. File picker: content script intercepts <input type="file"> click →
 *      native host → host shows NSOpenPanel → file sent to guest →
 *      chrome.debugger + DOM.setFileInputFiles sets it by path.
 *
 *   2. Drag-and-drop: host sends drop metadata (files + coordinates) →
 *      native host waits for files on disk → chrome.debugger +
 *      Input.dispatchDragEvent simulates the drop on the page.
 */

const NATIVE_HOST = "com.bromure.file_picker";

let nativePort = null;
const pendingRequests = new Map(); // requestId -> { tabId, frameId }

// Drag hover state — keeps debugger attached between dragEnter and drop/dragExit
let dragState = null; // { tabId, dpr, toolbarHeight }

// Managed-storage policy. Extension always loads so content.js can
// show an in-page "uploads disabled" overlay; but we only stand up
// the native port when uploads are actually enabled — otherwise we'd
// churn file-picker-host.py against a host bridge that isn't listening.
let uploadEnabled = true;

async function loadPolicy() {
  try {
    const stored = await chrome.storage.managed.get(null);
    if (stored && typeof stored.fileUploadEnabled === "boolean") {
      uploadEnabled = stored.fileUploadEnabled;
    }
  } catch (_) { /* unmanaged / not yet delivered — assume enabled */ }
  // Keep content scripts in sync; they also read storage directly
  // but this covers the race on SW cold start.
  chrome.tabs.query({}, (tabs) => {
    for (const t of tabs) {
      chrome.tabs.sendMessage(t.id, { type: "upload_policy", enabled: uploadEnabled }).catch(() => {});
    }
  });
  if (uploadEnabled && !nativePort) connectNative();
  if (!uploadEnabled && nativePort) {
    try { nativePort.disconnect(); } catch (_) {}
    nativePort = null;
  }
}
loadPolicy();
chrome.storage.onChanged.addListener((_changes, area) => {
  if (area === "managed") loadPolicy();
});

function connectNative() {
  if (!uploadEnabled) return;
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[FilePicker] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener(async (msg) => {
    console.log("[FilePicker] native message:", msg.type);

    if (msg.type === "pick_result") {
      await handlePickResult(msg);
    } else if (msg.type === "drop") {
      await handleDrop(msg);
    } else if (msg.type === "drag_enter") {
      await handleDragEnter(msg);
    } else if (msg.type === "drag_move") {
      await handleDragMove(msg);
    } else if (msg.type === "drag_exit") {
      await handleDragExit();
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

/**
 * Handle a pick_result from the native host (file picker flow).
 */
async function handlePickResult(msg) {
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

  const filePath = msg.path;
  console.log("[FilePicker] setting file via debugger:", filePath);

  const target = { tabId: pending.tabId };
  try {
    await chrome.debugger.attach(target, "1.3");

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
}

// MARK: - Drag hover handlers

/**
 * Convert guest screen pixel coordinates to CSS viewport coordinates.
 * Requires dpr and toolbarHeight (cached in dragState or passed in).
 */
function toViewport(screenX, screenY, dpr, toolbarHeight) {
  return {
    x: Math.round(screenX / dpr),
    y: Math.round(screenY / dpr) - toolbarHeight,
  };
}

/**
 * Attach the debugger to the active tab and cache viewport info for drag hover.
 * Returns the target { tabId } or null if no active tab.
 */
async function attachForDrag() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return null;

  const target = { tabId: tab.id };
  try {
    await chrome.debugger.attach(target, "1.3");
  } catch (e) {
    // May already be attached (e.g. from a prior hover that didn't clean up)
    if (!e.message?.includes("Already attached")) {
      console.error("[FilePicker] drag attach error:", e.message);
      return null;
    }
  }

  const evalResult = await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
    expression: "JSON.stringify({ dpr: window.devicePixelRatio, chrome: window.outerHeight - window.innerHeight })",
  });
  const info = JSON.parse(evalResult.result.value);

  dragState = {
    tabId: tab.id,
    dpr: info.dpr || 1,
    toolbarHeight: info.chrome || 0,
  };
  return target;
}

/**
 * Detach the debugger and clear drag state.
 */
async function detachDrag() {
  if (!dragState) return;
  const target = { tabId: dragState.tabId };
  dragState = null;
  try { await chrome.debugger.detach(target); } catch (_) {}
}

/** Placeholder drag data used during hover (no real files yet). */
const hoverDragData = {
  items: [{ mimeType: "application/octet-stream", data: "" }],
  files: [],
  dragOperationsMask: 1,
};

async function handleDragEnter(msg) {
  const target = await attachForDrag();
  if (!target || !dragState) return;

  const vp = toViewport(msg.x, msg.y, dragState.dpr, dragState.toolbarHeight);
  if (vp.y < 0) return;

  try {
    await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
      type: "dragEnter", x: vp.x, y: vp.y, data: hoverDragData,
    });
    await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
      type: "dragOver", x: vp.x, y: vp.y, data: hoverDragData,
    });
  } catch (e) {
    console.error("[FilePicker] dragEnter error:", e.message);
    await detachDrag();
  }
}

async function handleDragMove(msg) {
  if (!dragState) return;

  const target = { tabId: dragState.tabId };
  const vp = toViewport(msg.x, msg.y, dragState.dpr, dragState.toolbarHeight);
  if (vp.y < 0) return;

  try {
    await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
      type: "dragOver", x: vp.x, y: vp.y, data: hoverDragData,
    });
  } catch (e) {
    console.error("[FilePicker] dragMove error:", e.message);
    await detachDrag();
  }
}

async function handleDragExit() {
  if (!dragState) return;

  const target = { tabId: dragState.tabId };
  try {
    await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
      type: "dragLeave", x: 0, y: 0, data: hoverDragData,
    });
  } catch (e) {
    console.error("[FilePicker] dragExit error:", e.message);
  }
  await detachDrag();
}

// MARK: - Drop handler

/**
 * Handle a drop message from the native host (drag-and-drop flow).
 * Dispatches CDP drag events at the given coordinates with the file paths.
 * Reuses the debugger session from hover if one is active.
 */
async function handleDrop(msg) {
  const filePaths = msg.files; // array of "/home/chrome/..." paths
  const screenX = msg.x;
  const screenY = msg.y;

  console.log("[FilePicker] drop:", filePaths.length, "file(s) at screen", screenX, screenY);

  // Reuse debugger from hover, or attach fresh
  let target;
  let dpr, toolbarHeight;
  const hadDragState = !!dragState;

  if (dragState) {
    target = { tabId: dragState.tabId };
    dpr = dragState.dpr;
    toolbarHeight = dragState.toolbarHeight;
    dragState = null; // consume the state
  } else {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) {
      console.warn("[FilePicker] drop: no active tab");
      return;
    }
    target = { tabId: tab.id };
    try {
      await chrome.debugger.attach(target, "1.3");
    } catch (e) {
      if (!e.message?.includes("Already attached")) {
        console.error("[FilePicker] drop attach error:", e.message);
        return;
      }
    }

    const evalResult = await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
      expression: "JSON.stringify({ dpr: window.devicePixelRatio, chrome: window.outerHeight - window.innerHeight })",
    });
    const info = JSON.parse(evalResult.result.value);
    dpr = info.dpr || 1;
    toolbarHeight = info.chrome || 0;
  }

  const vpX = Math.round(screenX / dpr);
  const vpY = Math.round(screenY / dpr) - toolbarHeight;

  try {
    if (vpY < 0) {
      console.log("[FilePicker] drop landed on Chrome toolbar, ignoring");
      await chrome.debugger.detach(target);
      return;
    }

    // Test if there's a valid drop target at these coordinates
    const testResult = await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
      expression: `(function(x, y) {
        var el = document.elementFromPoint(x, y);
        if (!el) return "none";
        if (el.closest && el.closest('input[type="file"]')) return "file-input";
        if (el.tagName === "INPUT" && el.type === "file") return "file-input";
        var dt = new DataTransfer();
        try { dt.items.add(new File([""], "test", {type: "application/octet-stream"})); } catch(e) {}
        var evt = new DragEvent("dragover", {
          bubbles: true, cancelable: true,
          clientX: x, clientY: y,
          dataTransfer: dt
        });
        var prevented = !el.dispatchEvent(evt);
        return prevented ? "dropzone" : "none";
      })(${vpX}, ${vpY})`,
    });
    const targetType = testResult.result.value;
    console.log("[FilePicker] drop target type:", targetType, "at viewport", vpX, vpY);

    if (targetType === "none") {
      console.log("[FilePicker] no drop target at coordinates, ignoring");
      await chrome.debugger.detach(target);
      return;
    }

    if (targetType === "file-input") {
      // For file inputs, use DOM.setFileInputFiles (more reliable)
      const doc = await chrome.debugger.sendCommand(target, "DOM.getDocument");
      const nodeResult = await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
        expression: `(function(x, y) {
          var el = document.elementFromPoint(x, y);
          if (el && el.closest) el = el.closest('input[type="file"]') || el;
          if (el && el.tagName === "INPUT" && el.type === "file") {
            el.setAttribute("data-bromure-drop", "1");
            return true;
          }
          return false;
        })(${vpX}, ${vpY})`,
      });

      if (nodeResult.result.value) {
        const qResult = await chrome.debugger.sendCommand(target, "DOM.querySelector", {
          nodeId: doc.root.nodeId,
          selector: '[data-bromure-drop="1"]',
        });

        if (qResult.nodeId) {
          await chrome.debugger.sendCommand(target, "DOM.setFileInputFiles", {
            files: filePaths,
            nodeId: qResult.nodeId,
          });
          console.log("[FilePicker] files set on input via DOM.setFileInputFiles");

          // Clean up marker
          await chrome.debugger.sendCommand(target, "Runtime.evaluate", {
            expression: 'document.querySelector("[data-bromure-drop]")?.removeAttribute("data-bromure-drop")',
          });
        }
      }

      await chrome.debugger.detach(target);
      return;
    }

    // Dropzone: dispatch CDP drag events
    const dragData = {
      items: [],
      files: filePaths,
      dragOperationsMask: 1, // copy
    };

    // If we had hover state, the page already has dragEnter — just send drop.
    // Otherwise send the full sequence.
    if (!hadDragState) {
      await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
        type: "dragEnter", x: vpX, y: vpY, data: dragData,
      });
      await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
        type: "dragOver", x: vpX, y: vpY, data: dragData,
      });
    }
    await chrome.debugger.sendCommand(target, "Input.dispatchDragEvent", {
      type: "drop", x: vpX, y: vpY, data: dragData,
    });

    console.log("[FilePicker] drop dispatched via CDP at", vpX, vpY);
    await chrome.debugger.detach(target);

  } catch (err) {
    console.error("[FilePicker] drop error:", err.message);
    try { await chrome.debugger.detach(target); } catch (_) {}
  }
}

// Initial connect happens from loadPolicy() once it has read managed
// storage and confirmed uploads are enabled. No unconditional connect
// here — on sessions with uploads disabled it would just churn.

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type !== "pick_file") return;

  console.log("[FilePicker] pick_file request from tab", sender.tab?.id,
    "frame", sender.frameId, "requestId:", msg.requestId);

  if (!uploadEnabled) {
    sendResponse({ error: "uploads disabled for this session" });
    return;
  }

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
