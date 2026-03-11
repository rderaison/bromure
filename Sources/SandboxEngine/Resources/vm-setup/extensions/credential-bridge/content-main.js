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
    const domain = window.location.hostname;
    const requestId = crypto.randomUUID();

    sendRequest({
      requestId: requestId,
      type: "password_get",
      origin: window.location.origin,
      domain: domain,
    }).then((response) => {
      if (
        !response.success ||
        !response.credentials ||
        response.credentials.length === 0
      )
        return;

      // Find username field (input before the password field, or common selectors)
      const usernameField = findUsernameField(form, passwordField);

      if (response.credentials.length === 1) {
        // Single credential — autofill directly
        fillCredential(
          usernameField,
          passwordField,
          response.credentials[0]
        );
      } else {
        // Multiple credentials — show picker
        showCredentialPicker(
          usernameField,
          passwordField,
          response.credentials
        );
      }
    }).catch(() => {
      // Silently ignore — host may not be connected yet
    });
  }

  function findUsernameField(form, passwordField) {
    // Look for common username/email field patterns
    const selectors = [
      'input[type="email"]',
      'input[type="text"][name*="user"]',
      'input[type="text"][name*="email"]',
      'input[type="text"][name*="login"]',
      'input[type="text"][autocomplete*="user"]',
      'input[type="text"]',
    ];
    for (const sel of selectors) {
      const field = form.querySelector(sel);
      if (field && field !== passwordField) return field;
    }
    return null;
  }

  function fillCredential(usernameField, passwordField, credential) {
    if (usernameField) {
      setNativeValue(usernameField, credential.username);
    }
    setNativeValue(passwordField, credential.password);
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

  function showCredentialPicker(usernameField, passwordField, credentials) {
    // Show a simple dropdown below the password field
    const dropdown = document.createElement("div");
    dropdown.style.cssText =
      "position:absolute;z-index:999999;background:#fff;border:1px solid #ccc;" +
      "border-radius:6px;box-shadow:0 4px 12px rgba(0,0,0,0.15);padding:4px 0;" +
      "font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px;" +
      "max-height:200px;overflow-y:auto;min-width:200px;";

    for (const cred of credentials) {
      const item = document.createElement("div");
      item.textContent = cred.username;
      item.style.cssText =
        "padding:8px 12px;cursor:pointer;white-space:nowrap;";
      item.addEventListener("mouseenter", () => {
        item.style.background = "#f0f0f0";
      });
      item.addEventListener("mouseleave", () => {
        item.style.background = "transparent";
      });
      item.addEventListener("click", () => {
        fillCredential(usernameField, passwordField, cred);
        dropdown.remove();
      });
      dropdown.appendChild(item);
    }

    // Position below the target field
    const targetField = usernameField || passwordField;
    const rect = targetField.getBoundingClientRect();
    dropdown.style.left = rect.left + window.scrollX + "px";
    dropdown.style.top = rect.bottom + window.scrollY + 2 + "px";
    document.body.appendChild(dropdown);

    // Remove on click outside
    const removeDropdown = (e) => {
      if (!dropdown.contains(e.target)) {
        dropdown.remove();
        document.removeEventListener("click", removeDropdown, true);
      }
    };
    setTimeout(() => {
      document.addEventListener("click", removeDropdown, true);
    }, 100);
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
