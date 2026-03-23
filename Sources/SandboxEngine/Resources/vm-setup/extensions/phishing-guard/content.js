(function () {
  "use strict";

  let reported = false;
  let bannerElement = null;
  const approvedForms = new WeakSet();

  function getDomain() {
    try {
      return new URL(window.location.href).hostname;
    } catch (_) {
      return window.location.hostname;
    }
  }

  function getRegistrableDomain(hostname) {
    var h = hostname.replace(/^www\./, "");
    var parts = h.split(".");
    if (parts.length <= 2) return h;
    var twoPartTLDs = [
      "co.uk", "org.uk", "com.au", "co.jp", "co.kr", "co.nz",
      "com.br", "com.mx", "co.in", "co.za", "com.cn", "com.tw",
      "co.id", "com.sg", "com.ar", "com.co", "com.tr", "com.hk",
    ];
    var lastTwo = parts.slice(-2).join(".");
    if (twoPartTLDs.indexOf(lastTwo) !== -1) return parts.slice(-3).join(".");
    return parts.slice(-2).join(".");
  }

  /**
   * Collect cross-domain form action URLs from forms containing password fields.
   */
  function getFormActionDomains() {
    var domains = [];
    var pageDomain = getDomain();
    var pageReg = getRegistrableDomain(pageDomain);
    var forms = document.querySelectorAll("form");

    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      if (!form.querySelector('input[type="password"]')) continue;

      // Check form action
      var action = form.getAttribute("action");
      if (action && action !== "" && action !== "#" && !action.startsWith("javascript:")) {
        try {
          var url = new URL(action, window.location.href);
          if (getRegistrableDomain(url.hostname) !== pageReg) {
            domains.push(url.hostname);
          }
        } catch (_) {}
      }

      // Check submit buttons with formaction
      var buttons = form.querySelectorAll("[formaction]");
      for (var j = 0; j < buttons.length; j++) {
        try {
          var btnUrl = new URL(buttons[j].getAttribute("formaction"), window.location.href);
          if (getRegistrableDomain(btnUrl.hostname) !== pageReg) {
            domains.push(btnUrl.hostname);
          }
        } catch (_) {}
      }
    }

    // Deduplicate
    return domains.filter(function (d, i) { return domains.indexOf(d) === i; });
  }

  function reportPasswordField() {
    if (reported) return;
    reported = true;

    var formActionDomains = getFormActionDomains();

    chrome.runtime.sendMessage(
      {
        type: "passwordFieldDetected",
        url: window.location.href,
        domain: getDomain(),
        formActionDomains: formActionDomains,
      },
      function (response) {
        if (!response) return;
        if (response.verdict === "unknown") {
          showWarningBanner(response.domain, null);
        } else if (response.verdict === "cross-domain") {
          showWarningBanner(response.domain, response.actionDomain);
        }
        // "blocked" is handled by background.js (redirects to blocked.html)
        // "safe" needs no action
      }
    );
  }

  // -------------------------------------------------------------------------
  // Warning banner injected into the page
  // -------------------------------------------------------------------------

  function showWarningBanner(domain, actionDomain) {
    if (bannerElement) return;

    var message;
    if (actionDomain) {
      message =
        "This page at <strong>" + escapeHTML(domain) + "</strong> " +
        "will send your password to <strong>" + escapeHTML(actionDomain) + "</strong>, " +
        "a different site. Make sure this is expected before signing in.";
    } else {
      message =
        "This is the first time you\u2019re entering a password on " +
        "<strong>" + escapeHTML(domain) + "</strong>. " +
        "Make sure you recognize this site before signing in.";
    }

    var banner = document.createElement("div");
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

    banner.innerHTML =
      '<span style="font-size: 20px; flex-shrink: 0;">&#128274;</span>' +
      '<span style="flex: 1;">' + message + '</span>' +
      '<button id="bromure-trust-btn" style="' +
        "background: rgba(255,255,255,0.5);" +
        "border: 1px solid rgba(0,0,0,0.15);" +
        "color: #1a1a1a;" +
        "padding: 6px 14px;" +
        "border-radius: 4px;" +
        "cursor: pointer;" +
        "font-size: 13px;" +
        "white-space: nowrap;" +
        "flex-shrink: 0;" +
      '">I know this site</button>' +
      '<button id="bromure-dismiss-btn" style="' +
        "background: none;" +
        "border: none;" +
        "color: rgba(0,0,0,0.5);" +
        "cursor: pointer;" +
        "font-size: 18px;" +
        "padding: 0 4px;" +
        "flex-shrink: 0;" +
      '">&times;</button>';

    // Add slide-down animation
    var style = document.createElement("style");
    style.textContent =
      "@keyframes bromure-slide-down {" +
      "  from { transform: translateY(-100%); opacity: 0; }" +
      "  to { transform: translateY(0); opacity: 1; }" +
      "}";
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
      var height = bannerElement.offsetHeight;
      bannerElement.remove();
      bannerElement = null;
      // Restore body margin
      var currentMargin = parseInt(getComputedStyle(document.body).marginTop) || 0;
      document.body.style.marginTop =
        Math.max(0, currentMargin - height) + "px";
    }
  }

  function escapeHTML(str) {
    var div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  // -------------------------------------------------------------------------
  // Form submit interceptor — safety net for cross-domain password posts
  // -------------------------------------------------------------------------

  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!form.querySelector('input[type="password"]')) return;
    if (approvedForms.has(form)) return;

    // Determine effective action (formaction on submitter overrides form action)
    var actionUrl;
    if (e.submitter && e.submitter.hasAttribute("formaction")) {
      actionUrl = e.submitter.formAction;
    } else {
      actionUrl = form.action;
    }
    if (!actionUrl) return;

    try {
      var actionHost = new URL(actionUrl).hostname;
      var pageHost = getDomain();
      if (getRegistrableDomain(actionHost) === getRegistrableDomain(pageHost)) return;
    } catch (_) {
      return;
    }

    // Cross-domain submit — check with background if it's an auth provider
    e.preventDefault();
    var savedSubmitter = e.submitter;

    chrome.runtime.sendMessage(
      { type: "checkFormAction", actionDomain: actionHost },
      function (response) {
        if (response && response.isAuthProvider) {
          approvedForms.add(form);
          form.requestSubmit(savedSubmitter);
          return;
        }
        showSubmitConfirmation(form, savedSubmitter, pageHost, actionHost);
      }
    );
  }, true);

  function showSubmitConfirmation(form, submitter, pageDomain, actionDomain) {
    var overlay = document.createElement("div");
    overlay.setAttribute("style", [
      "position: fixed",
      "top: 0", "left: 0", "right: 0", "bottom: 0",
      "z-index: 2147483647",
      "background: rgba(0,0,0,0.5)",
      "display: flex",
      "align-items: center",
      "justify-content: center",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
    ].join(";"));

    overlay.innerHTML =
      '<div style="' +
        "background: white; border-radius: 12px; padding: 24px; max-width: 440px;" +
        "box-shadow: 0 8px 32px rgba(0,0,0,0.3); color: #1a1a1a;" +
      '">' +
        '<div style="font-size: 32px; text-align: center; margin-bottom: 12px;">&#9888;&#65039;</div>' +
        '<p style="font-size: 15px; line-height: 1.5; margin: 0 0 8px;">' +
          "This page at <strong>" + escapeHTML(pageDomain) + "</strong> " +
          "is about to send your password to:" +
        "</p>" +
        '<p style="font-size: 17px; font-weight: 600; text-align: center; ' +
          'color: #c2410c; margin: 8px 0 16px;">' + escapeHTML(actionDomain) + "</p>" +
        '<p style="font-size: 14px; color: #666; margin: 0 0 20px;">This is a different site. Only continue if you trust this destination.</p>' +
        '<div style="display: flex; gap: 10px; justify-content: flex-end;">' +
          '<button id="bromure-xd-cancel" style="' +
            "padding: 8px 20px; border-radius: 6px; border: 1px solid #ccc;" +
            "background: white; cursor: pointer; font-size: 14px;" +
          '">Cancel</button>' +
          '<button id="bromure-xd-continue" style="' +
            "padding: 8px 20px; border-radius: 6px; border: none;" +
            "background: #f59e0b; color: white; cursor: pointer; font-size: 14px;" +
          '">Continue</button>' +
        "</div>" +
      "</div>";

    document.documentElement.appendChild(overlay);

    overlay.querySelector("#bromure-xd-cancel").onclick = function () {
      overlay.remove();
    };
    overlay.querySelector("#bromure-xd-continue").onclick = function () {
      overlay.remove();
      approvedForms.add(form);
      form.requestSubmit(submitter);
    };
  }

  // -------------------------------------------------------------------------
  // Password field detection
  // -------------------------------------------------------------------------

  function checkForPasswordFields(root) {
    var inputs = (root || document).querySelectorAll('input[type="password"]');
    if (inputs.length > 0) {
      reportPasswordField();
    }
  }

  // Check existing DOM
  checkForPasswordFields();

  if (reported) return;

  // Watch for dynamically added password fields
  var observer = new MutationObserver(function (mutations) {
    if (reported) {
      observer.disconnect();
      return;
    }

    for (var m = 0; m < mutations.length; m++) {
      var mutation = mutations[m];
      for (var n = 0; n < mutation.addedNodes.length; n++) {
        var node = mutation.addedNodes[n];
        if (node.nodeType !== Node.ELEMENT_NODE) continue;

        if (node.tagName === "INPUT" && node.type === "password") {
          reportPasswordField();
          observer.disconnect();
          return;
        }

        if (node.querySelectorAll) {
          var inputs = node.querySelectorAll('input[type="password"]');
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
