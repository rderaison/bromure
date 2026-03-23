"use strict";

/**
 * Content script — intercepts file input clicks and routes them through
 * the Bromure host file picker instead of Chrome's built-in one.
 *
 * The background SW uses chrome.debugger + DOM.setFileInputFiles to set
 * files by local path — no data transfer happens through messaging.
 * This content script just marks the input with a data attribute so the
 * background SW can find it via DOM.querySelector.
 */

let pickCounter = 0;

/**
 * Generate a unique request ID for this pick.
 */
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
 * Intercept clicks on file inputs.
 */
document.addEventListener("click", (e) => {
  const input = e.target.closest('input[type="file"]');
  if (!input) return;

  e.preventDefault();
  e.stopPropagation();
  requestPick(input);
}, true);

/**
 * Also intercept programmatic clicks (e.g. label clicks triggering input.click()).
 */
const origClick = HTMLInputElement.prototype.click;
HTMLInputElement.prototype.click = function () {
  if (this.type === "file") {
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
  }
});
