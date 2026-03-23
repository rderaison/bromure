"use strict";

/**
 * Bromure Trace — form field capture content script.
 *
 * Maintains a live snapshot of all form fields on the page (including password
 * fields) so the background service worker can grab pre-submit values when a
 * POST/PUT request fires.
 */

const fieldCache = new Map(); // element -> {name, type, value}

function fieldKey(el) {
  if (el.name) return el.name;
  if (el.id) return el.id;
  // Positional fallback: tag + index among siblings of the same type
  const tag = el.tagName.toLowerCase();
  const siblings = el.parentElement
    ? Array.from(el.parentElement.querySelectorAll(tag))
    : [];
  const idx = siblings.indexOf(el);
  return "[" + tag + "#" + (idx >= 0 ? idx : "?") + "]";
}

function snapshotField(el) {
  const entry = {
    name: fieldKey(el),
    type: el.type || el.tagName.toLowerCase(),
    value: "",
  };

  if (el.tagName === "SELECT") {
    const selected = el.options[el.selectedIndex];
    entry.value = selected ? selected.value : "";
  } else if (el.type === "checkbox" || el.type === "radio") {
    entry.value = el.checked ? (el.value || "on") : "";
  } else {
    entry.value = el.value || "";
  }

  fieldCache.set(el, entry);
}

function scanAll() {
  fieldCache.clear();
  const elements = document.querySelectorAll("input, textarea, select");
  for (const el of elements) {
    snapshotField(el);
  }
}

// Initial scan
scanAll();

// Keep cache fresh via delegated events
document.addEventListener("input", (e) => {
  const el = e.target;
  if (el.matches && el.matches("input, textarea, select")) {
    snapshotField(el);
  }
}, true);

document.addEventListener("change", (e) => {
  const el = e.target;
  if (el.matches && el.matches("input, textarea, select")) {
    snapshotField(el);
  }
}, true);

// Respond to capture requests from the background service worker
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "captureFormFields") {
    // Re-scan to pick up dynamically added fields
    scanAll();
    const fields = Array.from(fieldCache.values());
    sendResponse({ fields });
  }
  // Return false — synchronous response
  return false;
});
