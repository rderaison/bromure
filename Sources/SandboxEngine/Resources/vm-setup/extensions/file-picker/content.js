"use strict";

/**
 * Content script — intercepts file input clicks and either routes them
 * to the Bromure host file picker (when uploads are enabled) or shows
 * an in-page overlay explaining that uploads are disabled for this
 * session (when fileUploadEnabled=false in managed storage).
 *
 * The extension loads unconditionally; the policy flag decides which
 * branch to take. This is nicer than letting Chromium fall back to the
 * Linux file dialog — users see a clear message inside the page
 * instead of an unfamiliar OS chooser.
 */

// Start assuming uploads are enabled so we never silently break a
// fresh install where policy hasn't landed yet. The SW will flip this
// via runtime message once it's read chrome.storage.managed, and we
// also read directly below for our own resilience on reloads.
let uploadEnabled = true;

async function loadPolicy() {
  try {
    const stored = await chrome.storage.managed.get(null);
    if (stored && typeof stored.fileUploadEnabled === "boolean") {
      uploadEnabled = stored.fileUploadEnabled;
    }
  } catch (_) {
    // Unmanaged session or storage unavailable — keep default.
  }
}
loadPolicy();

chrome.storage.onChanged.addListener((_changes, area) => {
  if (area === "managed") loadPolicy();
});

let pickCounter = 0;
function makeRequestId() {
  return `pick-${Date.now()}-${++pickCounter}`;
}

/**
 * Request a file pick from the host.
 */
function requestPick(input) {
  const accept = input.getAttribute("accept") || "";
  const multiple = input.hasAttribute("multiple");
  const requestId = makeRequestId();

  // Mark the input so background.js can find it via chrome.debugger
  input.setAttribute("data-bromure-pick", requestId);

  console.log("[FilePicker] intercepted file input click, requestId:", requestId, "accept:", accept);

  chrome.runtime.sendMessage(
    { type: "pick_file", accept, multiple, requestId },
    (response) => {
      if (chrome.runtime.lastError || !response || response.error) {
        console.error("[FilePicker] request failed:",
          chrome.runtime.lastError?.message || response?.error);
        input.removeAttribute("data-bromure-pick");
        return;
      }
      console.log("[FilePicker] pick request acknowledged");
    }
  );
}

/**
 * Shows a dismissible overlay explaining that uploads are disabled.
 * Kept entirely self-contained: all styles inline + !important so host
 * page CSS can't break the layout.
 */
const OVERLAY_ID = "__bromure_upload_blocked__";
let overlayHideTimer = null;

function showUploadDisabledMessage() {
  // Re-entrancy: if one is already up, just bump its dismissal timer.
  let root = document.getElementById(OVERLAY_ID);
  if (!root) {
    root = document.createElement("div");
    root.id = OVERLAY_ID;
    const rootStyle = [
      "all: initial",
      "position: fixed",
      "inset: 0",
      "z-index: 2147483647",
      "display: flex",
      "align-items: flex-start",
      "justify-content: center",
      "padding-top: 48px",
      "pointer-events: none",
    ].map(d => d + " !important").join(";");
    root.setAttribute("style", rootStyle);

    const card = document.createElement("div");
    const cardStyle = [
      "all: initial",
      "pointer-events: auto",
      "background: #fff7ed",
      "border: 1px solid #fb923c",
      "border-radius: 10px",
      "padding: 14px 18px",
      "max-width: 460px",
      "box-shadow: 0 6px 24px rgba(0,0,0,0.16)",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      "font-size: 13px",
      "line-height: 1.45",
      "color: #7c2d12",
      "display: flex",
      "align-items: flex-start",
      "gap: 10px",
    ].map(d => d + " !important").join(";");
    card.setAttribute("style", cardStyle);

    const icon = document.createElement("span");
    icon.textContent = "🚫";
    icon.setAttribute("style", "font-size: 18px !important; line-height: 1 !important; margin-top: 1px !important;");
    card.appendChild(icon);

    const text = document.createElement("div");
    text.setAttribute("style", "all: initial !important; font: inherit !important; color: inherit !important; flex: 1 !important;");
    const title = document.createElement("div");
    title.textContent = "File uploads are disabled";
    title.setAttribute("style", "all: initial !important; font: inherit !important; font-weight: 600 !important; color: inherit !important; margin-bottom: 2px !important;");
    text.appendChild(title);
    const body = document.createElement("div");
    body.textContent = "This Bromure session is configured to block uploading files from your Mac. Turn on “Allow file upload” in the profile settings to enable it.";
    body.setAttribute("style", "all: initial !important; font: inherit !important; color: inherit !important;");
    text.appendChild(body);
    card.appendChild(text);

    const close = document.createElement("button");
    close.textContent = "×";
    close.setAttribute("style", [
      "all: initial",
      "font: inherit",
      "color: #7c2d12",
      "font-size: 18px",
      "line-height: 1",
      "padding: 0 4px",
      "cursor: pointer",
      "background: transparent",
    ].map(d => d + " !important").join(";"));
    close.addEventListener("click", hideUploadDisabledMessage);
    card.appendChild(close);

    root.appendChild(card);
    (document.body || document.documentElement).appendChild(root);
  }

  if (overlayHideTimer) clearTimeout(overlayHideTimer);
  overlayHideTimer = setTimeout(hideUploadDisabledMessage, 5000);
}

function hideUploadDisabledMessage() {
  if (overlayHideTimer) {
    clearTimeout(overlayHideTimer);
    overlayHideTimer = null;
  }
  document.getElementById(OVERLAY_ID)?.remove();
}

/**
 * Intercept clicks on file inputs.
 */
document.addEventListener("click", (e) => {
  const input = e.target.closest('input[type="file"]');
  if (!input) return;

  e.preventDefault();
  e.stopPropagation();

  if (!uploadEnabled) {
    showUploadDisabledMessage();
    return;
  }
  requestPick(input);
}, true);

/**
 * Also intercept programmatic clicks (e.g. label clicks triggering input.click()).
 */
const origClick = HTMLInputElement.prototype.click;
HTMLInputElement.prototype.click = function () {
  if (this.type === "file") {
    if (!uploadEnabled) {
      showUploadDisabledMessage();
      return;
    }
    requestPick(this);
    return;
  }
  origClick.call(this);
};

/**
 * Handle responses from the background service worker.
 */
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === "pick_complete") {
    // File was set via chrome.debugger — just clean up the marker
    console.log("[FilePicker] pick complete:", msg.requestId);
    const input = document.querySelector(`[data-bromure-pick="${msg.requestId}"]`);
    if (input) {
      input.removeAttribute("data-bromure-pick");
    }
  } else if (msg.type === "pick_cancelled") {
    console.log("[FilePicker] pick cancelled:", msg.requestId);
    const input = document.querySelector(`[data-bromure-pick="${msg.requestId}"]`);
    if (input) {
      input.removeAttribute("data-bromure-pick");
    }
  } else if (msg.type === "upload_policy") {
    if (typeof msg.enabled === "boolean") uploadEnabled = msg.enabled;
  }
});
