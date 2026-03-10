/**
 * Content script (ISOLATED world) — relays CustomEvents between the MAIN
 * world content script and the background service worker.
 *
 * The MAIN world script cannot use chrome.runtime, so this relay is needed.
 */

window.addEventListener("bromure-credential-request", (event) => {
  const payload = event.detail;
  chrome.runtime.sendMessage(
    { type: "credential-request", payload: payload },
    (response) => {
      if (chrome.runtime.lastError) {
        // Extension context invalidated — ignore
        return;
      }
      window.dispatchEvent(
        new CustomEvent("bromure-credential-response", {
          detail: JSON.stringify(response),
        })
      );
    }
  );
}, true);
