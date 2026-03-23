"use strict";

/**
 * Bromure Trace — background service worker.
 *
 * Captures web request telemetry at three detail levels and forwards events
 * to the host via native messaging (trace-agent.py -> vsock).
 *
 * Level 1 (basic):   URL, method, status, duration
 * Level 2 (headers): + request/response headers, POST body
 * Level 3 (full):    + response bodies via CDP (chrome.debugger)
 */

const NATIVE_HOST = "com.bromure.trace";
const BATCH_INTERVAL_MS = 100;
const MAX_RESPONSE_BODY = 1 * 1024 * 1024; // 1 MB

let nativePort = null;
let traceLevel = 0; // 0 = unconfigured, waiting for config
let eventCounter = 0;

// In-flight requests: requestId -> {startTime, method, url, requestHeaders, postData, initiator, tabId, type}
const inflight = new Map();

// Event batch buffer
let pendingEvents = [];
let flushTimer = null;

// Tabs with debugger attached
const debuggedTabs = new Set();

// Response bodies captured via CDP, keyed by CDP requestId
const cdpBodies = new Map();

// ---------- Native messaging ----------

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    console.error("[Trace] connectNative failed:", e);
    nativePort = null;
    return;
  }

  nativePort.onMessage.addListener((msg) => {
    if (msg.type === "config" && typeof msg.level === "number") {
      const prev = traceLevel;
      traceLevel = msg.level;
      console.log(`[Trace] trace level set to ${traceLevel}`);
      if (prev === 0 && traceLevel > 0) {
        installListeners();
      }
    }
  });

  nativePort.onDisconnect.addListener(() => {
    console.log(
      "[Trace] native host disconnected",
      chrome.runtime.lastError?.message || ""
    );
    nativePort = null;
    traceLevel = 0;
    teardownListeners();
    setTimeout(connectNative, 3000);
  });
}

// ---------- Event batching ----------

function enqueueEvent(evt) {
  pendingEvents.push(evt);
  if (flushTimer === null) {
    flushTimer = setTimeout(flushEvents, BATCH_INTERVAL_MS);
  }
}

function flushEvents() {
  flushTimer = null;
  if (pendingEvents.length === 0 || !nativePort) return;
  const batch = pendingEvents;
  pendingEvents = [];
  try {
    nativePort.postMessage({ type: "events", events: batch });
  } catch (e) {
    console.error("[Trace] failed to send batch:", e);
  }
}

// ---------- webRequest listeners ----------

function onBeforeRequest(details) {
  const entry = {
    startTime: Date.now(),
    method: details.method,
    url: details.url,
    initiator: details.initiator || null,
    tabId: details.tabId,
    type: details.type,
    documentUrl: details.documentUrl || null,
    frameUrl: details.frameUrl || null,
    requestType: details.type,
  };

  // Level 2+: capture POST body
  if (traceLevel >= 2 && details.requestBody) {
    const rb = details.requestBody;
    if (rb.raw && rb.raw.length > 0) {
      // ArrayBuffer data — encode as base64 would be expensive; store size hint
      try {
        const decoder = new TextDecoder("utf-8", { fatal: true });
        const parts = rb.raw.map((p) => (p.bytes ? decoder.decode(p.bytes) : ""));
        entry.postData = parts.join("");
      } catch {
        entry.postData = `[binary, ${rb.raw.reduce((n, p) => n + (p.bytes ? p.bytes.byteLength : 0), 0)} bytes]`;
      }
    } else if (rb.formData) {
      entry.postData = JSON.stringify(rb.formData);
    }
  }

  inflight.set(details.requestId, entry);

  // Level 2+: capture form fields for POST/PUT requests
  if (traceLevel >= 2 && (details.method === "POST" || details.method === "PUT") && details.tabId > 0) {
    chrome.tabs.sendMessage(details.tabId, { type: "captureFormFields" }, (response) => {
      if (chrome.runtime.lastError || !response) return;
      entry.formFields = response.fields || [];
    });
  }
}

function onSendHeaders(details) {
  const entry = inflight.get(details.requestId);
  if (entry && details.requestHeaders) {
    entry.requestHeaders = {};
    for (const h of details.requestHeaders) {
      entry.requestHeaders[h.name] = h.value || "";
    }
  }
}

