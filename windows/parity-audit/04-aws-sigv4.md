# Parity Audit: AWS SigV4 Signer + Resigner + Credential Server

**Scope**: macOS `Sources/AgentCoding/Mitm/{SigV4Signer.swift, AWSResigner.swift, AWSCredentialServer.swift}` and host wiring in `MitmEngine.swift` / `HTTPProxy.swift` / `BromureAC.swift` vs Windows `windows/Bromure.AC.Mitm/{SigV4, Aws, Proxy, Engine}` + supporting code in `Bromure.AC.Core` and `Bromure.SandboxEngine`.

## Findings Summary — 22 gaps

| Severity | Count |
|----------|-------|
| CRITICAL (silent breakage / security regression) | 5 |
| HIGH (functional gap that hits common workflows) | 6 |
| MEDIUM (audit / UX / cosmetic) | 7 |
| LOW (edge cases / latent traps) | 4 |

## Top 5 Most Impactful Gaps

### 1. CRITICAL — Real AWS Secret Written Verbatim into the Guest VM (threat-model collapse)
- **macOS**: `Profile.swift:2279–2316` writes `~/.aws/config` with `credential_process = /mnt/bromure-meta/bromure-aws-creds.py` and intentionally NEVER writes `~/.aws/credentials`; the secret only ever lives on the host (`AWSCredentialServer.swift:33–113`).
- **Windows**: `SessionHomeBuilder.cs:113–121` writes `.aws/credentials` containing **plaintext** `aws_access_key_id`, `aws_secret_access_key`, and `aws_session_token` into the guest home overlay. Comment at line 114–116 admits: *"Static-keys mode also writes ~/.aws/credentials so the SDK can find the AKID/secret without our credential_process helper (which the macOS port uses but isn't ported yet)."*
- **Impact**: The fail-closed guarantee documented in `AWSResigner.swift:11–13` ("If a request bypasses the proxy, AWS rejects it with InvalidSignatureException") is **gone on Windows**. The SDK in the VM signs every request with the real secret. Anything in the VM (malicious npm package, compromised tooling, leaked file via 9p) can exfiltrate the live IAM secret. This converts Bromure AC's central AWS isolation claim into a no-op. **This is the worst possible regression for the AWS surface and must be fixed before any AWS-using profile is shipped on Windows.**

### 2. CRITICAL — `AwsCredentialServer.SetCredentials` Is Never Called Anywhere
- **macOS**: `BromureAC.swift:2127–2174` calls `engine.awsCreds.setCredentials(...)` at session start for every profile (SSO-resolved or static), and the `AWSSSOResolver.startRefreshLoop` keeps it refreshed.
- **Windows**: Grep across the entire `windows/` tree for `SetCredentials` returns exactly one match — the method definition in `AwsCredentialServer.cs:36`. No call site exists in `App.xaml.cs`, `ShellViewModel.cs`, `SessionsViewModel.cs`, `SessionViewModel.cs`, or `SettingsViewModel.cs`.
- **Impact**: `_byProfile` is permanently empty, so `SigningMaterialAsync` always returns `Missing` (`AwsCredentialServer.cs:67`). `AwsResigner.ResignAsync` falls through to `Outcome.Unchanged` (`AwsResigner.cs:90–94`) and forwards the guest's (now real-secret-signed) request unchanged. Combined with #1 this means: **Windows behaves as if the resigner did not exist.** The signer pipeline is built and unit-tested but disconnected from runtime credential delivery.

