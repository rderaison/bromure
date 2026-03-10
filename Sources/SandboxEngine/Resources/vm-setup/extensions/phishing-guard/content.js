(function () {
  "use strict";

  let reported = false;
  let bannerElement = null;

  function getDomain() {
    try {
      return new URL(window.location.href).hostname;
    } catch (_) {
      return window.location.hostname;
    }
  }

  function reportPasswordField() {
    if (reported) return;
    reported = true;

    chrome.runtime.sendMessage(
      {
        type: "passwordFieldDetected",
        url: window.location.href,
        domain: getDomain(),
      },
      function (response) {
        if (!response) return;
        if (response.verdict === "unknown") {
          showWarningBanner(response.domain);
        }
        // "blocked" is handled by background.js (redirects to blocked.html)
        // "safe" needs no action
      }
    );
  }

  // -------------------------------------------------------------------------
  // Warning banner injected into the page
  // -------------------------------------------------------------------------

  function showWarningBanner(domain) {
    if (bannerElement) return;

    const banner = document.createElement("div");
    banner.id = "bromure-phishing-banner";
    banner.setAttribute(
      "style",
      [
        "position: fixed",
        "top: 0",
        "left: 0",
        "right: 0",
        "z-index: 2147483647",
        "background: linear-gradient(135deg, #f59e0b, #d97706)",
        "color: #1a1a1a",
        "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
        "font-size: 14px",
        "padding: 12px 20px",
        "display: flex",
        "align-items: center",
        "gap: 12px",
        "box-shadow: 0 2px 8px rgba(0,0,0,0.2)",
        "animation: bromure-slide-down 0.3s ease-out",
      ].join(";")
    );

    banner.innerHTML = `
      <span style="font-size: 20px; flex-shrink: 0;">&#128274;</span>
      <span style="flex: 1;">
        This is the first time you're entering a password on
        <strong>${escapeHTML(domain)}</strong>.
        Make sure you recognize this site before signing in.
      </span>
      <button id="bromure-trust-btn" style="
        background: rgba(255,255,255,0.5);
        border: 1px solid rgba(0,0,0,0.15);
        color: #1a1a1a;
        padding: 6px 14px;
        border-radius: 4px;
        cursor: pointer;
        font-size: 13px;
        white-space: nowrap;
        flex-shrink: 0;
      ">I know this site</button>
      <button id="bromure-dismiss-btn" style="
        background: none;
        border: none;
        color: rgba(0,0,0,0.5);
        cursor: pointer;
        font-size: 18px;
        padding: 0 4px;
        flex-shrink: 0;
      ">&times;</button>
    `;

    // Add slide-down animation
    const style = document.createElement("style");
    style.textContent = `
      @keyframes bromure-slide-down {
        from { transform: translateY(-100%); opacity: 0; }
        to { transform: translateY(0); opacity: 1; }
      }
    `;
    document.documentElement.appendChild(style);
    document.documentElement.appendChild(banner);
    bannerElement = banner;

    // Push page content down so banner doesn't overlap
    document.body.style.marginTop =
      (parseInt(getComputedStyle(document.body).marginTop) || 0) +
      banner.offsetHeight +
      "px";

    // Button handlers
    document.getElementById("bromure-trust-btn").addEventListener(
      "click",
      function () {
        chrome.runtime.sendMessage({
          type: "trustDomain",
          domain: domain,
        });
        removeBanner();
      }
    );

    document.getElementById("bromure-dismiss-btn").addEventListener(
      "click",
      function () {
        removeBanner();
      }
    );
  }

  function removeBanner() {
    if (bannerElement) {
      const height = bannerElement.offsetHeight;
      bannerElement.remove();
      bannerElement = null;
      // Restore body margin
      const currentMargin = parseInt(getComputedStyle(document.body).marginTop) || 0;
      document.body.style.marginTop =
        Math.max(0, currentMargin - height) + "px";
    }
  }

  function escapeHTML(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  // -------------------------------------------------------------------------
  // Password field detection
  // -------------------------------------------------------------------------

  function checkForPasswordFields(root) {
    const inputs = (root || document).querySelectorAll('input[type="password"]');
    if (inputs.length > 0) {
      reportPasswordField();
    }
  }

  // Check existing DOM
  checkForPasswordFields();

  if (reported) return;

  // Watch for dynamically added password fields
  const observer = new MutationObserver(function (mutations) {
    if (reported) {
      observer.disconnect();
      return;
    }

    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;

        if (node.tagName === "INPUT" && node.type === "password") {
          reportPasswordField();
          observer.disconnect();
          return;
        }

        if (node.querySelectorAll) {
          const inputs = node.querySelectorAll('input[type="password"]');
          if (inputs.length > 0) {
            reportPasswordField();
            observer.disconnect();
            return;
          }
        }
      }

      if (
        mutation.type === "attributes" &&
        mutation.attributeName === "type" &&
        mutation.target.tagName === "INPUT" &&
        mutation.target.type === "password"
      ) {
        reportPasswordField();
        observer.disconnect();
        return;
      }
    }
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["type"],
  });
})();
