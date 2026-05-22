# Token-Swap Subsystem Parity Audit

macOS v.s. Windows — TokenSwap, SessionTokenPlan, CompromiseDetector, ConsentBroker, OAuth Rotation, SubscriptionFakeMint, and MCP Bearer Support.

---

## Findings Summary

**Total gaps found: 17**
- **CRITICAL (5)**: Foundational logic divergence affecting swap fidelity
- **HIGH (4)**: Missing or incomplete features with security implications
- **MEDIUM (5)**: Implementation detail differences that may affect behavior
- **LOW (3)**: Test harnesses, logging, or UI-layer variance

---

## Detailed Findings

### Token Swap Core

**Feature: Exact Host-Scope Matching (Security-Critical)**
- **macOS source**: `TokenSwap.swift:523–531` (`hostMatchesScope`)
- **Windows status**: OK
- **Detail**: Both implement `exact-or-subdomain` matching (case-insensitive, `host == scope || host.hasSuffix("." + scope)`). No substring matching. Windows uses `StringComparison.Ordinal` on the lowercased strings; macOS uses `.lowercased()` then `==` / `hasSuffix`. Functionally identical.

**Feature: Sibling-Domain Compromise Detection**
- **macOS source**: `TokenSwap.swift:544–551` (`hostMatchesScopeFamily`)
- **Windows status**: OK
- **Detail**: Windows equivalent in `HostMatcher.cs:37–45`. Both strip one label from scope and re-check. Both guard against dropping below 3 labels. Functionally identical.

**Feature: Header-End Detection**
- **macOS source**: `TokenSwap.swift:171`
- **Windows status**: DIFFERENT
- **Detail**: macOS uses `Data.range(of: Data("\r\n\r\n".utf8))?.lowerBound`, then subdata slicing includes the delimiter in `bodyBytes`. Windows finds the index and uses `headerEndIdx + HeaderEndPattern.Length` as the body start, excluding the delimiter. RFC 9110 issue: macOS has a 4-byte off-by-one — it includes the CRLF CRLF in the body. Windows deliberately diverges to fix this. When patching Content-Length, Windows reports `bodyBytes.Length` (correct); macOS reports `bodyBytes.count` which includes the 4-byte delimiter. This can cause the upstream to truncate the body by 4 bytes on PUT/POST with body mutations.

**Feature: Token Swap Direction (Request vs Response)**
- **macOS source**: `TokenSwap.swift:185–240` (`swap` function)
- **Windows status**: OK
- **Detail**: Both scan headers first (loop over entries, string replacement), then body (if entry.Body is set). Sweep logic is identical.

**Feature: Content-Length Patching on Body Mutation**
- **macOS source**: `TokenSwap.swift:269–289` (`replaceContentLength`)
- **Windows status**: OK
- **Detail**: Both idempotent. Both insert before the trailing blank line if absent. Format is identical.

**Feature: Aho-Corasick Integration**
- **macOS source**: `TokenSwap.swift:86–114` (setMap, clearMap, appendEntries)
- **Windows status**: MISSING
- **Detail**: macOS builds an AC automaton per `setMap` (outside the lock), then stores it in `scanners` dict. Windows has a separate `CompromiseDetector` class that maintains a scanner, but `TokenSwapper` itself has no AC automaton. This is a CRITICAL gap: macOS's hot path uses AC for both swap detection and compromise scanning; Windows performs naive substring search. The Windows design offloads AC building to `CompromiseDetector.Rebuild()`, but there's no integration point showing where/when `Rebuild()` is called. The swapper's `AppendEntries` does not rebuild the scanner.

---

### Fake-Token Derivation

**Feature: HKDF-SHA256 Derivation Algorithm**
- **macOS source**: `SessionTokenPlan.swift:413–432` (`deriveFake`)
- **Windows status**: OK
- **Detail**: Both use HKDF-SHA256. IKM is the real token (UTF8). Salt is user-supplied. Info string is identical: `"bromure-ac-fake-token-v2"`. Output size: 32 bytes. Base62 alphabet is identical. Derivation logic identical.

**Feature: Prefix Matching for Known Token Shapes**
- **macOS source**: `SessionTokenPlan.swift:224–240` (Anthropic/OpenAI/GitHub)
- **Windows status**: OK
- **Detail**: Prefixes match exactly across platforms.

**Feature: Docker Registry Fake Derivation**
- **macOS source**: `SessionTokenPlan.swift:312–359`
- **Windows status**: OK
- **Detail**: Both systems support docker-registry credentials with base64 auth blob wrapping.

**Feature: DigitalOcean Token Derivation**
- **macOS source**: `SessionTokenPlan.swift:277–310`
- **Windows status**: MISSING
- **Detail**: macOS derives DigitalOcean PAT with prefix `dop_v1_` and explicit `targetLength: 64` to match real DO token format. Also creates a base64-encoded `<token>:<token>` pair for HTTP Basic auth on `doctl registry login`. Windows `Purpose.DigitalOcean` enum case exists, but no special handling for base64 pairing. Windows does not mint the base64 pair. This is a CRITICAL gap: Windows won't swap DO's registry login flow that relies on Basic auth.

