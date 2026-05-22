# HTTP MITM Proxy + MitmEngine Parity Audit: macOS ↔ Windows

**Audit Date:** 2025-05-21  
**macOS Revision:** HTTPProxy.swift @ 875b644e, MitmEngine.swift @ 546d34bf  
**Windows Revision:** HttpMitmProxy.cs (current)  
**Scope:** HTTP CONNECT, TLS MITM, token swap, AWS resign, WebSocket upgrade, trace recording, event taps

---

## CRITICAL GAPS (Blocking Production Parity)

### 1. **Subscription & Codex Token Detection Hooks: MISSING**
- **Feature:** SubscriptionTokenSeen / CodexTokenSeen callbacks
- **macOS source:** HTTPProxy.swift:182–198 (detectSubscriptionAccessToken + detectCodexAccessToken calls)
- **Windows status:** MISSING
- **Detail:** macOS fires callbacks when clean sk-ant-oat01-* or JWT token seen on anthropic.com / openai.com. Windows defines callback properties (MitmEngine.cs:78–80) but **never calls them**. No Windows equivalent to swapper.detectSubscriptionAccessToken() exists. Breaks consent-prompt UX for token rotation.
- **Impact:** Users not prompted to update credential status when subscription tokens rotate.

### 2. **Realtime Event Tap: Incomplete Emission**
- **Feature:** RealtimeEventTap cloud-event emission
- **macOS source:** RealtimeEventTap.swift:37–138 (full response.completed → llm.request / tool.use / file.* / command.run emission)
- **Windows status:** PARTIAL
- **Detail:** Windows RealtimeEventTap.cs counts streamed events but **only logs them**. No equivalent to macOS BACEventEmitter.shared.emitDetached() calls (lines 69–72, 85–121). Windows needs to call _onCloudEvent with structured audit events.
- **Impact:** Realtime streaming sessions not audited mid-stream; events fire only at WS close or never.

### 3. **MCP Bearer Injection: No Consent Gating**
- **Feature:** OAuth-brokered MCP server authorization (step 5b)
- **macOS source:** HTTPProxy.swift:205–220
- **Windows status:** PARTIAL
- **Detail:** Windows implements McpProxyHooks.InjectMcpBearer() but lacks consent-broker re-validation at injection time. macOS also doesn't re-validate, but both should for defense-in-depth.
- **Impact:** Low—MCP consent validated upstream. Functional but not defensive.

---

## HIGH-PRIORITY GAPS

### 4. **Chunked Encoding Edge Cases: Windows Implementation Risk**
- **Feature:** Transfer-Encoding: chunked body framing
- **macOS source:** HTTPProxy.swift:983–1027 (deliberately skips chunked on request path; "which we don't handle in this minimal v1")
- **Windows status:** IMPLEMENTED (response path only)
- **Detail:** Windows implements full chunked support (ReadChunkedAsync + FindChunkedEnd) on response path. Manual parser has edge-case risk if final 0\r\n\r\n detection fails (FindChunkedEnd line 751).
- **Impact:** Low-to-Medium. Windows more robust than macOS here, but manual parser has edge-case risk.

### 5. **IPv6 Listening: MISSING**
- **Feature:** Proxy bind to both IPv4 + IPv6
- **macOS source:** N/A (uses vsock, platform-agnostic)
- **Windows status:** MISSING
- **Detail:** Windows TcpListener binds only to provided endpoint (typically 127.0.0.1). VM reaching [::1] will fail. Not implemented.
- **Impact:** Low (most use 127.0.0.1), but breaks explicit IPv6 preference.

### 6. **Cluster CA Hostname Binding: Windows Validation Weaker**
- **Feature:** Cluster CA trust anchoring for private k8s
- **macOS source:** HTTPProxy.swift:1502–1532 (SecTrustSetPolicies with hostname binding)
- **Windows status:** PARTIAL (custom X509Chain, no explicit hostname policy)
- **Detail:** Windows builds custom chain (lines 534–564) but doesn't explicitly set SSL policy hostname. Works for single-cert clusters, risky for multi-SAN.
- **Impact:** Medium. Safe for single-cert, weak for multi-cert SANs.

---

## MEDIUM-PRIORITY GAPS

### 7. **Proxy.pac / System Proxy Registration: MISSING**
- **Feature:** Auto-register as system proxy
- **macOS source:** N/A (handled elsewhere, not in HTTPProxy)
- **Windows status:** MISSING
- **Detail:** macOS proxy discovered via Virtualization.framework network bridge. Windows requires HTTPS_PROXY env var or WinHTTP registration (not implemented). Manual setup required.
- **Impact:** Low-to-Medium. Expected Windows difference, documented in MitmEngine.cs:144–147.

