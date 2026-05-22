# Parity Audit 06 — Trace Store, Secrets Vault, MCP Server, MCP OAuth Broker, Cloud Subsystem, Enrollment

Scope: TraceStore, TraceRecord, TraceBodyRedactor, SecretsVault, MCP stdio server, MCP OAuth broker, CloudEvent / Uploader / mTLS identity / LLMEventExtractor / SessionTracker, Enrollment (install + bearer + leaf cert + CSR + heartbeat).

Severity legend:
- **CRITICAL** — breaks core feature, silent data loss, or security regression
- **HIGH** — visible feature gap that the user/admin will hit
- **MEDIUM** — behavioral drift that may surprise but isn't outright broken
- **LOW** — cosmetic / minor wording / nice-to-have

---

## 1. TraceStore

### 1.1 Storage format: JSONL vs SQLite
- **Feature**: On-disk persistence format
- **macOS source**: `Sources/AgentCoding/Mitm/TraceStore.swift:9-13,185-206`
- **Windows status**: **DIFFERENT** (intentional, but with consequences)
- **Detail**: macOS writes one JSONL file per (day, session) at `traces/YYYY-MM-DD/<sessionID>.jsonl` with the trace record JSON-encoded per line (`.sortedKeys`, ISO-8601 dates, `\n` terminator). Windows uses a single SQLite WAL database `traces/trace.db` with table `traces(id, session_id, profile_id, timestamp_utc, host, port, method, path, status_code, request_bytes, response_bytes, latency_ms, swaps_json, leaks_json, body_stored, is_conversation)` and three indexes (session, ts, host). Impact: the on-disk formats are not interchangeable; a forensic export pipeline that consumes macOS's JSONL won't work on Windows. The schema is otherwise faithful — all fields present. **Severity: MEDIUM** (deliberate architectural divergence, but undocumented for an admin who expects a single common schema).

### 1.2 Body files layout
- **Feature**: Encrypted body file paths
- **macOS source**: `TraceStore.swift:11-12,208-222`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS path: `traces/YYYY-MM-DD/<sessionID>/<recordID>.{req,res}.enc`. Windows path: `traces/bodies/<sessionID>/<recordID>.{req,res}.enc`. Windows drops the per-day directory; eviction is "oldest session" rather than "oldest day". **Severity: MEDIUM**. Affects the per-day cleanup behavior — a session that ran across 30 days would be a single eviction unit on Windows but multiple on macOS.

### 1.3 In-memory ring + reactive feed
- **Feature**: Live `recent: [TraceRecord]` observable for the Trace Inspector
- **macOS source**: `TraceStore.swift:27-29,69-109,113-155`
- **Windows status**: **DIFFERENT / PARTIAL**
- **Detail**: macOS holds a 5000-record `@Observable` array sorted newest-first and pushes on every `record(_:)`, with explicit AppKit-reentrancy avoidance via `DispatchQueue.main.async`. The SwiftUI inspector binds to this and updates live. Windows replaces this with `Recent(limit)` SELECT-on-demand from SQLite; `TraceInspectorViewModel.Refresh()` is called manually and clears+repopulates `Rows` (`Bromure.AC/ViewModels/TraceInspectorViewModel.cs:37`). **Severity: HIGH** — no reactive push to UI. The Windows trace inspector requires a manual refresh / polling to see new records, while macOS streams them live as the proxy emits.

### 1.4 Cold-start reload
- **Feature**: `reload()` to backfill ring from today + yesterday's directories
- **macOS source**: `TraceStore.swift:113-155`
- **Windows status**: **N/A** (subsumed by SQL query)
- **Detail**: macOS's two-day prefix cold-start read is needed because the on-disk format is JSONL with no random access. Windows just runs `SELECT … ORDER BY timestamp_utc DESC LIMIT N`. **Severity: LOW** — equivalent behavior, just achieved differently.

### 1.5 TraceUploader streaming hook
- **Feature**: `public var uploader: TraceUploader?` invoked synchronously per record
- **macOS source**: `TraceStore.swift:31-34,108,332-334`
- **Windows status**: **MISSING**
- **Detail**: macOS defines a `TraceUploader` protocol so the engine can ship every record to `analytics.bromure.io` in real time (currently TBD/no implementation, but the seam exists). Windows has no `ITraceUploader` interface and no per-record streaming sink on `TraceStore`. **Severity: LOW** — neither side implements the upload, but the contract is gone on Windows, so future server-side streaming would require an API addition.

### 1.6 Cap enforcement
- **Feature**: Per-session 100 MB body cap, total 5 GB trace dir cap
- **macOS source**: `TraceStore.swift:48-50,226-301`
- **Windows status**: **OK**
- **Detail**: Both honor the same constants (`PerSessionBodyCap = 100*1024*1024`, `TotalDirCap = 5*1024*1024*1024`, cleanup every 200 appends). Windows uses `LastWriteTimeUtc` for ordering; macOS uses `contentModificationDate`. Equivalent. macOS evicts oldest *day directories* once total exceeds cap; Windows evicts oldest *session directories*. Behavioral drift — see 1.2.

### 1.7 Background queue
- **Feature**: Off-main-thread disk writes
- **macOS source**: `TraceStore.swift:36-50,89-105`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS uses a dedicated serial `DispatchQueue` (`io.bromure.ac.trace-store`, `qos: .utility`) so the proxy hot path never blocks on disk. Windows performs SQL inserts + body file writes **synchronously** inside `lock (_lock)` on the caller's thread. **Severity: HIGH** — when SQLite is rotating WAL pages under load (Claude Code burst → 50 events/sec), this serializes the proxy's connection-handling thread on `_lock` and the SQLite mutex. macOS deliberately avoided this.

