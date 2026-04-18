// Page-world hook for "ClickFix" / "paste-and-run" attack detection.
//
// Runs in the page's MAIN world at document_start so we install our wraps
// before the target page's JS gets a chance to copy to the clipboard. All
// clipboard writes are forwarded via window.postMessage to the isolated-world
// content script, which pattern-matches the payload against shell-command
// signatures and ClickFix-instruction text on the page.

(function () {
  "use strict";
  if (window.__bromurePhishingClipboardWrap) return;
  window.__bromurePhishingClipboardWrap = true;

  function post(text, source) {
    if (!text || typeof text !== "string") return;
    try {
      window.postMessage({
        __bromurePhishingClipboard: true,
        text: text.substring(0, 4096),
        source: source,
      }, "*");
    } catch (_) { /* cross-origin frame isolation, ignore */ }
  }

  // 1. navigator.clipboard.writeText(text) — most common ClickFix path
  if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
    var origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = function (text) {
      post(String(text), "writeText");
      return origWriteText(text);
    };
  }

  // 2. navigator.clipboard.write(items) — rarer, but possible
  if (navigator.clipboard && typeof navigator.clipboard.write === "function") {
    var origWrite = navigator.clipboard.write.bind(navigator.clipboard);
    navigator.clipboard.write = function (items) {
      try {
        for (var i = 0; i < items.length; i++) {
          var types = items[i].types || [];
          for (var j = 0; j < types.length; j++) {
            if (types[j] === "text/plain") {
              items[i].getType("text/plain").then(function (blob) {
                blob.text().then(function (t) { post(t, "write"); }).catch(function () {});
              }).catch(function () {});
            }
          }
        }
      } catch (_) { /* ignore */ }
      return origWrite(items);
    };
  }

  // 3. document.execCommand('copy') — legacy path, still works for selection-based copies
  //    We listen in the bubble phase so the final clipboardData is populated
  //    (pages may call setData() in their own copy listener).
  document.addEventListener("copy", function (ev) {
    try {
      var txt = "";
      if (ev.clipboardData && typeof ev.clipboardData.getData === "function") {
        txt = ev.clipboardData.getData("text/plain") || "";
      }
      if (!txt && window.getSelection) {
        txt = String(window.getSelection() || "");
      }
      if (txt) post(txt, "copy-event");
    } catch (_) { /* ignore */ }
  }, false);
})();