### 8. **OAuth Rotation Rewriter: ENABLED on Windows, DISABLED on macOS**
- **Feature:** OAuth token rotation capture + rewrite
- **macOS source:** HTTPProxy.swift:341–378 (deliberately **disabled** with comment: "refresh-token rotation isn't being mirrored back reliably")
- **Windows status:** IMPLEMENTED (lines 284–291, active)
- **Detail:** macOS disabled due to unresolved fake/real token sync issue. Windows enables it. If the issue isn't fully solved on Windows, this causes divergent behavior + stale-token errors.
- **Impact:** Medium. Windows doing something macOS intentionally didn't. Needs verification.

### 9. **Hop-by-Hop Header Stripping: Different Seams, Same Outcome**
- **Feature:** Removal of hop-by-hop headers
- **macOS source:** HTTPProxy.swift:1194–1207 (done in URLRequest construction)
- **Windows status:** OK (ForceConnectionClose at line 788–807)
- **Detail:** Different implementation, same result. Windows explicit, macOS implicit.
- **Impact:** None—both converge correctly.

### 10. **Error Response Codes: Semantic Mismatch**
- **Feature:** Proxy-generated error responses
- **macOS source:** 404 (discovery block), 451 (compromise)
- **Windows status:** 502 (all upstream failures)
- **Detail:** Windows returns 502 Bad Gateway for any upstream failure. Macros distinguishes 404 (intentional) vs 451 (blocked). Windows's 502 is overly broad.
- **Impact:** Low. 502 acceptable but semantically imprecise.

---

## LOWER-PRIORITY GAPS

### 11. **Debug Logging: Different Instrumentation**
- **Feature:** Performance + state visibility
- **macOS source:** HTTPProxy.swift:260–261, 699–704, 733–757 (BACDebug.log timing + state)
- **Windows status:** PARTIAL (ILogger at DEBUG level only)
- **Detail:** macOS has extensive timing telemetry. Windows minimal. No functional gap.
- **Impact:** Very Low. Diagnostic only.

### 12. **Per-Direction Byte Counting: Implementation Differs (Both Correct)**
- **Feature:** Accurate wire-byte counters for trace
- **macOS source:** WSByteCounters (thread-unsafe by design, one task per field)
- **Windows status:** Interlocked.Add (atomic operations)
- **Detail:** Both correct. Windows slightly more defensive.
- **Impact:** None—both work correctly.

---

## TOP 5 MOST IMPACTFUL GAPS (Ranked by Risk + User Impact)

1. **SubscriptionTokenSeen / CodexTokenSeen Callbacks: MISSING** — Breaks subscription-token rotation UX. Users won't be prompted. **Fix effort:** 1 week (implement swapper.DetectSubscriptionAccessToken + DetectCodexAccessToken, wire into proxy).

2. **RealtimeEventTap Cloud-Event Emission: PARTIAL** — OpenAI Realtime sessions not audited in realtime. Events only at close or never. **Fix effort:** 3–5 days (emit llm.request / tool.use / file.* / command.run to _onCloudEvent).

3. **IPv6 Listening: MISSING** — Breaks if VM uses [::1]. **Fix effort:** 2–3 days (dual-bind or [::] socket).

4. **Cluster CA Hostname Binding: PARTIAL** — Multi-SAN k8s clusters may fail. **Fix effort:** 2–3 days (add explicit hostname policy to X509Chain).

5. **OAuth Rotation Rewriter Divergence: RISKY** — macOS disabled for unresolved issue; Windows enabled. Stale-token risk if issue unresolved. **Fix effort:** 3–5 days (audit fake-token sync path + disable on Windows or confirm fix).

---

## GAP SEVERITY BREAKDOWN

- **CRITICAL (Blocking):** 3 gaps (subscription tokens, realtime events, MCP consent)
- **HIGH (Feature completeness):** 3 gaps (chunked edge cases, IPv6, cluster CA policy)
- **MEDIUM (Observability & divergence):** 2 gaps (proxy.pac registration, OAuth rewriter)
- **LOW (Semantics & logging):** 4 gaps (hop-by-hop, error codes, debug logging, byte counting)

**Total Issues:** 12 (2 CRITICAL, 3 HIGH, 2 MEDIUM, 4 LOW)  
**Estimated Closure Effort:** 2–3 weeks for all gaps; 1 week for critical + high.