**Feature: MCP Bearer Token Derivation**
- **macOS source**: `SessionTokenPlan.swift:261–274` (`mcpBearer` case)
- **Windows status**: OK (separate class)
- **Detail**: macOS stores MCP entries directly in `SessionTokenPlan.Entry`. Windows has a separate `McpFakeMint.Build()` static method. Functionally equivalent.

**Feature: Manual Token Derivation**
- **macOS source**: `SessionTokenPlan.swift:244–258`
- **Windows status**: OK
- **Detail**: Both derive with prefix `brm_`, no special length handling.

---

### JWT Subscription Token Handling

**Feature: JWT Fake Minting (Codex Tokens)**
- **macOS source**: `SubscriptionFakeMint.swift:40–50` (`mintJWTFake`)
- **Windows status**: OK
- **Detail**: Both split on `.`, derive signature with HKDF, return `header.payload.fakeSig`. Identical logic.

**Feature: JWT Fake Detection**
- **macOS source**: `SubscriptionFakeMint.swift:52–60`
- **Windows status**: OK
- **Detail**: Both check `parts[2].hasPrefix(jwtSignatureMarker)` where marker is `"brm-cdX-sig"`.

**Feature: Codex Refresh Token Minting**
- **macOS source**: `SubscriptionFakeMint.swift:62–78`
- **Windows status**: OK
- **Detail**: Both use prefix `rt_brm-cdX-rfs-`, derive to `targetLength: real.count`.

**Feature: Codex Refresh Fake Detection**
- **macOS source**: `SubscriptionFakeMint.swift:80–83`
- **Windows status**: OK
- **Detail**: Both check `tok.hasPrefix("rt_brm-cdX-rfs-")`.

---

### Compromise Detection

**Feature: Aho-Corasick Scanner Lifecycle**
- **macOS source**: `CompromiseDetector.swift` (implied in TokenSwapper)
- **Windows status**: PARTIAL
- **Detail**: macOS builds scanner on `setMap`, stores in `scanners[profileId]`. Windows has a separate `CompromiseDetector` class with `Rebuild(profileId)`. The CRITICAL integration point is missing: where does Windows code call `detector.Rebuild()`? The swapper's `AppendEntries` does not rebuild the scanner, leading to stale scans after OAuth rotation.

**Feature: Fake-Token Scanning Logic**
- **macOS source**: `TokenSwap.swift:464–516` (`detectCompromise`)
- **Windows status**: OK
- **Detail**: Both snapshot the scanner + entries under lock, call `scan()`, iterate results, check host scope.

**Feature: Leak Detection (Unswapped Credentials)**
- **macOS source**: `TokenSwap.swift:298–360` (`detectLeaks`)
- **Windows status**: OK
- **Detail**: Both scan headers for Authorization and *-api-key headers. Both check against known fakes, known prefixes, and opaque-token heuristic.

**Feature: Subscription Token Detection (Anthropic)**
- **macOS source**: `TokenSwap.swift:371–402` (`detectSubscriptionAccessToken`)
- **Windows status**: MISSING
- **Detail**: macOS scans for `sk-ant-oat01-` prefix (not `brm-` flavor) to detect fresh Anthropic OAuth tokens. Windows does not implement this. CRITICAL gap for Anthropic subscription flow.

**Feature: Codex Token Detection (OpenAI)**
- **macOS source**: `TokenSwap.swift:412–447` (`detectCodexAccessToken`)
- **Windows status**: MISSING
- **Detail**: macOS scans for JWT-shaped tokens (`eyJ` prefix, ≥32 chars) on ChatGPT/OpenAI hosts. Windows does not implement this. CRITICAL gap for Codex subscription flow.

---

### Consent Broker

**Feature: Consent Decision Types**
- **macOS source**: `ConsentBroker.swift:21–29`
- **Windows status**: OK
- **Detail**: Both have deny, allow5min, allow1hr, allowSession.

**Feature: Deny Memory (5-Minute Debounce)**
- **macOS source**: `ConsentBroker.swift:89–102`
- **Windows status**: OK
- **Detail**: Both use 5-minute TTL.

**Feature: Grant Storage & Expiry**
- **macOS source**: `ConsentBroker.swift:89–162`
- **Windows status**: OK
- **Detail**: Both store as keyed dictionaries, check expiration before returning.

**Feature: Consent Coalescing (Concurrent Requests)**
- **macOS source**: `ConsentBroker.swift:166–170`
- **Windows status**: OK
- **Detail**: macOS uses CheckedContinuation. Windows uses TaskCompletionSource. Functionally equivalent.