function onHeadersReceived(details) {
  const entry = inflight.get(details.requestId);
  if (entry && details.responseHeaders) {
    entry.responseHeaders = {};
    for (const h of details.responseHeaders) {
      entry.responseHeaders[h.name] = h.value || "";
    }
  }
}

function onCompleted(details) {
  const entry = inflight.get(details.requestId);
  inflight.delete(details.requestId);
  if (!entry) return;

  eventCounter++;
  const evt = {
    id: "req-" + eventCounter,
    timestamp: Date.now() / 1000,
    method: entry.method,
    url: entry.url,
    statusCode: details.statusCode,
    duration: Date.now() - entry.startTime,
    mimeType: null,
    initiator: entry.initiator,
    tabId: entry.tabId,
    documentUrl: entry.documentUrl,
    frameUrl: entry.frameUrl,
    navType: entry.requestType,
  };

  // Extract mimeType from response headers if available
  if (entry.responseHeaders) {
    const ct =
      entry.responseHeaders["content-type"] ||
      entry.responseHeaders["Content-Type"] ||
      null;
    if (ct) {
      evt.mimeType = ct.split(";")[0].trim();
    }
  }

  if (traceLevel >= 2) {
    if (entry.requestHeaders) evt.requestHeaders = entry.requestHeaders;
    if (entry.postData !== undefined) evt.postData = entry.postData;
    if (entry.responseHeaders) evt.responseHeaders = entry.responseHeaders;
    if (entry.formFields) evt.formFields = entry.formFields;
  }

  enqueueEvent(evt);
}

function onErrorOccurred(details) {
  const entry = inflight.get(details.requestId);
  inflight.delete(details.requestId);
  if (!entry) return;

  eventCounter++;
  enqueueEvent({
    id: "err-" + eventCounter,
    timestamp: Date.now() / 1000,
    method: entry.method,
    url: entry.url,
    statusCode: 0,
    duration: Date.now() - entry.startTime,
    errorText: details.error,
    mimeType: null,
    initiator: entry.initiator,
    tabId: entry.tabId,
  });
}

// ---------- Redirect tracking ----------

function onBeforeRedirect(details) {
  const entry = inflight.get(details.requestId);
  if (!entry) return;
  eventCounter++;
  enqueueEvent({
    id: "redir-" + eventCounter,
    timestamp: Date.now() / 1000,
    method: entry.method,
    url: details.url,
    statusCode: details.statusCode,
    tabId: details.tabId,
    documentUrl: entry.documentUrl,
    navType: "redirect",
    redirectFrom: entry.url,
  });
  entry.url = details.redirectUrl;
}

// ---------- Navigation tracking ----------

function onNavigationCommitted(details) {
  if (details.frameId !== 0) return; // top frame only
  eventCounter++;
  enqueueEvent({
    id: "nav-" + eventCounter,
    timestamp: Date.now() / 1000,
    method: "NAVIGATE",
    url: details.url,
    tabId: details.tabId,
    navType: details.transitionType,
  });
}

// ---------- Level 3: chrome.debugger (CDP) ----------

function attachDebugger(tabId) {
  if (debuggedTabs.has(tabId) || traceLevel < 3) return;
  chrome.debugger.attach({ tabId }, "1.3", () => {
    if (chrome.runtime.lastError) {
      console.warn(
        `[Trace] debugger attach failed for tab ${tabId}:`,
        chrome.runtime.lastError.message
      );
      return;
    }
    debuggedTabs.add(tabId);
    chrome.debugger.sendCommand({ tabId }, "Network.enable", {}, () => {
      if (chrome.runtime.lastError) {
        console.warn("[Trace] Network.enable failed:", chrome.runtime.lastError.message);
      }
    });
  });
}

function onDebuggerEvent(source, method, params) {
  if (method === "Network.loadingFinished") {
    const cdpRequestId = params.requestId;
    const tabId = source.tabId;
    chrome.debugger.sendCommand(
      { tabId },
      "Network.getResponseBody",
      { requestId: cdpRequestId },
      (result) => {
        if (chrome.runtime.lastError || !result) return;
        let body = result.body || "";
        let truncated = false;
        if (body.length > MAX_RESPONSE_BODY) {
          body = body.substring(0, MAX_RESPONSE_BODY);
          truncated = true;
        }
        // Emit as a supplemental event; the main request event was already
        // sent via webRequest.onCompleted. We attach the body by matching URL.
        eventCounter++;
        enqueueEvent({
          id: "body-" + eventCounter,
          timestamp: Date.now() / 1000,
          method: "GET",
          url: params.response?.url || "",
          tabId,
          responseBody: body,
          responseBodyTruncated: truncated,
        });
      }
    );
  }
}