### 3. CRITICAL — Credential Server Has No Transport (vsock listener never wired)
- **macOS**: `MitmEngine.swift:74–76, 173–174` reserves vsock port 8445 and wires a `VZVirtioSocketListener` to `AWSCredsListenerDelegate` (`MitmEngine.swift:345–365`), which calls `awsCreds.serve(fd:profileID:)` and pushes the JSON payload. The guest's `bromure-aws-creds.py` (`Sources/AgentCoding/Resources/vm-setup/bromure-aws-creds.py`) reads from `/tmp/bromure-aws-creds.sock` (bridged to vsock 8445 by `bromure-vm-bridge.py`).
- **Windows**: `MitmEngine.cs:34, 43–44` declares the constant `AwsCredsVsockPort = 8445` and the doc comment lists it, but **no listener is ever registered**. `AwsCredentialServer.WriteCredentialProcessPayloadAsync(Stream, Guid, CancellationToken)` is defined (`AwsCredentialServer.cs:87–92`) but has zero call sites. `VsockBridge.cs` exposes a generic named-pipe bridge but no AWS port is registered. The guest setup script `setup-hcs.sh` has zero AWS-creds-helper installation.
- **Impact**: Even if #1 + #2 were fixed, there is no IPC path from the guest's `credential_process` helper to the host. The `IAwsCredentialServer` doc-comment (`IAwsCredentialServer.cs:6–10`) speculates about an "IMDSv2-shaped HTTP server inside the host (port 169.254.170.2 in the guest, tunnelled via the proxy)" — neither IMDSv2 nor the vsock pattern is implemented. The Windows guest has no way to ever obtain the fake-secret payload.

### 4. HIGH — No Audit Event Emitted for AWS Re-sign (`credential.aws_sign`)
- **macOS**: `AWSResigner.swift:194–209` calls `BACEventEmitter.shared.emitDetached(profileID:eventType:"credential.aws_sign", eventData:[method, host, path, service, region, access_key_masked])`. Comment from `LLMEventExtractor.swift:19` documents `aws_sign` as one of three credential-related audit event types fed to the cloud event sink.
- **Windows**: `AwsResigner.cs:163` returns `Outcome.Resigned` with no log line, no `_onCloudEvent` callback, no equivalent of the `[mitm] AWS resign … akid=…` stderr log line at macOS `AWSResigner.swift:189–192`. `Bromure.Cloud/LlmEventExtractor.cs:19` still references `aws_sign` in its comment but no producer exists.
- **Impact**: Audit pipeline gap. Compliance / forensics cannot account for AWS API calls signed on the user's behalf. The `OnCloudEvent` hook on `MitmEngine.cs:90` is wired for `credential.token_swap` but the AWS path bypasses it.

### 5. HIGH — Bedrock / SSO Profile Auto-Resolve at Session Start Is Disconnected
- **macOS**: `BromureAC.swift:2127–2172` resolves SSO at session start (`AWSSSOResolver.resolve`), pushes resolved creds into `awsCreds.setCredentials`, then arms a `startRefreshLoop` that auto-refreshes credentials before expiration and re-pushes via `setCredentials` callback.
- **Windows**: `AwsSsoResolver.cs` is a direct port and works, but there is NO call site that invokes it at session launch. `SessionViewModel.StartAsync` (`SessionViewModel.cs:134–198`) never calls `AwsSsoResolver.ResolveAsync` and never pushes anything to `_engine.AwsCreds`. There is also no `startRefreshLoop` equivalent — `AwsSsoResolver.cs` exposes one-shot `ResolveAsync` only.
- **Impact**: Even if the resigner pipeline were connected, Bedrock-via-SSO profiles cannot work because no fresh STS material is ever pulled. Static-keys mode also fails because the static creds are never installed in the in-memory `_byProfile` map. **All AWS auth modes on Windows are functionally broken.**

---

## Full Findings

