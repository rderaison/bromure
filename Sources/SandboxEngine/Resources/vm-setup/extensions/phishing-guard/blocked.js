"use strict";

const params = new URLSearchParams(window.location.search);
const domain = params.get("domain") || "unknown";

document.getElementById("blocked-domain").textContent = domain;

document.getElementById("go-back").addEventListener("click", () => {
  if (history.length > 1) {
    history.back();
  } else {
    chrome.tabs.update({ url: "about:blank" });
  }
});

document.getElementById("proceed").addEventListener("click", (e) => {
  e.preventDefault();
  chrome.runtime.sendMessage(
    { type: "proceedAnyway", domain: domain },
    () => {
      // Navigate back; the domain is now trusted so it won't be blocked again
      if (history.length > 2) {
        history.go(-2);
      } else {
        window.close();
      }
    }
  );
});