function onDebuggerDetach(source, reason) {
  debuggedTabs.delete(source.tabId);
  // Re-attach if the tab is still alive and we are still at level 3
  if (traceLevel >= 3 && reason === "canceled_by_user") {
    // Do not re-attach when the user manually detached
    return;
  }
  if (traceLevel >= 3) {
    setTimeout(() => attachDebugger(source.tabId), 1000);
  }
}

function onTabCreated(tab) {
  if (traceLevel >= 3 && tab.id) {
    attachDebugger(tab.id);
  }
}

function onTabUpdated(tabId) {
  if (traceLevel >= 3) {
    attachDebugger(tabId);
  }
}

// ---------- Listener management ----------

let listenersInstalled = false;

function installListeners() {
  if (listenersInstalled) return;
  listenersInstalled = true;

  // Level 1+: basic request tracking
  const beforeRequestOpts = ["requestBody"];
  chrome.webRequest.onBeforeRequest.addListener(
    onBeforeRequest,
    { urls: ["<all_urls>"] },
    traceLevel >= 2 ? beforeRequestOpts : []
  );

  chrome.webRequest.onCompleted.addListener(
    onCompleted,
    { urls: ["<all_urls>"] },
    traceLevel >= 2 ? ["responseHeaders"] : []
  );

  chrome.webRequest.onErrorOccurred.addListener(onErrorOccurred, {
    urls: ["<all_urls>"],
  });

  chrome.webRequest.onBeforeRedirect.addListener(onBeforeRedirect, {
    urls: ["<all_urls>"],
  });

  chrome.webNavigation.onCommitted.addListener(onNavigationCommitted);

  // Level 2+: headers
  if (traceLevel >= 2) {
    chrome.webRequest.onSendHeaders.addListener(
      onSendHeaders,
      { urls: ["<all_urls>"] },
      ["requestHeaders"]
    );

    chrome.webRequest.onHeadersReceived.addListener(
      onHeadersReceived,
      { urls: ["<all_urls>"] },
      ["responseHeaders"]
    );
  }

  // Level 3: CDP debugger
  if (traceLevel >= 3) {
    chrome.debugger.onEvent.addListener(onDebuggerEvent);
    chrome.debugger.onDetach.addListener(onDebuggerDetach);
    chrome.tabs.onCreated.addListener(onTabCreated);
    chrome.tabs.onUpdated.addListener(onTabUpdated);

    // Attach to all existing tabs
    chrome.tabs.query({}, (tabs) => {
      for (const tab of tabs) {
        if (tab.id) attachDebugger(tab.id);
      }
    });
  }
}

function teardownListeners() {
  if (!listenersInstalled) return;
  listenersInstalled = false;

  chrome.webRequest.onBeforeRequest.removeListener(onBeforeRequest);
  chrome.webRequest.onCompleted.removeListener(onCompleted);
  chrome.webRequest.onErrorOccurred.removeListener(onErrorOccurred);
  chrome.webRequest.onSendHeaders.removeListener(onSendHeaders);
  chrome.webRequest.onHeadersReceived.removeListener(onHeadersReceived);
  chrome.webRequest.onBeforeRedirect.removeListener(onBeforeRedirect);
  chrome.webNavigation.onCommitted.removeListener(onNavigationCommitted);

  chrome.debugger.onEvent.removeListener(onDebuggerEvent);
  chrome.debugger.onDetach.removeListener(onDebuggerDetach);
  chrome.tabs.onCreated.removeListener(onTabCreated);
  chrome.tabs.onUpdated.removeListener(onTabUpdated);

  // Detach debugger from all tabs
  for (const tabId of debuggedTabs) {
    chrome.debugger.detach({ tabId }, () => {
      void chrome.runtime.lastError; // suppress
    });
  }
  debuggedTabs.clear();

  // Flush remaining events
  flushEvents();
}

// ---------- Startup ----------

connectNative();