### 6. SigV4 canonical request construction — OK
- **Feature**: Method, path encoding, query canonicalization, header canonicalization, signed-headers list, payload hash, key-derivation chain.
- **macOS source**: `SigV4Signer.swift:89–156, 190–260`
- **Windows status**: OK
- **Detail**: Direct port. Header sorting uses `StringComparer.Ordinal` (matches Swift's `<` String comparison for ASCII-lowercase header names). Headers grouped by name and joined with `','` (RFC 9110 §5.3). `\n`-separated 6-line canonical request. `Sign` writes `AWS4-HMAC-SHA256` STS prefix and matches the get-vanilla reference vector — verified by `SigV4SignerTests.cs:23–53`.

### 7. Key-derivation chain — OK
- **macOS source**: `SigV4Signer.swift:137–145`
- **Windows status**: OK
- **Detail**: `kSecret = UTF8("AWS4" + secret)`; HMAC-SHA256 chain `kDate ← kSecret(date)`, `kRegion ← kDate(region)`, `kService ← kRegion(service)`, `kSigning ← kService("aws4_request")`. Final signature is HMAC-SHA256(kSigning, stringToSign) hex-encoded lower-case. Byte-for-byte parity with macOS (`SigV4Signer.cs:95–101`) and validated against the AWS "get-vanilla" vector.

### 8. URI encoding (RFC 3986 segment encoding) — OK
- **macOS source**: `SigV4Signer.swift:199–220`
- **Windows status**: OK
- **Detail**: Both iterate UTF-8 bytes (`Encoding.UTF8.GetBytes(s)` in C#, `s.utf8` in Swift); both treat `A-Z a-z 0-9 - . _ ~` as unreserved and percent-encode everything else with upper-case hex digits. Both encode `%` itself, producing double-encoding when wire path already carries `%XX`. Bedrock `:` test (`SigV4SignerTests.cs:63–72`) covers the critical regression path.

### 9. S3 canonical-path special-case — OK
- **macOS source**: `SigV4Signer.swift:192`
- **Windows status**: OK
- **Detail**: Both short-circuit `service.lowercased() == "s3"` to pass the path through untouched. `CanonicalPath_S3IsLeftIntact` test covers it.

### 10. Empty path handling — OK
- **macOS source**: `SigV4Signer.swift:191`
- **Windows status**: OK
- **Detail**: Both map empty path to `"/"`. Empty path segments (`//`) are preserved via Swift's `omittingEmptySubsequences: false` / C#'s default `String.Split('/')` (which does preserve empties).

### 11. Canonical query string sorting — OK
- **macOS source**: `SigV4Signer.swift:226–241`
- **Windows status**: OK
- **Detail**: Both split on `&`, parse `key=value`, sort lexicographically by key then value, rejoin. C# uses `string.CompareOrdinal` matching Swift's `<` on String for ASCII inputs. The unit test `CanonicalQueryString_SortsByKeyThenValue` (`SigV4SignerTests.cs:74–79`) covers duplicate-key ordering.

### 12. Canonical header-value collapse (whitespace + quoted strings) — OK
- **macOS source**: `SigV4Signer.swift:246–260`
- **Windows status**: OK
- **Detail**: Both trim leading/trailing whitespace and collapse internal `' '|'\t'` runs to a single space outside double-quoted strings. Unit tests cover both whitespace and quoted runs.

### 13. Authorization header format and credential scope — OK
- **macOS source**: `SigV4Signer.swift:147–150`
- **Windows status**: OK
- **Detail**: `AWS4-HMAC-SHA256 Credential=AKID/DATE/REGION/SERVICE/aws4_request, SignedHeaders=…, Signature=…` produced verbatim. `CredentialScope` accessor identical.

### 14. AWS host detection — OK (but partition coverage is incomplete on BOTH platforms)
- **Feature**: AWS-host suffix matching.
- **macOS source**: `AWSResigner.swift:62–68`
- **Windows status**: OK (parity with macOS)
- **Detail**: Both match `amazonaws.com`, `amazonaws.com.cn`, `*.amazonaws.com`, `*.amazonaws.com.cn`. Lowercased before suffix comparison. *Caveat (applies to both)*: `amazonaws.com.cn` covers China but does NOT cover IP-literal hosts (e.g. `52.94.…`), `c2s.ic.gov`/`sc2s.sgov.gov` (US ISO partitions), or `cloud.aws.dev`. SigV4a (asymmetric) is explicitly out of scope per `AWSResigner.swift:33`. No regression on Windows.

### 15. Scope parsing from Authorization header — OK
- **macOS source**: `AWSResigner.swift:219–228`
- **Windows status**: OK
- **Detail**: Both extract `Credential=AKID/DATE/REGION/SERVICE/aws4_request`, split on `/`, require 5 parts with trailing `aws4_request`. Both bail with the same `502 Bad Gateway` `bromure: could not parse AWS Authorization` response on malformed input. Edge case: macOS scans until `,` or whitespace; Windows scans for `, ` or whitespace via `char.IsWhiteSpace` — equivalent for `Credential=…/aws4_request, SignedHeaders=…` shape.

### 16. UNSIGNED-PAYLOAD passthrough — OK
- **macOS source**: `AWSResigner.swift:95–148`
- **Windows status**: OK
- **Detail**: Both detect `X-Amz-Content-SHA256: UNSIGNED-PAYLOAD` and forward as `unsignedPayload=true` to the signer; both regenerate the `X-Amz-Content-SHA256: UNSIGNED-PAYLOAD` header verbatim on the wire.

### 17. STREAMING-AWS4-HMAC-SHA256-PAYLOAD rejection — OK
- **macOS source**: `AWSResigner.swift:96–102`
- **Windows status**: OK
- **Detail**: Both detect chunked-upload signing and return `501 Not Implemented` with the `bromure: aws-chunked uploads not supported by the host signer` body. Identical text + status.

### 18. Header drop list before signing — OK
- **macOS source**: `AWSResigner.swift:130–141`
- **Windows status**: OK
- **Detail**: Both drop `authorization`, `x-amz-date`, `x-amz-content-sha256`, `x-amz-security-token`, `host`, `content-length`, `connection`, `proxy-connection`, `transfer-encoding`, `keep-alive`, `te`, `upgrade`, `proxy-authorization` and regenerate the first four + `Host`. Identical case-insensitive comparisons.

### 19. Wire reassembly drops synthetic Host — OK
- **macOS source**: `AWSResigner.swift:182–187`
- **Windows status**: OK
- **Detail**: Both sign over `Host` but filter it out before reassembly so URLSession (macOS) / SocketsHttpHandler-equivalent (Windows) derives Host from the URL on the wire and avoids duplicates. Both append `Authorization` last.

### 20. Resign hook in proxy pipeline — OK
- **macOS source**: `HTTPProxy.swift:277–319` (step 6b, after token swap)
- **Windows source**: `HttpMitmProxy.cs:223–239` (step 5b, after `_swapper.SwapAsync`, after `McpProxyHooks.InjectMcpBearer`)
- **Windows status**: OK
- **Detail**: Wire location matches: token-swap first, then AWS resign. Both short-circuit Denied/Failed by writing the response back to the client TLS server stream and returning. **Subtle gap**: macOS `HTTPProxy.swift:294–304` calls `emitTrace(...)` on Denied/Failed paths so the inspector records the failure; Windows simply writes the response and returns with no trace record (`HttpMitmProxy.cs:231–236`). Trace inspector loses Denied/Failed AWS calls — minor but noted.

### 21. CRITICAL — Real AWS secret written into guest (cross-reference #1) — see above

### 22. CRITICAL — SetCredentials never called (cross-reference #2) — see above

### 23. CRITICAL — Credential transport missing (cross-reference #3) — see above

### 24. HIGH — `credential_process` helper not installed in the guest image
- **macOS source**: `Sources/AgentCoding/Resources/vm-setup/bromure-aws-creds.py` (Python helper packed into `vm-setup/`) + `Profile.swift:2306` writes `credential_process = /mnt/bromure-meta/bromure-aws-creds.py` into the guest's `~/.aws/config`.
- **Windows status**: MISSING
- **Detail**: `windows/Bromure.SandboxEngine/Image/setup-hcs.sh` does not stage the credential_process helper. `SessionHomeBuilder.cs:266–278` writes only `[default]` + `sso_session=` / `region=` — never `credential_process`. There is no Windows-equivalent helper script anywhere in the tree.
- **Impact**: Even if the host vsock listener were wired, the guest SDK would have nothing to invoke to fetch credentials. The entire fake-secret strategy is unreachable from the guest side on Windows.

### 25. HIGH — `~/.aws/config` writer omits `credential_process` directive
- **macOS source**: `Profile.swift:2300–2316` writes:
  ```
  [default]
  credential_process = /mnt/bromure-meta/bromure-aws-creds.py
  region = …
  ```
- **Windows source**: `SessionHomeBuilder.BuildAwsConfig` (`SessionHomeBuilder.cs:266–278`) writes:
  ```
  [default]
  sso_session = …      (SSO mode only)
  region = …
  ```
- **Detail**: SSO mode writes a non-functional `sso_session = <name>` line (the field semantics are wrong — `sso_session` references a `[sso-session]` block, not an SSO profile name). Static-keys mode writes `[default]` with only a region, then `.aws/credentials` separately. Neither mode points the SDK at any credential_process helper.

### 26. HIGH — Audit event `credential.aws_sign` not emitted (cross-reference #4)

### 27. HIGH — SSO resolve / refresh loop never invoked at session start (cross-reference #5)

### 28. HIGH — Fake-secret payload format diverges (JSON key ordering documented as fixed)
- **macOS source**: `AWSCredentialServer.swift:150–164` uses `JSONSerialization.data(withJSONObject:options:[.sortedKeys])` producing alphabetically-sorted keys.
- **Windows source**: `AwsCredentialServer.cs:104–110` uses `JsonSerializer.Serialize(new SortedDictionary<string,object>{...})` — also sorted alphabetically.
- **Status**: OK at the byte level (both produce `{"AccessKeyId":"…","SecretAccessKey":"…","Version":1}` sorted). However the macOS payload uses `"Version": 1` as an integer; the C# variant boxes the literal `1` as `object` then `JsonSerializer` writes it as `1` — matches. **No gap**, included here only because future drift between `JsonSerializer` integer vs string semantics would silently break credential_process parsing.

### 29. MEDIUM — Error payload key ordering
- **macOS source**: `AWSCredentialServer.swift:166–170` writes `{"Version":1,"Error":"…"}` (key order `Version, Error` — `JSONSerialization` default).
- **Windows source**: `AwsCredentialServer.cs:113–121` writes `{"Error":"…","Version":1}` (sorted).
- **Impact**: SDK ignores key order. Cosmetic. Documented because the macOS code path does NOT use sorted-keys for the error case (line 168 omits `.sortedKeys`) while the success case does — Windows is consistent (sorts both). Trivial divergence.

### 30. MEDIUM — Fake-secret generation byte distribution differs
- **macOS source**: `AWSCredentialServer.swift:177–188` uses `SystemRandomNumberGenerator.next()` (`UInt64`) and `idx % UInt64(alphabet.count)` — modulo-bias against a 64-bit value over a 64-char alphabet (`64` divides `2^64` evenly, so actually no bias).
- **Windows source**: `AwsCredentialServer.cs:129–137` uses `RandomNumberGenerator.Fill(buf)` (cryptographic) and `buf[i] % 64` — modulo of a `byte` (`0–255`) over `64`. Since `256 % 64 == 0`, again unbiased.
- **Status**: OK (no bias either way). Both produce `[A-Za-z0-9+/]^40`. Noted because if either side changed the alphabet length to non-power-of-two the bias would silently emerge.

### 31. MEDIUM — `vendedSecret` rotated on `SetCredentials` — OK
- **macOS source**: `AWSCredentialServer.swift:59–65` regenerates `vendedSecret` on each `setCredentials`.
- **Windows source**: `AwsCredentialServer.cs:45–51` does the same.
- **Status**: OK.

### 32. MEDIUM — `ClearCredentials` parity — OK
- **macOS source**: `AWSCredentialServer.swift:67–70`
- **Windows source**: `AwsCredentialServer.cs:54–57`
- **Status**: OK. Both remove the entry under lock.

### 33. MEDIUM — Consent flow parity — OK
- **macOS source**: `AWSCredentialServer.swift:99–107`
- **Windows source**: `AwsCredentialServer.cs:68–74`
- **Status**: OK. Both call `consent.requestConsentAsync` with `ConsentCredentialId.Aws()` ("aws"), `"AWS access key <masked>"`, and the same scope hint string `"for any AWS API call (SigV4 signing on the host)"`. **Localization gap**: macOS uses `NSLocalizedString(...)` which means the prompt is localized for the 7 locales bundled (`de, en, es, fr, ja, pt, zh-Hans, zh-Hant`); Windows hard-codes the English string at `AwsResigner.cs:79`. Not a security issue but breaks the macOS i18n promise on Windows.

### 34. MEDIUM — Masking of AKID in logs/UI — OK
- **macOS source**: `AWSCredentialServer.swift:137–140` and `AWSResigner.swift:230–233` both produce `"AKIA…XXXX"` (first 4 + ellipsis + last 4) for AKIDs longer than 6 chars; `"***"` otherwise.
- **Windows source**: `AwsCredentialServer.cs` does NOT define a private `MaskAccessKey`; instead the consent path calls into `AwsResigner.MaskAccessKey` (`AwsResigner.cs:184–188`). The implementation matches macOS (first 4 + `…` + last 4).
- **Status**: OK functionally. Minor structural divergence (utility lives in a different class) — no impact.

### 35. MEDIUM — `Expiration` field intentionally omitted from credential_process payload — OK
- **macOS source**: `AWSCredentialServer.swift:142–164` comment explains "Omitting Expiration lets the SDK cache for the consumer process's lifetime".
- **Windows source**: `AwsCredentialServer.cs:101–110` preserves this.
- **Status**: OK.

### 36. LOW — `ParsedHttpRequest` parser: subtle divergence on lines lacking `\r\n` terminator
- **macOS source**: `AWSResigner.swift:285–315` uses `String.split(separator: "\r\n", omittingEmptySubsequences: false)`.
- **Windows source**: `AwsResigner.cs:252` uses `headerStr.Split("\r\n")` (default = `StringSplitOptions.None`).
- **Status**: OK. Both preserve empty trailing entries the same way. The Windows version then skips empty lines (`if (ln.Length == 0) continue;`) before colon parsing, matching the macOS `for ln in lines where !ln.isEmpty`.

### 37. LOW — Method/path parser tolerance
- **macOS source**: `AWSResigner.swift:289–301` splits the request line by `" "` (single space).
- **Windows source**: `AwsResigner.cs:255` does `first.Split(' ')` — also single space.
- **Status**: OK. Both reject empty parts via `parts.Length < 2 / parts.count < 2` checks.

### 38. LOW — Body extraction `subdata` vs `Buffer.BlockCopy`
- **macOS source**: `AWSResigner.swift:280–281` — `Data.subdata(in:)`.
- **Windows source**: `AwsResigner.cs:249–250` — `new byte[len]` + `Buffer.BlockCopy`.
- **Status**: OK. Equivalent semantics.

### 39. LOW — Empty-body edge case
- **macOS source**: `SigV4Signer.swift:99–103` computes `hexSHA256(Data())` for empty body → `e3b0c442…2b855`.
- **Windows source**: `SigV4Signer.cs:57` does `HexSha256(ReadOnlyMemory<byte>.Empty.Span)` → same hash.
- **Status**: OK. The get-vanilla test (`SigV4SignerTests.cs:39`) covers this.

### 40. CRITICAL/Architectural — There is no path on Windows where AWS Bedrock from Claude Code can actually work without leaking the secret
- **Discussion**: The combination of #1 (real keys in guest), #2 (resigner disconnected), #3 (no transport), #5 (no SSO resolve at start), and #24 (no credential_process helper) means **every AWS workflow on Windows operates outside the security model Bromure AC promises**.
- For Bedrock-via-static-keys: guest signs with the real secret, request reaches AWS successfully — but the threat model is violated because the secret is on the guest disk and in SDK memory.
- For Bedrock-via-SSO: nothing populates `_byProfile` and `~/.aws/credentials` is NOT written (`SessionHomeBuilder.cs:117–120` only writes credentials for StaticKeys), so the SDK has no creds at all — request fails. Even if SSO worked, the resolved STS material would still be written to the guest disk if you flipped the AuthMode to StaticKeys.
- **This must be the next thing fixed for the Windows AWS surface.**

### 41. MEDIUM — `IAwsCredentialServer` interface signature understates what callers need
- **macOS source**: `AWSCredentialServer.swift` exposes `setCredentials`, `clearCredentials`, `serve(fd:profileID:)`, and `signingMaterial(for:scopeHint:)`. The resigner only uses the last.
- **Windows source**: `IAwsCredentialServer.cs:11–14` exposes ONLY `SigningMaterialAsync` — `SetCredentials`, `ClearCredentials`, `WriteCredentialProcessPayloadAsync` are on the concrete class. This is fine for the resigner but means a test double (e.g. `NullCredServer` in `HttpMitmProxyTests.cs:100–104`) cannot stand in for the full surface, and the concrete `AwsCredentialServer` is impossible to mock for transport tests.
- **Impact**: Test infrastructure gap. Would need to be widened when transport is added.

### 42. MEDIUM — No test coverage for `AwsResigner.ResignAsync` end-to-end on Windows
- **macOS source**: macOS has no dedicated `Tests/.../AWSResignerTests.swift` either (the test suite ships SigV4 vectors only).
- **Windows source**: `SigV4SignerTests.cs` covers the signer (vanilla vector, Bedrock colon-encoding, query sort, header value canonical). There is **no** `AwsResignerTests.cs` or similar covering `ParseScope`, `IsAwsHost` partition handling, or the Outcome enum. `HttpMitmProxyTests.cs:82` constructs a resigner with `NullCredServer` (always returns Missing), so the unchanged-path is exercised but the Resigned / Denied / Failed paths are not.
- **Impact**: Regressions in scope parsing or AWS-host detection would not be caught.

### 43. LOW — `IsAwsHost` allocates a lowercase copy of the entire host string per call
- **macOS source**: `AWSResigner.swift:63` — `host.lowercased()` allocates.
- **Windows source**: `AwsResigner.cs:39` — `host.ToLowerInvariant()` allocates.
- **Status**: OK (parity). Noted because this runs on every request; not worth optimising for AWS-call frequencies.

---

## Wire-format Compliance Check (byte-level)

Both signers produce identical wire bytes for the AWS "get-vanilla" vector — verified by `SigV4SignerTests.GetVanilla_MatchesAwsReferenceSignature`. The canonical-request, string-to-sign, and final HMAC chain are byte-exact across platforms. **The signer itself is solid; everything around it (transport, credential delivery, audit, guest-side helper) is the gap.**

## Recommended Remediation Order

1. **STOP writing `.aws/credentials` to the guest** (`SessionHomeBuilder.cs:117–121`). This is the single most impactful change — disables the secret leak immediately even if it breaks AWS-from-Bromure temporarily.
2. **Wire the AWS vsock-equivalent transport** (named pipe via `VsockBridge` on port 8445, or an in-host HTTP IMDSv2 endpoint reachable from the guest through the proxy).
3. **Ship a Windows-side `bromure-aws-creds` helper** into the guest overlay (Python or static binary) and add `credential_process = …` to `SessionHomeBuilder.BuildAwsConfig`.
4. **Call `AwsCreds.SetCredentials` at session start** from `SessionViewModel.StartAsync` for static-keys, and from a freshly-added SSO start-bootstrap that calls `AwsSsoResolver.ResolveAsync` + arms a refresh loop.
5. **Emit `credential.aws_sign`** via `_onCloudEvent` in `AwsResigner.ResignAsync` before returning `Outcome.Resigned`.
6. **Localize** the consent scope-hint string.

## File Locations (absolute)

- macOS signer: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Mitm\SigV4Signer.swift`
- macOS resigner: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Mitm\AWSResigner.swift`
- macOS credential server: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Mitm\AWSCredentialServer.swift`
- macOS host wiring: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Mitm\MitmEngine.swift:74–365`, `BromureAC.swift:2127–2174`, `HTTPProxy.swift:277–319`
- macOS guest helper: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Resources\vm-setup\bromure-aws-creds.py`
- macOS profile materializer: `C:\Users\renaud\Devel\bromure\Sources\AgentCoding\Profile.swift:2279–2316`
- Windows signer: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\SigV4\SigV4Signer.cs`
- Windows resigner: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\SigV4\AwsResigner.cs`
- Windows credential server: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\Aws\AwsCredentialServer.cs`
- Windows credential interface: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\Aws\IAwsCredentialServer.cs`
- Windows credentials record: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\Aws\AwsCredentials.cs`
- Windows host wiring: `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\Engine\MitmEngine.cs:107–108, 177` (only), `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Mitm\Proxy\HttpMitmProxy.cs:223–239`
- Windows profile materializer (the leak): `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Core\Model\SessionHomeBuilder.cs:109–121, 266–312`
- Windows SSO resolver (unused at runtime): `C:\Users\renaud\Devel\bromure\windows\Bromure.AC.Core\Imports\AwsSsoResolver.cs`
- Windows guest setup (no creds helper installed): `C:\Users\renaud\Devel\bromure\windows\Bromure.SandboxEngine\Image\setup-hcs.sh`
- Windows tests: `C:\Users\renaud\Devel\bromure\windows\Bromure.Tests\SigV4SignerTests.cs` (signer only; no resigner / credential-server tests)
