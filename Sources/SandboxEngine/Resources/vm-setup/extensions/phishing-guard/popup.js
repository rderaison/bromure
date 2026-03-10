"use strict";

const warningEl = document.getElementById("warning");
const safeEl = document.getElementById("safe");
const domainEl = document.getElementById("domain-name");
const trustBtn = document.getElementById("trust-btn");
const backBtn = document.getElementById("back-btn");

chrome.runtime.sendMessage({ type: "getPendingWarning" }, (info) => {
  if (info && info.domain) {
    domainEl.textContent = info.domain;
    warningEl.classList.remove("hidden");
  } else {
    safeEl.classList.remove("hidden");
  }
});

trustBtn.addEventListener("click", () => {
  const domain = domainEl.textContent;
  chrome.runtime.sendMessage({ type: "trustDomain", domain }, () => {
    window.close();
  });
});

backBtn.addEventListener("click", () => {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    if (tabs[0]) {
      chrome.tabs.goBack(tabs[0].id);
    }
    window.close();
  });
});
