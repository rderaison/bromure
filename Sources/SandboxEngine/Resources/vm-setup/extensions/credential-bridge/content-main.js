/**
 * Content script (MAIN world) — overrides navigator.credentials to proxy
 * WebAuthn requests to the host macOS platform authenticator, and intercepts
 * password form submissions for autofill/save.
 *
 * Runs at document_start in the MAIN world so it can override the real
 * navigator.credentials before any page script accesses it.
 */

(function () {
  "use strict";

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  function bufferToBase64(buf) {
    const bytes = new Uint8Array(
      buf instanceof ArrayBuffer ? buf : buf.buffer || buf
    );
    let binary = "";
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  function base64ToBuffer(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  const pendingRequests = new Map();

  function sendRequest(detail) {
    return new Promise((resolve, reject) => {
      pendingRequests.set(detail.requestId, { resolve, reject });
      window.dispatchEvent(
        new CustomEvent("bromure-credential-request", {
          detail: JSON.stringify(detail),
        })
      );

      // Timeout after 120s (Touch ID may take a while)
      setTimeout(() => {
        if (pendingRequests.has(detail.requestId)) {
          pendingRequests.delete(detail.requestId);
          reject(new DOMException("Request timed out", "NotAllowedError"));
        }
      }, 120000);
    });
  }

  // Listen for responses from the isolated world relay
  window.addEventListener("bromure-credential-response", (event) => {
    let data;
    try {
      data = JSON.parse(event.detail);
    } catch (e) {
      return;
    }

    const pending = pendingRequests.get(data.requestId);
    if (!pending) return;
    pendingRequests.delete(data.requestId);

    if (!data.success) {
      const errorName =
        data.error === "user_cancelled" ? "NotAllowedError" : "NotAllowedError";
      pending.reject(new DOMException(data.error || "Failed", errorName));
      return;
    }

    // Route to the correct handler based on response type
    if (data.type === "passkey_create_response") {
      pending.resolve(buildCreateResponse(data));
    } else if (data.type === "passkey_get_response") {
      if (data.isPassword) {
        // User picked a password from the system sheet during a WebAuthn flow.
        // Can't return a password as a PublicKeyCredential — autofill the form instead.
        autofillPasswordFields(data.username, data.password);
        pending.reject(
          new DOMException("Password autofilled instead", "NotAllowedError")
        );
      } else {
        pending.resolve(buildGetResponse(data));
      }
    } else if (
      data.type === "password_get_response" ||
      data.type === "password_fill_response" ||
      data.type === "password_save_response"
    ) {
      pending.resolve(data);
    }
  });

  // -----------------------------------------------------------------------
  // WebAuthn credential response builders
  // -----------------------------------------------------------------------

  function buildCreateResponse(data) {
    const credentialId = base64ToBuffer(data.credentialId);
    const response = {
      attestationObject: base64ToBuffer(data.attestationObject),
      clientDataJSON: base64ToBuffer(data.clientDataJSON),
      getTransports: () => ["internal"],
      getAuthenticatorData: () =>
        data.authenticatorData
          ? base64ToBuffer(data.authenticatorData)
          : new ArrayBuffer(0),
      getPublicKey: () => null,
      getPublicKeyAlgorithm: () => -7,
    };

    return {
      id: data.credentialId,
      rawId: credentialId,
      type: "public-key",
      response: response,
      authenticatorAttachment: "platform",
      getClientExtensionResults: () => ({}),
    };
  }

  function buildGetResponse(data) {
    const credentialId = base64ToBuffer(data.credentialId);
    const response = {
      authenticatorData: base64ToBuffer(data.authenticatorData),
      clientDataJSON: base64ToBuffer(data.clientDataJSON),
      signature: base64ToBuffer(data.signature),
      userHandle: data.userHandle
        ? base64ToBuffer(data.userHandle)
        : new ArrayBuffer(0),
    };

    return {
      id: data.credentialId,
      rawId: credentialId,
      type: "public-key",
      response: response,
      authenticatorAttachment: "platform",
      getClientExtensionResults: () => ({}),
    };
  }

  // -----------------------------------------------------------------------
  // Override navigator.credentials
  // -----------------------------------------------------------------------

  const originalCreate = navigator.credentials.create.bind(
    navigator.credentials
  );
  const originalGet = navigator.credentials.get.bind(navigator.credentials);

  navigator.credentials.create = function (options) {
    if (options && options.publicKey) {
      return handlePasskeyCreate(options.publicKey);
    }
    return originalCreate(options);
  };

  navigator.credentials.get = function (options) {
    if (options && options.publicKey) {
      return handlePasskeyGet(options.publicKey);
    }
    return originalGet(options);
  };

  function handlePasskeyCreate(publicKey) {
    const requestId = crypto.randomUUID();
    const detail = {
      requestId: requestId,
      type: "passkey_create",
      origin: window.location.origin,
      rp: {
        id: publicKey.rp.id || window.location.hostname,
        name: publicKey.rp.name || "",
      },
      user: {
        id: bufferToBase64(publicKey.user.id),
        name: publicKey.user.name,
        displayName: publicKey.user.displayName || publicKey.user.name,
      },
      challenge: bufferToBase64(publicKey.challenge),
      pubKeyCredParams: publicKey.pubKeyCredParams || [
        { type: "public-key", alg: -7 },
      ],
      excludeCredentials: (publicKey.excludeCredentials || []).map((c) => ({
        type: c.type,
        id: bufferToBase64(c.id),
      })),
      authenticatorSelection: publicKey.authenticatorSelection || {},
      attestation: publicKey.attestation || "none",
      extensions: publicKey.extensions || {},
    };

    return sendRequest(detail);
  }

  function handlePasskeyGet(publicKey) {
    const requestId = crypto.randomUUID();
    const detail = {
      requestId: requestId,
      type: "passkey_get",
      origin: window.location.origin,
      rpId: publicKey.rpId || window.location.hostname,
      challenge: bufferToBase64(publicKey.challenge),
      allowCredentials: (publicKey.allowCredentials || []).map((c) => ({
        type: c.type,
        id: bufferToBase64(c.id),
      })),
      userVerification: publicKey.userVerification || "preferred",
      extensions: publicKey.extensions || {},
    };

    return sendRequest(detail);
  }

  // -----------------------------------------------------------------------
  // Password autofill and save
  // -----------------------------------------------------------------------

  // Track whether we've offered autofill for a given form
  const autofillOffered = new WeakSet();

  // Track credentials we autofilled so we don't offer to save them back
  const autofilledCredentials = new WeakMap();

  function findPasswordForms() {
    const pwFields = document.querySelectorAll('input[type="password"]');
    for (const pw of pwFields) {
      const form = pw.closest("form") || pw.parentElement;
      if (!form || autofillOffered.has(form)) continue;
      autofillOffered.add(form);
      offerAutofill(form, pw);
    }
  }

  function offerAutofill(form, passwordField) {
    // Only offer autofill on visible password fields to prevent hidden-field attacks
    if (!isVisible(passwordField)) return;

    const domain = window.location.hostname;
    const requestId = crypto.randomUUID();

    sendRequest({
      requestId: requestId,
      type: "password_get",
      origin: window.location.origin,
      domain: domain,
    })
      .then((response) => {
        if (
          !response.success ||
          !response.credentials ||
          response.credentials.length === 0
        )
          return;

        const usernameField = findUsernameField(form, passwordField);

        // Never auto-fill — always show a picker requiring user interaction.
        // This prevents malicious pages with hidden password fields from
        // silently capturing credentials.
        showCredentialPicker(usernameField, passwordField, response.credentials);
      })
      .catch(() => {
        // Silently ignore — host may not be connected yet
      });
  }

  function findUsernameField(form, passwordField) {
    // Look for common username/email field patterns
    const selectors = [
      'input[autocomplete="username"]',
      'input[autocomplete="email"]',
      'input[type="email"]',
      'input[type="text"][name*="user" i]',
      'input[type="text"][name*="email" i]',
      'input[type="text"][name*="login" i]',
      'input[type="tel"][name*="user" i]',
      'input[type="text"][autocomplete*="user"]',
      'input[type="text"]',
      'input:not([type])',
    ];
    for (const sel of selectors) {
      const field = form.querySelector(sel);
      if (field && field !== passwordField && isVisible(field)) return field;
    }
    // Fallback: find the closest visible input before the password field
    const allInputs = Array.from(form.querySelectorAll("input"));
    const pwIdx = allInputs.indexOf(passwordField);
    for (let i = pwIdx - 1; i >= 0; i--) {
      const f = allInputs[i];
      if (f.type !== "hidden" && f.type !== "submit" && isVisible(f)) return f;
    }
    return null;
  }

  function isVisible(el) {
    return el.offsetParent !== null || el.getClientRects().length > 0;
  }

  function fillCredential(usernameField, passwordField, credential) {
    // If this is an iCloud credential without a password, fetch it first
    if (credential.source === "icloud" && !credential.password) {
      const requestId = crypto.randomUUID();
      sendRequest({
        requestId: requestId,
        type: "password_fill",
        origin: window.location.origin,
        domain: window.location.hostname,
        username: credential.username,
      })
        .then((response) => {
          if (response.success && response.password) {
            doFill(usernameField, passwordField, response.username, response.password);
          }
        })
        .catch(() => {});
      return;
    }
    doFill(usernameField, passwordField, credential.username, credential.password);
  }

  function doFill(usernameField, passwordField, username, password) {
    if (usernameField) {
      setNativeValue(usernameField, username);
    }
    setNativeValue(passwordField, password);
    // Remember what we filled so we don't offer to save it back
    const form = passwordField.closest("form") || passwordField.parentElement;
    if (form) {
      autofilledCredentials.set(form, { username, password });
    }
  }

  function setNativeValue(element, value) {
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    ).set;
    setter.call(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function autofillPasswordFields(username, password) {
    // Find visible password field on the page and fill it + any username field
    const pwField = document.querySelector('input[type="password"]');
    if (pwField) {
      const form = pwField.closest("form") || pwField.parentElement;
      const userField = form ? findUsernameField(form, pwField) : null;
      if (userField) setNativeValue(userField, username);
      setNativeValue(pwField, password);
    }
  }

  // Currently visible credential picker (only one at a time)
  let activeDropdown = null;

  function showCredentialPicker(usernameField, passwordField, credentials) {
    // Remove any existing picker
    if (activeDropdown) {
      activeDropdown.remove();
      activeDropdown = null;
    }

    const isDark =
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches;
    const bg = isDark ? "#2a2a2c" : "#fff";
    const border = isDark ? "#48484a" : "#c8c8c8";
    const hoverBg = isDark ? "#3a3a3c" : "#e8e8ed";
    const textColor = isDark ? "#f5f5f7" : "#1d1d1f";
    const subColor = isDark ? "#98989d" : "#86868b";
    const iconBg = isDark ? "#48484a" : "#e8e8ed";

    const dropdown = document.createElement("div");
    dropdown.style.cssText =
      "position:absolute;z-index:999999;background:" + bg + ";" +
      "border:1px solid " + border + ";border-radius:8px;" +
      "box-shadow:0 4px 16px rgba(0,0,0," + (isDark ? "0.4" : "0.15") + ");" +
      "padding:4px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;" +
      "font-size:13px;max-height:240px;overflow-y:auto;min-width:240px;" +
      "color:" + textColor + ";";
    activeDropdown = dropdown;

    for (const cred of credentials) {
      const item = document.createElement("div");
      item.style.cssText =
        "padding:8px 12px;cursor:pointer;display:flex;align-items:center;gap:10px;";

      // Key icon
      const icon = document.createElement("div");
      icon.textContent = "\uD83D\uDD11";
      icon.style.cssText =
        "width:28px;height:28px;border-radius:6px;background:" + iconBg + ";" +
        "display:flex;align-items:center;justify-content:center;font-size:15px;" +
        "flex-shrink:0;";

      // Text container
      const text = document.createElement("div");
      text.style.cssText = "overflow:hidden;min-width:0;";

      const username = document.createElement("div");
      username.textContent = cred.username;
      username.style.cssText =
        "font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;";

      const maskedPw = document.createElement("div");
      maskedPw.textContent = "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022";
      maskedPw.style.cssText =
        "font-size:11px;color:" + subColor + ";letter-spacing:1px;";

      text.appendChild(username);
      text.appendChild(maskedPw);
      item.appendChild(icon);
      item.appendChild(text);

      item.addEventListener("mouseenter", () => {
        item.style.background = hoverBg;
        item.style.borderRadius = "4px";
      });
      item.addEventListener("mouseleave", () => {
        item.style.background = "transparent";
      });
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        fillCredential(usernameField, passwordField, cred);
        dropdown.remove();
        activeDropdown = null;
      });
      dropdown.appendChild(item);
    }

    // Position below the target field
    const targetField = usernameField || passwordField;
    const rect = targetField.getBoundingClientRect();
    dropdown.style.left = rect.left + window.scrollX + "px";
    dropdown.style.top = rect.bottom + window.scrollY + 2 + "px";
    document.body.appendChild(dropdown);

    // Remove on click outside or Escape
    const dismiss = (e) => {
      if (!dropdown.contains(e.target)) {
        dropdown.remove();
        activeDropdown = null;
        document.removeEventListener("click", dismiss, true);
        document.removeEventListener("keydown", dismissKey, true);
      }
    };
    const dismissKey = (e) => {
      if (e.key === "Escape") {
        dropdown.remove();
        activeDropdown = null;
        document.removeEventListener("click", dismiss, true);
        document.removeEventListener("keydown", dismissKey, true);
      }
    };
    setTimeout(() => {
      document.addEventListener("click", dismiss, true);
      document.addEventListener("keydown", dismissKey, true);
    }, 100);

    // Re-show picker when the user focuses the field again
    const refocus = () => {
      if (!document.body.contains(dropdown) && document.body.contains(targetField)) {
        showCredentialPicker(usernameField, passwordField, credentials);
      }
    };
    targetField.addEventListener("focus", refocus, { once: true });
    if (usernameField && usernameField !== targetField) {
      usernameField.addEventListener("focus", refocus, { once: true });
    }
  }

  // -----------------------------------------------------------------------
  // Password save detection
  // -----------------------------------------------------------------------

  function watchFormSubmissions() {
    document.addEventListener(
      "submit",
      (e) => {
        const form = e.target;
        if (!(form instanceof HTMLFormElement)) return;
        trySavePassword(form);
      },
      true
    );

    // Also watch for XHR-based logins (click on submit button)
    document.addEventListener(
      "click",
      (e) => {
        const btn = e.target.closest(
          'button[type="submit"], input[type="submit"]'
        );
        if (!btn) return;
        const form = btn.closest("form");
        if (form) {
          // Delay slightly so the form values are populated
          setTimeout(() => trySavePassword(form), 100);
        }
      },
      true
    );
  }

  function trySavePassword(form) {
    const pwField = form.querySelector('input[type="password"]');
    if (!pwField || !pwField.value) return;

    const usernameField = findUsernameField(form, pwField);
    if (!usernameField || !usernameField.value) return;

    const domain = window.location.hostname;
    const username = usernameField.value;
    const password = pwField.value;

    // Don't offer to save credentials we just autofilled
    const filled = autofilledCredentials.get(form);
    if (filled && filled.username === username && filled.password === password) return;

    // Save via the bridge
    const requestId = crypto.randomUUID();
    sendRequest({
      requestId: requestId,
      type: "password_save",
      origin: window.location.origin,
      domain: domain,
      username: username,
      password: password,
    }).catch(() => {
      // Ignore save failures silently
    });
  }

  // -----------------------------------------------------------------------
  // Initialize
  // -----------------------------------------------------------------------

  // Watch for password forms (they may appear dynamically)
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      findPasswordForms();
      watchFormSubmissions();
    });
  } else {
    findPasswordForms();
    watchFormSubmissions();
  }

  // Re-scan when DOM changes (SPAs, dynamic forms)
  const observer = new MutationObserver(() => {
    findPasswordForms();
  });
  const startObserving = () => {
    if (document.body) {
      observer.observe(document.body, { childList: true, subtree: true });
    }
  };
  if (document.body) {
    startObserving();
  } else {
    document.addEventListener("DOMContentLoaded", startObserving);
  }
})();