### 1.8 TraceBodyRedactor
- **Feature**: Pre-storage header redaction + Content-Type whitelist
- **macOS source**: `Sources/AgentCoding/Mitm/HTTPProxy.swift:667-668,808-811,828+,872+` (static helpers `redactSensitiveHeaders` / `bodyForTrace`)
- **Windows status**: **OK** (lifted into a separate static class)
- **Detail**: Windows extracted these into `Bromure.AC.Mitm/Trace/TraceBodyRedactor.cs` with identical 5 MB per-record cap, identical sensitive-header set (`authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-amz-security-token`, `x-goog-iap-jwt-assertion`, `api-key`, `*-api-key`), and identical Content-Type whitelist (text/*, application/json, application/xml, application/javascript, x-www-form-urlencoded, x-ndjson, ld+json, graphql, yaml, problem+json, multipart/form-data, +json/+xml suffix, text/event-stream). Faithful port.

### 1.9 TraceRecord schema
- **Feature**: Record fields + JSON shape
- **macOS source**: `Mitm/TraceRecord.swift:66-149`
- **Windows status**: **OK**
- **Detail**: Both carry `id, sessionID, profileID, timestamp, host, port, method, path, statusCode, requestBytes, responseBytes, latencyMs, swaps[], leaks[], bodyStored, isConversation`. SwapEntry / LeakEntry are byte-for-byte. `isConversation` defaults to false (Windows: optional positional with default; macOS: `decodeIfPresent ?? false`).

### 1.10 TraceLevel enum + AI host list
- **Feature**: Off / Activity / AiDetails / All + 11-host AI substring set
- **macOS source**: `Mitm/TraceRecord.swift:7-61`
- **Windows status**: **OK**
- **Detail**: Identical set: `anthropic.com, openai.com, googleapis.com, google.com, cohere.com, mistral.ai, perplexity.ai, x.ai, groq.com, replicate.com, huggingface.co`. `CapturesBodyForHost` does the same substring match with `lower.Contains(host)`.

### 1.11 `displayName` localization
- **Feature**: Localized strings for trace level
- **macOS source**: `Mitm/TraceRecord.swift:21-28`
- **Windows status**: **MISSING**
- **Detail**: macOS exposes `NSLocalizedString`-wrapped names; Windows enum has no display extension. **Severity: LOW** — UI presumably hard-codes them somewhere.

---

## 2. SecretsVault

### 2.1 Master-key storage backend
- **Feature**: 32-byte random AES-256 key persisted per install
- **macOS source**: `Sources/AgentCoding/Mitm/SecretsVault.swift:4-15,62-106`
- **Windows status**: **DIFFERENT** (intentional)
- **Detail**: macOS uses Data Protection Keychain (`kSecUseDataProtectionKeychain=true`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service `io.bromure.agentic-coding.master-key`, account `v1`). Windows persists a DPAPI-wrapped blob via `ISecretStore.StoreBlob("vault-master-key-v1", BlobScope.LocalMachine)` → `WindowsSecretStore` → `ProtectedData.Protect(...DataProtectionScope.LocalMachine)` written under `MachineDataRoot\secrets\vault-master-key-v1.bin`. Entropy const: `"bromure-ac-v1"`. **Severity: OK** — analogous threat model. Worth noting: macOS uses *device-unlock* gating; Windows DPAPI-LocalMachine is bound to the machine only (per BitLocker comment in `ISecretStore.cs:7-10`).

### 2.2 AES-GCM wire layout
- **Feature**: 12-byte nonce || ciphertext || 16-byte tag
- **macOS source**: `SecretsVault.swift:43-58`
- **Windows status**: **OK**
- **Detail**: Both use AES-GCM with 12-byte nonce, no AAD, 16-byte tag, "combined" concatenation. macOS uses CryptoKit's `AES.GCM.seal(...).combined`; Windows uses `AesGcm` and manually concatenates `nonce + ciphertext + tag`. The layouts are byte-compatible (would be inter-decryptable if the master keys were shared).

### 2.3 Key rotation
- **Feature**: Wipe blob → next call mints a fresh key
- **macOS source**: `SecretsVault.swift:14-15,29-41`
- **Windows status**: **OK**
- **Detail**: Both no-prompt, both lazy-create. Both have an in-memory cache (`cachedKey` + `cacheLock` / `_cachedKey` + `_gate`). Windows exposes `ClearCache()` for tests; macOS has no equivalent (cache persists for the process lifetime).

### 2.4 Cache reset hook
- **Feature**: `ClearCache()` / no-op vs `purge()` semantics
- **macOS source**: N/A (cache lives until process exits)
- **Windows status**: **EXTRA**
- **Detail**: Windows has `ClearCache()` for testability. Not a parity gap — Windows-only addition.

### 2.5 IBodyEncryptor interface
- **Feature**: Plug-in interface for sealing trace bodies
- **macOS source**: trace store calls `SecretsVault.encrypt`/`decrypt` directly
- **Windows status**: **DIFFERENT (extra abstraction)**
- **Detail**: Windows introduces `IBodyEncryptor` so `TraceStore` doesn't depend on `SecretsVault` directly. macOS hard-references `SecretsVault.encrypt`/`decrypt` from `TraceStore`. Minor architectural drift; Windows is cleaner. **Severity: LOW**.

### 2.6 TraceStore actually wires the vault
- **Feature**: Engine plumbing the `IBodyEncryptor` into TraceStore.Record
- **macOS source**: `TraceStore.swift:217-219` (`SecretsVault.encrypt` called inline)
- **Windows status**: **PARTIAL — likely broken**
- **Detail**: `MitmEngine.cs:54,57,109-110` constructs both `TraceStore` and `Vault` but does NOT pass `Vault` (which implements `IBodyEncryptor`) to `TraceStore`. The proxy's call to `TraceStore.Record(...)` (via `HttpMitmProxy`) would need to thread the encryptor through. **Verify**: Grep `TraceStore.Record` callers in `HttpMitmProxy.cs` — if no `encryptor` is passed, **trace body files are stored unencrypted on disk**, which is a security regression versus macOS where bodies are AES-GCM at rest. **Severity: CRITICAL** if the call site doesn't pass it; **HIGH** at minimum (gap in observability — `LoadBody` will return plaintext but think it's still encrypted).

### 2.7 POSIX 0600 mode bit on body files
- **Feature**: chmod 600 the encrypted body file at write time
- **macOS source**: `TraceStore.swift:219-221`
- **Windows status**: **MISSING** (not directly applicable but no NTFS ACL equivalent)
- **Detail**: macOS sets `.posixPermissions: 0o600` on each `.enc` body file. Windows inherits whatever ACL `bodies/` has (likely user-default). For a single-user Windows install this is fine; for the LocalMachine kiosk scenario the BitLocker boundary is still effective. **Severity: LOW**.

---

## 3. MCP Server (stdio JSON-RPC)

### 3.1 Wire protocol + initialize
- **Feature**: `initialize`, `notifications/initialized`, `notifications/cancelled`, `ping`, `tools/list`, `tools/call`, `-32601 Method not found`
- **macOS source**: `Sources/AgentCoding/MCPServer.swift:60-81`
- **Windows status**: **OK**
- **Detail**: Both implement the identical handshake. `protocolVersion: "2025-03-26"`, `serverInfo: { name: "bromure-ac", version: "1.0.0" }`, capabilities `tools.listChanged=false`. Wire format: line-delimited JSON on stdin/stdout. JSON-RPC error code `-32601`. Both flush after every response.

### 3.2 Tool catalog
- **Feature**: Tool name + description + input schema definitions
- **macOS source**: `MCPServer.swift:105-176`
- **Windows status**: **PARTIAL**
- **Detail**: Both expose the 8 core tools: `bromure_ac_list_profiles`, `bromure_ac_list_sessions`, `bromure_ac_open_session`, `bromure_ac_close_session`, `bromure_ac_get_profile`, `bromure_ac_set_profile`, `bromure_ac_get_profile_setting`, `bromure_ac_set_profile_setting`. Tool descriptions and required-arg lists match. However:
  - macOS's `bromure_ac_get_profile_setting` description lists supported keys: `name, color, comments, tool, authMode, apiKey, closeAction, memoryGB, folderPathsCount, mcpServerCount, keyboardLayoutOverride, keyRepeatDelayMs, keyRepeatRateHz`. Windows's lists: `name, color, tool, authMode, apiKey, folderPathsCount, mcpServerCount, privateMode, traceLevel`. The supported-keys set drifts substantially (no `comments`, `closeAction`, `memoryGB`, `keyboardLayoutOverride`, `keyRepeatDelayMs`, `keyRepeatRateHz`; adds `privateMode`, `traceLevel`). **Severity: HIGH** — admins / agents reading the tool docs will not know which keys they can read/set. Behavior of the API server endpoints (`/profiles/{id}/settings/{key}`) needs separate verification.

### 3.3 Debug-only tools
- **Feature**: `--debug` exposes 4 extra tools
- **macOS source**: `MCPServer.swift:136-158`
- **Windows status**: **PARTIAL**
- **Detail**: macOS exposes 4 debug tools: `bromure_ac_app_state`, `bromure_ac_vm_exec`, `bromure_ac_vm_read_file`, `bromure_ac_vm_write_file`. Windows exposes only `bromure_ac_app_state`, with a comment that `vm_exec/read_file/write_file` ship "once the guest shell-agent bridge lands on Windows (mirrors macOS Phase 2b)" (`Program.cs:156-157`). **Severity: MEDIUM** — debug-only feature, but the guest VM exec/read/write tools are absent on Windows.

### 3.4 Tool dispatch / transport to AC app
- **Feature**: How the MCP server talks to the running AC app
- **macOS source**: `MCPServer.swift:187-275,308-381`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS hand-rolls a raw socket → `127.0.0.1:9223` HTTP/1.1 client (`Darwin.socket + connect + write + read`); the get-profile / set-profile paths additionally shell out to `osascript -e 'tell application "Bromure Agentic Coding" to ...'` for AppleScript-only commands. Windows uses `HttpClient` against `http://127.0.0.1:9223` (clean) and for `get_profile`/`set_profile` calls a `GET /profiles/{id}/json` / `PUT /profiles/{id}/json` HTTP endpoint instead of AppleScript. The Windows API surface is broader (`/profiles/{id}/json`, `/profiles/{id}/settings/{key}` endpoints), while macOS uses HTTP for sessions and AppleScript for profile mutations. **Severity: MEDIUM** — both functional, but require the host API server to expose the right routes. Worth confirming `/profiles/{id}/json` and `/profiles/{id}/settings/{key}` are actually implemented on the Windows AutomationServer.

### 3.5 Close-session profile resolution
- **Feature**: Resolve name → UUID for `DELETE /sessions/{id}`
- **macOS source**: `MCPServer.swift:200-213`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS fetches the profile list and resolves locally before issuing `DELETE /sessions/{uuid}`. Windows just URL-encodes the input and lets the server resolve (`Program.cs:215-218`). Functionally OK if the server endpoint accepts both forms — see comment "The DELETE /sessions/{id} endpoint accepts either a UUID or a profile name (the server-side handler resolves)".

### 3.6 Error envelope
- **Feature**: `errorResult` returning `{content:[{type:text, text:"Error: ..."}], isError:true}`
- **macOS source**: `MCPServer.swift:283-285`
- **Windows status**: **OK**
- **Detail**: Identical envelope shape on both sides. Note: macOS protocol error uses JSON-RPC error code -32601; Windows uses -32000 for generic exceptions thrown during dispatch (`Program.cs:101`). Minor drift — macOS funnels all exceptions through `errorResult` rather than JSON-RPC error frames.

### 3.7 Project: separate executable
- **Feature**: `bromure-ac mcp` subcommand
- **macOS source**: `MCPServer.swift:6-29`
- **Windows status**: **DIFFERENT** (separate exe `bromure-ac-mcp.exe`)
- **Detail**: macOS embeds it as a `bromure-ac mcp` subcommand on the main CLI. Windows ships a separate executable `bromure-ac-mcp.exe` (`Bromure.AC.Mcp` project). Both accept `--debug --api-url <url>`. **Severity: LOW**.

### 3.8 No prompts / resources advertised
- **Feature**: capabilities omits `prompts` and `resources`
- **macOS source**: `MCPServer.swift:62-66`
- **Windows status**: **OK**
- **Detail**: Both advertise only `tools.listChanged=false`. No prompts, no resources. Faithful.

---

## 4. MCP OAuth Broker

### 4.1 Discovery (RFC 8414)
- **Feature**: `GET <server>/.well-known/oauth-authorization-server`
- **macOS source**: `Sources/AgentCoding/MCPOAuthBroker.swift:222-251`
- **Windows status**: **OK**
- **Detail**: Both fetch the discovery document, require `authorization_endpoint` + `token_endpoint`, optionally pick up `registration_endpoint`. Both `URIComponents`-based path replacement. Both default to HTTPS via the user-supplied server URL.

### 4.2 Dynamic Client Registration (RFC 7591)
- **Feature**: POST to `registration_endpoint` with `client_name`, `redirect_uris`, `grant_types`, `response_types`, `token_endpoint_auth_method=none`
- **macOS source**: `MCPOAuthBroker.swift:255-287`
- **Windows status**: **OK**
- **Detail**: Identical payload: `client_name="Bromure AC"`, single-element `redirect_uris`, `["authorization_code"]`, `["code"]`, `"none"`. Both accept 200 or 201 status. Both require `client_id` in response; `client_secret` optional.

### 4.3 PKCE
- **Feature**: 32-byte verifier, S256 challenge, base64url with no padding
- **macOS source**: `MCPOAuthBroker.swift:367-382`
- **Windows status**: **OK**
- **Detail**: Both generate a 32-byte random verifier (macOS: `SecRandomCopyBytes`; Windows: `RandomNumberGenerator.GetBytes`). Both base64url with `+/=` → `-_` strip. Both SHA-256 the verifier for the challenge. Compatible.

### 4.4 Callback listener
- **Feature**: Localhost HTTP listener on port 28500–28599
- **macOS source**: `MCPOAuthBroker.swift:137-219`
- **Windows status**: **OK**
- **Detail**: Both bind in the same port range, both prefer the previously-saved port when refreshing existing state, both fall back to scanning the range. macOS uses raw POSIX sockets (`socket/bind/listen/accept/recv/send`); Windows uses `TcpListener`. Both verify the `state` query param, both write a 400 on mismatch and 200 with HTML body on success.

### 4.5 State / nonce verification
- **Feature**: Random `state` query param check
- **macOS source**: `MCPOAuthBroker.swift:298-300,201-211`
- **Windows status**: **OK** but with a subtle difference
- **Detail**: macOS uses `UUID().uuidString` (36 chars, hyphenated). Windows uses `Guid.NewGuid().ToString("N")` (32 chars, no hyphens). Both random per-flow. No CSRF risk on either side, but the state strings have different shapes. **Severity: LOW**.

### 4.6 Authorization URL construction
- **Feature**: How extra query params are appended when the authorization endpoint already has a query string
- **macOS source**: `MCPOAuthBroker.swift:301-313` — uses `URLComponents.queryItems` (replaces existing query)
- **Windows status**: **DIFFERENT**
- **Detail**: Windows uses `metadata.AuthorizationEndpoint.AbsoluteUri + (existing.Query.Length > 0 ? "&" : "?") + qs` — i.e. appends to an existing query rather than replacing. macOS replaces (`queryItems = [...]`). If a server's discovery returns `authorization_endpoint` with embedded params, Windows preserves them but macOS drops them. **Severity: LOW** unless a real-world MCP server's discovery returns embedded params (rare).

### 4.7 Refresh flow
- **Feature**: `refresh_token` grant
- **macOS source**: `MCPOAuthBroker.swift:99-133`
- **Windows status**: **OK**
- **Detail**: Both POST `grant_type=refresh_token&refresh_token=...&client_id=...&client_secret=...`. Both update `access_token`, conditionally update `refresh_token`, and recompute `expires_at` from `expires_in`. Both throw on non-200. Faithful.

### 4.8 Browser launch
- **Feature**: Open the system browser to the auth URL
- **macOS source**: `MCPOAuthBroker.swift:314` — `NSWorkspace.shared.open(authURL)`
- **Windows status**: **OK**
- **Detail**: Windows uses `Process.Start(new ProcessStartInfo { FileName = authUrl, UseShellExecute = true })`. Comment correctly notes equivalence.

### 4.9 Token exchange
- **Feature**: POST `grant_type=authorization_code` with `code_verifier`
- **macOS source**: `MCPOAuthBroker.swift:321-363`
- **Windows status**: **OK**
- **Detail**: Identical body: `grant_type, code, redirect_uri, client_id, code_verifier, [client_secret]`. Both require `access_token` in response; both surface `refresh_token`, `expires_in` optionally.

### 4.10 McpOAuthState persistence
- **Feature**: Persisted OAuth state across sessions
- **macOS source**: `Profile.swift` `MCPOAuthState`
- **Windows status**: **OK**
- **Detail**: `Bromure.AC.Core/Model/McpServer.cs:91-103` has all fields: ClientId, ClientSecret, AuthorizationEndpoint, TokenEndpoint, RegistrationEndpoint, AccessToken, RefreshToken, ExpiresAt, AuthorizedAt, CallbackPort.

---

## 5. Cloud Subsystem

### 5.1 CloudEvent wire shape
- **Feature**: `{sessionId, profileId, ts, eventType, eventData}` JSON object
- **macOS source**: `Sources/AgentCoding/CloudEvents.swift:18-33`
- **Windows status**: **OK**
- **Detail**: Both wire-encode the same fields. macOS uses a typed `[String: AnyJSON]` map; Windows uses `JsonObject` from `System.Text.Json.Nodes`. macOS encodes dates as ISO-8601 (uploader's `JSONEncoder.dateEncodingStrategy = .iso8601`). Windows relies on `JsonSerializer.Serialize` defaults for `DateTimeOffset` — System.Text.Json emits ISO-8601 by default with offset. Compatible.

### 5.2 AnyJSON encoding
- **Feature**: Polymorphic JSON value type
- **macOS source**: `CloudEvents.swift:39-79`
- **Windows status**: **PARTIAL**
- **Detail**: macOS has a full `AnyJSON` enum with string/int/double/bool/array/object/null cases + `of(_:)` helpers. Windows just uses `JsonObject` everywhere with a `DataFrom(IEnumerable<KVP>)` builder that falls back to `JsonSerializer.Serialize(v)` for unsupported types (`CloudEvent.cs:19-36`). Functional difference: macOS preserves typed roundtripping; Windows stringifies anything not in `{string,int,long,double,bool}`. **Severity: LOW** — emitted shapes look the same on the wire because emitters only insert known scalars.

### 5.3 Session tracking + 20-minute idle rollover
- **Feature**: Activity-based session ID with 20-min idle timeout
- **macOS source**: `CloudEvents.swift:86-139`
- **Windows status**: **OK**
- **Detail**: Both define `IdleTimeout = 20 min`. Both return `Bump(SessionId, PriorSessionId, Rolled)`. Both maintain per-profile (sessionId, lastActivity) maps under a lock. Both `Close(profileID)` returns the prior session ID. Identical semantics.

### 5.4 Enrollment gate
- **Feature**: Drop events when not enrolled
- **macOS source**: `CloudEvents.swift:183-190`
- **Windows status**: **OK**
- **Detail**: macOS checks `BACEnrollmentStore.load() != nil && BACEnrollmentStore.loadInstallToken() != nil`. Windows injects a `Func<bool> _enrolledProbe` (`EnrollmentStore.IsEnrolled` from `ShellViewModel.cs:103`). Equivalent.

### 5.5 Private-profile gate
- **Feature**: Drop events for profiles flagged private
- **macOS source**: `CloudEvents.swift:155-160,192-200`
- **Windows status**: **OK**
- **Detail**: Both maintain `privateProfiles` set, both drop with the same debug log line. `SetPrivateProfiles` API present on both.

### 5.6 session.start / session.end events with backdated end
- **Feature**: On rollover, emit `session.end` for prior with backdated ts
- **macOS source**: `CloudEvents.swift:208-227`
- **Windows status**: **OK**
- **Detail**: macOS subtracts `idleTimeoutSec` from now for the backdate; Windows subtracts `SessionTracker.IdleTimeout`. `reason="idle_timeout"`. `CloseSession(profileId, reason)` emits the final session.end. Both correct.

### 5.7 Sync emit + flush APIs
- **Feature**: `emitDetached`, `flush`, `closeSession`, `reset`, `setPrivateProfiles`, `ensureUploader`
- **macOS source**: `CloudEvents.swift:162-273`
- **Windows status**: **PARTIAL**
- **Detail**: Windows has `EmitAsync`, `Reset`, `FlushAsync`, `SetUploader`, `SetPrivateProfiles`, `CloseSession`. **MISSING from Windows**: `EmitDetached` (the sync-callable wrapper that spawns a Task). macOS uses this from AppKit menu / window-close handlers. Windows's window-close path would need to `Task.Run`/`fire-and-forget` manually. **Severity: LOW** — call sites can do it themselves, but the helper isn't there.

### 5.8 Uploader: batch / interval / cap parameters
- **Feature**: maxBatch=500, flushHighWatermark=200, flushIntervalSec=5
- **macOS source**: `CloudUploader.swift:20-30`
- **Windows status**: **OK**
- **Detail**: Both use 500/200/5s. Both cap `pending` at `4 * MaxBatch = 2000`; on overflow, drop oldest half.

### 5.9 Endpoint URL
- **Feature**: Default ingest URL + env override
- **macOS source**: `Enrollment.swift:234-240`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS default: `https://analytics.bromure.io/ac-ingest` (env: `BROMURE_AC_INGEST_URL`; also reads `UserDefaults["managed.acIngestURL"]`). Windows default: `https://analytics.bromure.io/ac-ingest` (env: `BROMURE_AC_INGEST_URL`, `EnrollmentStore.DefaultIngestUrl()`). Windows **does NOT honor a UserDefaults / Settings registry override** equivalent to macOS's `managed.acIngestURL`. **Severity: LOW** — env var works for dev; admin-override UI is missing on both sides.

Additionally `EnrollmentClient.DefaultAnalyticsUrl = "https://analytics.bromure.io/v1/ac-events"` (`EnrollmentClient.cs:16`) is **inconsistent** with `DefaultIngestUrl()` which uses `/ac-ingest`. Two different endpoints in Windows code suggesting confusion. macOS only references `/ac-ingest`. **Severity: MEDIUM** — confusion in endpoint constants; verify which one is actually authoritative. The uploader uses `EnrollmentStore.DefaultIngestUrl()` so `/ac-ingest` wins, but the `DefaultAnalyticsUrl` constant is dead/misleading code.

### 5.10 mTLS handshake
- **Feature**: Client cert presented on connect
- **macOS source**: `CloudUploader.swift:184-208` (NSURLSession delegate)
- **Windows status**: **OK**
- **Detail**: macOS hooks `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` and answers `NSURLAuthenticationMethodClientCertificate`. Windows configures `SocketsHttpHandler.SslOptions.LocalCertificateSelectionCallback` to return `mtls.SelectCertificate()`. Both let the system verify server trust. Connection reuse: both retain the session/HttpClient for the process lifetime, so TLS sessions warm-cache across batches.

### 5.11 Body encoding + Content-Type
- **Feature**: `{"events":[...]}` JSON body, `application/json`
- **macOS source**: `CloudUploader.swift:161-180`
- **Windows status**: **OK**
- **Detail**: Both POST. Both use Content-Type `application/json`. **Neither side gzips** — even though the audit request mentions gzip, it is not implemented on either side. macOS uses `JSONEncoder.dateEncodingStrategy = .iso8601`; Windows uses default System.Text.Json. Both omit a bearer token (mTLS is the auth).

### 5.12 Retry / backoff
- **Feature**: Retry strategy on failure
- **macOS source**: `CloudUploader.swift:149-159`
- **Windows status**: **OK**
- **Detail**: Neither side does retry/backoff. Both leave `pending` intact on failure; the next `flushNow` (5 s later) tries the same batch. Both log the failure. macOS additionally checks `BACEnrollmentStore.load() != nil` before each flush and drops the batch on lost enrollment; **Windows does NOT** (`CloudUploader.cs` has no such check — it only consults the cancellation gate). **Severity: LOW** — Windows would keep retrying on a lost enrollment until DPAPI fails the cert load.

### 5.13 Shutdown
- **Feature**: Graceful shutdown that finishes in-flight + drops buffer
- **macOS source**: `CloudUploader.swift:85-91`
- **Windows status**: **OK**
- **Detail**: macOS `shutdown()` sets `stopped=true`, cancels the flush task, calls `session.finishTasksAndInvalidate()`. Windows `DisposeAsync` cancels CTS, awaits the flush loop, disposes HttpClient. Equivalent.

### 5.14 CloudMtlsIdentity construction
- **Feature**: How the leaf cert + private key become a TLS client identity
- **macOS source**: `Sources/AgentCoding/CloudMTLSIdentity.swift:63-107`
- **Windows status**: **DIFFERENT / PARTIAL**
- **Detail**: macOS reads PEM cert + serial + PKCS#1 RSA private key from disk, converts the key to PKCS#8, packages into in-memory PKCS#12 with a random password, calls `SecPKCS12Import` **without** `kSecImportExportKeychain` → keeps the `SecIdentity` purely in memory (no Keychain Access entry). Windows has two parallel implementations:
  1. `Bromure.Cloud/CloudMtlsIdentity.cs:FileBackedCloudMtlsIdentity` (loads from `ISecretStore` blobs `ac-mtls-leaf-cert-pem` / `ac-mtls-leaf-key-pem`)
  2. `Bromure.AC/Cloud/EnrollmentCloudMtlsIdentity.cs` (loads from `EnrollmentStore`'s on-disk PEM + DPAPI-wrapped private key blob)
  
  Only #2 is wired up in `ShellViewModel.cs:102`. The Windows implementation reads PEM cert + DER PKCS#8 key, attaches via `cert.CopyWithPrivateKey(rsa)`, round-trips through PFX with `EphemeralKeySet` (#1) or `UserKeySet|Exportable` (#2). The `UserKeySet|Exportable` path **persists the private key on disk in the user's CAPI key store** despite the comment ("UserKeySet is the safe pick"). **Severity: HIGH** — macOS leaves zero persistent traces; Windows leaks a key into `%APPDATA%\Microsoft\Crypto\RSA\<sid>`. The comment claims `EphemeralKeySet` fails on some Schannel revisions, but `EphemeralKeySet` is the in-memory equivalent used by `FileBackedCloudMtlsIdentity` (which isn't wired up). Need to verify the `UserKeySet` Schannel claim is current.

### 5.15 mTLS identity cache + rotation
- **Feature**: Cache the identity, purge on leaf rotation / unenroll
- **macOS source**: `CloudMTLSIdentity.swift:40-61` + `Enrollment.swift:340-348`
- **Windows status**: **PARTIAL**
- **Detail**: macOS caches and exposes `purge()`, called from `fetchLeafCert` and `unenroll`. Windows `EnrollmentCloudMtlsIdentity` caches by serial and auto-rebuilds when the serial changes (`EnrollmentCloudMtlsIdentity.cs:53-60`), which is **better** than macOS in principle — but macOS's explicit `purge()` is also called at unenroll. Windows does NOT call `Purge()` on unenroll (no enrollment.UnenrollAsync exists — see §6.1 below). **Severity: LOW** until unenroll is wired up.

### 5.16 Multiple identity classes / unclear ownership
- **Feature**: A single canonical mTLS identity path
- **macOS source**: One class — `BACMTLSIdentity`
- **Windows status**: **DIFFERENT**
- **Detail**: Windows has both `FileBackedCloudMtlsIdentity` (`Bromure.Cloud`) and `EnrollmentCloudMtlsIdentity` (`Bromure.AC.Cloud`) doing similar but not identical things. `FileBackedCloudMtlsIdentity` is dead code (no callers in shell/ViewModels grep). **Severity: LOW** — confusion / dead-code risk.

### 5.17 LLMEventExtractor: tool classification
- **Feature**: `isFileReadTool / isFileWriteTool / isCommandTool` switch lists
- **macOS source**: `LLMEventExtractor.swift:150-178`
- **Windows status**: **OK**
- **Detail**: Identical name sets on both sides for all three categories.

### 5.18 LLMEventExtractor: path extraction
- **Feature**: Extract file path from tool input JSON
- **macOS source**: `LLMEventExtractor.swift:187-198`
- **Windows status**: **OK**
- **Detail**: Both probe `file_path, path, filename, target_file` in order. Both return null on parse failure.

### 5.19 LLMEventExtractor: command extraction (bash -lc shape)
- **Feature**: Detect Codex's `["bash","-lc","<cmd>"]` array shape and pull element [2]
- **macOS source**: `LLMEventExtractor.swift:200-222`
- **Windows status**: **OK**
- **Detail**: Both detect 3-element arrays starting with `bash, /bin/bash, sh, /bin/sh, zsh` and second element starting with `-`, then return the third element summarized to 500 chars. Both fall back to space-joining the array otherwise.

### 5.20 LLMEventExtractor: emit orchestration
- **Feature**: Walk parsed `Conversation`, emit llm.request + tool.use + specialized events
- **macOS source**: `LLMEventExtractor.swift:28-145`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS has a `static func emit(profileID, host, path, statusCode, latencyMs, responseBody, conversation)` that calls `BACEventEmitter.shared.emitDetached(...)` 1–N times. Windows splits this into:
  - Pure helpers in `LlmEventExtractor` (classification + token parsing)
  - The orchestration loop in `ConversationEventEmitter.Emit(profileId, ..., conversation, emit: Action<...>)` which takes the emit callback as a parameter
  
  Both walk only the **last assistant message** (correctly, to avoid double-counting echoed history). Both emit a generic `tool.use` first, then a specialised `file.read` / `file.write` / `command.run` when classifiable. Faithful in semantics, cleaner in code. **Severity: OK**.

### 5.21 input_summary cap
- **Feature**: 240-char cap on `tool.use.input_summary`
- **macOS source**: `LLMEventExtractor.swift:91-97`
- **Windows status**: **OK**
- **Detail**: Both truncate at 240 chars with `…`.

### 5.22 command length cap
- **Feature**: 500-char cap on `command.run.command`
- **macOS source**: `LLMEventExtractor.swift:203,217`
- **Windows status**: **OK**
- **Detail**: Both 500 chars + `…`.

### 5.23 Token counter parsing — Anthropic
- **Feature**: Parse `usage.{input,output,cache_creation_input,cache_read_input}` from non-stream JSON, fall back to SSE message_start + message_delta walk
- **macOS source**: `LLMEventExtractor.swift:262-298`
- **Windows status**: **OK**
- **Detail**: Both probe top-level `usage` first. SSE: walk lines beginning `data:`, parse JSON, pick highest `output_tokens` from `message_delta` events; pull cache counters from `message_start.message.usage`. Faithful.

### 5.24 Token counter parsing — OpenAI
- **Feature**: Parse `prompt_tokens / completion_tokens / prompt_tokens_details.cached_tokens`
- **macOS source**: `LLMEventExtractor.swift:300-314`
- **Windows status**: **OK**
- **Detail**: Both extract the three counters. Windows doesn't do an SSE fallback for OpenAI; neither does macOS. Consistent.

### 5.25 Multimodal / image content
- **Feature**: Image blocks in messages
- **macOS source**: Uses `Conversation` from `ConversationParser`
- **Windows status**: **OK**
- **Detail**: Both treat images as opaque blocks. Neither extractor emits anything for image content. `Conversation.Image` exists in both. Faithful.

### 5.26 System prompt / tool description handling
- **Feature**: System prompt or tool description capture
- **macOS source**: Not emitted to cloud (privacy posture: "what did the AI do", not "what did the user ask")
- **Windows status**: **OK**
- **Detail**: Both deliberately omit system prompts / user content. Conversation has `SystemPrompt` but neither extractor emits it.

### 5.27 Provider list (Google, Cohere)
- **Feature**: Token-counter parsing for Google / Cohere
- **macOS source**: `LLMEventExtractor.swift:255-260` (returns empty `TokenCounters`)
- **Windows status**: **OK**
- **Detail**: Both fall back to empty token counters for non-Anthropic-non-OpenAI providers.

### 5.28 Credential.token_swap / .ssh_sign / .aws_sign events
- **Feature**: Credential-use events emitted from MITM hooks
- **macOS source**: Emitted by the swap engine + ssh-agent + aws-resigner (separate code paths)
- **Windows status**: **PARTIAL / VERIFY**
- **Detail**: `MitmEngine.cs:88-91` declares `Action<Guid, string, JsonObject>? OnCloudEvent`, and `ShellViewModel` wires it (`ShellViewModel.cs:108-111`). But the audit doesn't include the proxy hot path — verify token swap actually emits `credential.token_swap` events via this hook. Quick grep showed `OnCloudEvent` is consumed in `MitmEngine` and `ShellViewModel` only. **Severity: MEDIUM** — needs verification in HttpMitmProxy.cs that the credential events are actually produced.

---

## 6. Enrollment

### 6.1 Enrollment API endpoint
- **Feature**: POST URL for redeeming a code
- **macOS source**: `ManagedProfileClient.swift:34-58` → `v1/enroll` at the server URL
- **Windows status**: **DIFFERENT**
- **Detail**: macOS POSTs `<serverURL>/v1/enroll` where `serverURL` is the workspace-supplied origin (default `https://bromure.io/api`). Windows POSTs `<serverURL>/api/agentic-coding/enroll` (`EnrollmentClient.cs:32`) at default `https://app.bromure.io`. **Severity: CRITICAL** — different URL paths and different default hosts. Either the server endpoint is exposed under both paths or one of the clients will 404 against the real server.

### 6.2 Enroll request body
- **Feature**: `{code, installPubkey, deviceName, app}`
- **macOS source**: `ManagedProfileClient.swift:42-54`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS sends `code, installPubkey (Curve25519 X25519 hex), deviceName, app="agentic-coding"`. Windows sends `code, deviceName, app="agentic-coding"` — **no `installPubkey`**. macOS's comment (`Enrollment.swift:259-264`) explicitly notes the server requires `installPubkey` even though AC doesn't yet use it for sealed-box delivery. **Severity: HIGH/CRITICAL** — if the server validates `installPubkey` presence the Windows enroll request will be rejected.

### 6.3 EnrollResponse shape
- **Feature**: `{installId, installToken, orgSlug, userId, userEmail, app}`
- **macOS source**: `ManagedProfileClient.swift:13-23`
- **Windows status**: **DIFFERENT**
- **Detail**: macOS expects `installId, installToken, orgSlug, userId, userEmail, app?`. Windows expects all of those plus `leafCertPem?, caCertPem?, leafSerial?` (`EnrollmentClient.cs:88-97`) — apparently planning to receive the leaf cert in the enroll response. **macOS issues the leaf cert via a SEPARATE `signCSR` call.** Windows's flow has no CSR generation at all. **Severity: CRITICAL** — see §6.5 below.

### 6.4 App scope check
- **Feature**: Reject codes not minted for `agentic-coding`
- **macOS source**: `Enrollment.swift:273-275`
- **Windows status**: **OK**
- **Detail**: Both verify `app == "agentic-coding"`. Both throw with a specific exception.

### 6.5 CSR + leaf cert issuance
- **Feature**: Generate RSA-2048 keypair, build CSR, POST to `/v1/installs/:installId/csr`, persist returned cert + CA + serial
- **macOS source**: `Enrollment.swift:312-350` + `ManagedProfileClient.swift:186-201`
- **Windows status**: **MISSING — CRITICAL**
- **Detail**: macOS generates a 2048-bit RSA key (`_RSA.Signing.PrivateKey(keySize: .bits2048)`), builds an X.509 CSR with `CN="bromure-install-<installId>"` using `swift-certificates`, serializes to PEM, POSTs to `/v1/installs/<id>/csr` with bearer token, gets back `(certPem, caCertPem, serialHex, notAfter)`, persists via `BACEnrollmentStore.storeLeafCert`. This is best-effort during enroll, retried on heartbeat. Windows has **no** equivalent — no CSR generation, no CSR endpoint client, no leaf-cert fetch outside the (probably-not-server-implemented) inline `EnrollResponse.LeafCertPem`. **Severity: CRITICAL** — mTLS will fail because there's no leaf cert. The cloud uploader will fail every batch with a TLS handshake error. The Windows `EnrollmentSheetViewModel.SubmitAsync` doesn't even call `storeLeafCert`; the result of `EnrollAsync` is just `_store.Save(install)` (`EnrollmentSheetViewModel.cs:51-52`).

### 6.6 Heartbeat
- **Feature**: Periodic POST to `/v1/installs/:installId/heartbeat` with bearer
- **macOS source**: `Enrollment.swift:354-364` + `ManagedProfileClient.swift:150-160` + `BACHeartbeat:367-398`
- **Windows status**: **MISSING — HIGH**
- **Detail**: macOS pings the server every 10 minutes (with an immediate first ping on startup) to keep `last_seen_at` fresh in the admin UI. Phase 3b notes leaf-rotation will piggyback. Windows has no `Heartbeat` class, no heartbeat client method, and no scheduled task. **Severity: HIGH** — admins will see stale "last seen" rows on the workspace dashboard for all Windows installs.

### 6.7 Unenroll
- **Feature**: `BACEnrollment.unenroll()` wipes state + purges cached identity + fires UI state-change
- **macOS source**: `Enrollment.swift:302-308`
- **Windows status**: **PARTIAL**
- **Detail**: Windows has `EnrollmentStore.Destroy()` (wipes files + bearer + leaf key blob) but **no orchestrator** that also calls `_cloudIdentity.Purge()`, tears down the running `CloudUploader`, or notifies the UI. macOS has `BACEnrollment.shared.unenroll()` doing all three. **Severity: HIGH** — when the user signs out, the in-flight `CloudUploader` keeps sending events with a stale cached identity until DPAPI fails. Verify the WPF `SettingsViewModel` actually invokes a coordinated unenroll path.

### 6.8 Enrollment-state change notification
- **Feature**: `onStateChange` global callback
- **macOS source**: `Enrollment.swift:242-245`
- **Windows status**: **MISSING**
- **Detail**: macOS fires `Self.onStateChange?()` on enroll and unenroll so the menu / status panel refresh. Windows has no equivalent — UI must be manually told to re-read `IsEnrolled`. **Severity: MEDIUM** — UI may show stale state until a user-triggered refresh.

### 6.9 Server URL default + UserDefaults override
- **Feature**: Default URL + env override + persisted override
- **macOS source**: `Enrollment.swift:222-228`
- **Windows status**: **PARTIAL**
- **Detail**: macOS default `https://bromure.io/api`, overridable via `BROMURE_MANAGED_URL` env var OR `UserDefaults["managed.serverURL"]`. Windows default `https://app.bromure.io`, no env-var override, no settings override (`EnrollmentClient.cs:15`). **Severity: MEDIUM** — dev/staging users cannot point at a non-prod server through any config knob.

### 6.10 Bearer token storage
- **Feature**: Persist install bearer (DPKC on macOS, Credential Manager on Windows)
- **macOS source**: `Enrollment.swift:127-134`
- **Windows status**: **OK**
- **Detail**: macOS keychain: service `io.bromure.agentic-coding.managed-install`, account `install-token`. Windows Credential Manager via `WindowsSecretStore`: target `Bromure.AC:BromureAC:install-token`. Both prevent UI prompts.

### 6.11 Leaf private-key storage
- **Feature**: Per-serial private-key in OS secret store
- **macOS source**: `Enrollment.swift:144-153`
- **Windows status**: **OK** (modulo §6.5 — no key is ever issued)
- **Detail**: macOS stores PKCS#1 DER bytes under keychain account `leaf-cert-key-<serial>`. Windows stores DER bytes via `ISecretStore.StoreBlob("leaf-cert-key-" + serial, LocalMachine)` → DPAPI-wrapped under `MachineDataRoot\secrets\leaf-cert-key-<serial>.bin`. Atomic serial-pointer-last write pattern preserved.

### 6.12 Install metadata persistence
- **Feature**: install.json file
- **macOS source**: `Enrollment.swift:92-105` — pretty-printed sortedKeys, ISO-8601 dates
- **Windows status**: **OK**
- **Detail**: Windows uses `JsonSerializer` with `WriteIndented=true, PropertyNamingPolicy.CamelCase`. Saves atomically via tmp + Move. macOS uses `[.prettyPrinted, .sortedKeys]` + `.write(...options: .atomic)`. Equivalent.

### 6.13 Default device name
- **Feature**: Fallback device name
- **macOS source**: `Enrollment.swift:257-258` — `Host.current().localizedName ?? "unnamed"`
- **Windows status**: **OK**
- **Detail**: Windows: `Environment.MachineName` (`EnrollmentSheetViewModel.cs:27`). Both are sensible defaults.

### 6.14 EnrollmentCLI (`bromure-ac enroll/unenroll/status`)
- **Feature**: CLI counterparts to the GUI sheet
- **macOS source**: `Sources/AgentCoding/EnrollmentCLI.swift:1-123`
- **Windows status**: **MISSING**
- **Detail**: macOS exposes three CLI subcommands: `enroll --code --server-url --device-name`, `unenroll --force`, `status` (with `--code`, optional server-url and device-name). Windows has none — no CLI surface for headless enrollment, no scriptable provisioning. **Severity: HIGH** for the kiosk / mass-provisioning use case the macOS CLI was explicitly designed for ("Apple Configurator-style provisioning").

### 6.15 EnrollmentSheet behavior
- **Feature**: SwiftUI sheet UX
- **macOS source**: `EnrollmentSheet.swift:1-229` — title, subtitle (privacy posture text), code field, device name field, Advanced disclosure for server URL, error display, Cancel/Enroll buttons
- **Windows status**: **OK** (functional equivalent in WPF — not full-content audited here)
- **Detail**: `EnrollmentSheet.xaml.cs` + `EnrollmentSheetViewModel.cs` cover Code / ServerUrl / DeviceName / InFlight / ErrorMessage + Submit/Cancel commands. Same fields. Missing on Windows: the "Renew certificate" / status-panel split (macOS has `BACEnrollmentStatusView` exposed in the Window menu — not audited as Windows file).

### 6.16 Renew-certificate UI
- **Feature**: Button + handler to re-fetch leaf cert
- **macOS source**: `EnrollmentSheet.swift:199-211`
- **Windows status**: **MISSING**
- **Detail**: Direct consequence of §6.5 (no CSR flow). **Severity: HIGH** — once leaf certs expire (90 days TLS-typical), the user has no path to renew without unenrolling and re-enrolling.

### 6.17 Best-effort cert issuance during enroll
- **Feature**: Tolerate org-CA being unconfigured at enroll time
- **macOS source**: `Enrollment.swift:288-296` — wraps `fetchLeafCert` in try/catch, defers to heartbeat
- **Windows status**: **N/A**
- **Detail**: Windows has no `fetchLeafCert` to call. Consequence already captured under §6.5.

### 6.18 X25519 installPubkey generation
- **Feature**: Generate Curve25519 keypair and send public key on enroll
- **macOS source**: `Enrollment.swift:259-265`
- **Windows status**: **MISSING**
- **Detail**: Even though AC doesn't currently use the X25519 key for sealed-box delivery, the server requires it. See §6.2.

---

## 7. Cross-cutting

### 7.1 Privacy posture documentation
- macOS code is liberally commented with privacy reasoning. Windows ports preserve the comments where the code is faithfully ported.

### 7.2 Debug logging
- macOS uses `BACDebug.log("[tag]", ...)` throughout the cloud pipeline. Windows uses `ILogger.LogDebug` with the same tag prefixes (`[ac/emit]`, `[bac/uploader]` → `[cloud]`). Equivalent severity, slightly different category names.

### 7.3 Cloud uploader on AC vs Web
- macOS: `BACEnrollmentStore` is distinct from Bromure Web's `InstallIdentityStore` ("io.bromure.app.managed-install" vs "io.bromure.agentic-coding.managed-install"). Windows store path `MachineDataRoot\secrets\` plus the bearer-token target name `Bromure.AC:BromureAC:install-token` follow the same separation.

---

# Summary

## Counts by severity (distinct findings)
- **CRITICAL: 4**
  - §2.6 TraceStore vault wiring missing → trace bodies likely unencrypted at rest
  - §6.1 Different enrollment URL path + host
  - §6.2 Missing `installPubkey` in enroll request
  - §6.5 Missing CSR / leaf-cert issuance flow entirely
- **HIGH: 8** — §1.3 (no reactive trace feed), §1.7 (sync proxy-thread DB writes), §3.2 (drifted profile setting keys), §5.14 (mTLS key persisted to user CAPI store), §6.6 (no heartbeat), §6.7 (no coordinated unenroll), §6.14 (no enrollment CLI), §6.16 (no renew-cert UI)
- **MEDIUM: 8** — §1.1/1.2 (JSONL vs SQLite + body layout), §3.3 (no vm_exec debug tools), §3.4 (API route surface), §5.9 (`DefaultAnalyticsUrl` dead/misleading), §5.28 (verify credential events wired), §6.8 (no onStateChange), §6.9 (no env/UserDefaults override)
- **LOW: ~12** — assorted cosmetics, dead code, missing helpers (EmitDetached, ClearCache, displayName, etc.)

## Top 5 most impactful gaps
1. **No CSR / leaf-cert issuance on Windows (§6.5)** — kills mTLS to the analytics service. Cloud uploader will fail every batch. This is the single largest functional regression.
2. **Wrong enrollment URL + missing `installPubkey` (§6.1/6.2)** — enrollment itself likely 404s/400s against the real server. Without this, nothing downstream works.
3. **TraceStore probably writes UNENCRYPTED body files (§2.6)** — `MitmEngine` builds a `SecretsVault` but doesn't pass it as `IBodyEncryptor` into `TraceStore`. If verified, this is a security regression: API keys / cookies / OAuth bodies sit in plaintext on disk.
4. **mTLS identity round-trips through `UserKeySet|Exportable` (§5.14)** — leaks the install's private key into the user CAPI store on Windows. macOS never persists. Even if mTLS worked, the threat model would be weaker than macOS.
5. **No heartbeat + no unenroll orchestrator + no CLI (§6.6/6.7/6.14)** — admins see stale "last seen" forever; sign-out leaves the uploader running with a cached cert; no headless provisioning path. Three separate gaps that together make Windows installs unmanageable at scale.