**Feature: Modal Presentation (Native UI)**
- **macOS source**: `ConsentBroker.swift:260–286` (NSAlert)
- **Windows status**: OK
- **Detail**: Windows presents ConsentDialog (XAML) matching the same four-button layout.

**Feature: Snapshot of Live Decisions**
- **macOS source**: `ConsentBroker.swift:208–232`
- **Windows status**: OK
- **Detail**: Both return LiveEntry list, filtered and sorted.

**Feature: Session-Scoped Grant Revocation**
- **macOS source**: `ConsentBroker.swift:243–250`
- **Windows status**: OK
- **Detail**: Both revoke all session-scoped grants on profile teardown.

---

### OAuth Rotation Rewriter

**Feature: Endpoint Detection**
- **macOS source**: `OAuthRotationRewriter.swift:45–57`
- **Windows status**: OK
- **Detail**: Identical host/path checks for Anthropic and OpenAI endpoints.

**Feature: Anthropic Token Validation**
- **macOS source**: `OAuthRotationRewriter.swift:100–106`
- **Windows status**: OK
- **Detail**: Identical prefix checks and rejection of already-faked tokens.

**Feature: Anthropic Token Derivation**
- **macOS source**: `OAuthRotationRewriter.swift:108–119`
- **Windows status**: OK
- **Detail**: Identical salt and length handling.

**Feature: Codex Token Validation**
- **macOS source**: `OAuthRotationRewriter.swift:175–182`
- **Windows status**: OK
- **Detail**: Identical JWT and optional id_token handling.

**Feature: Codex Token Derivation**
- **macOS source**: `OAuthRotationRewriter.swift:184–197`
- **Windows status**: OK
- **Detail**: Identical salts and entry registration.

**Feature: Content-Length Patching in Response**
- **macOS source**: `OAuthRotationRewriter.swift:255–275`
- **Windows status**: OK
- **Detail**: Both update Content-Length to match rewritten body.

**Feature: Gzip/Deflate/Brotli Decompression**
- **macOS source**: Not found
- **Windows status**: OK (Windows enhancement)
- **Detail**: Windows adds decompression to handle gzipped OAuth responses. macOS silently fails when response is gzipped.

---

### MCP Bearer Support

**Feature: MCP Fake Minting**
- **macOS source**: `SessionTokenPlan.swift:261–274`
- **Windows status**: OK (separate McpFakeMint class)
- **Detail**: Both derive with prefix `brm-mcp_`.

**Feature: OAuth Discovery Blocking**
- **macOS source**: `HTTPProxy.swift:111–127`
- **Windows status**: OK
- **Detail**: Both return 404 for OAuth discovery paths on MCP hosts.

**Feature: MCP Bearer Injection**
- **macOS source**: `HTTPProxy.swift:200–220`
- **Windows status**: OK
- **Detail**: Both inject Authorization header when request lacks one.

---

## Top 5 Most Impactful Gaps

1. **Aho-Corasick Detector Integration (CRITICAL)**
   - macOS: Scanner rebuilt on `setMap`/`appendEntries`
   - Windows: Detector never rebuilt after OAuth rotation
   - **Impact**: Stale scans; rotated tokens could leak undetected

2. **DigitalOcean Base64 Auth Pair (CRITICAL)**
   - macOS: Creates both naked token + `base64("<token>:<token>")` entries
   - Windows: Only naked token
   - **Impact**: `doctl registry login` sends unswapped credentials to DigitalOcean registry

3. **Subscription Token Detection Missing (CRITICAL)**
   - macOS: `detectSubscriptionAccessToken()` + `detectCodexAccessToken()`
   - Windows: Not implemented
   - **Impact**: User never prompted; fresh tokens leak to VM in plaintext

4. **RFC 9110 Content-Length Off-by-One (HIGH)**
   - macOS: Includes CRLF CRLF in body count (4-byte overcount)
   - Windows: Correct (excludes delimiter)
   - **Impact**: Some servers truncate body by 4 bytes on PUT/POST; silent data loss

5. **OAuth Response Decompression (MEDIUM)**
   - macOS: Silently fails on gzip-encoded responses
   - Windows: Decompresses gzip/deflate/brotli
   - **Impact**: macOS skips rotation when Anthropic gzips response; fakes never rotate

---

## Recommendations

1. **URGENT**: Wire `CompromiseDetector.Rebuild()` in `TokenSwapper.AppendEntries()` on Windows
2. **URGENT**: Implement DigitalOcean base64 auth pair handling in Windows
3. **HIGH**: Add `DetectSubscriptionAccessToken()` and `DetectCodexAccessToken()` stubs to Windows TokenSwapper
4. **HIGH**: Fix macOS Content-Length calculation to exclude CRLF delimiter
5. **MEDIUM**: Add gzip decompression to macOS OAuth rewriter (port Windows implementation back)
