# Bromure Agentic Coding — Windows port

C#/.NET 8 reimplementation of `bromure-ac` per
[`WIN32_AC_PLAN.md`](../WIN32_AC_PLAN.md). The macOS sources under
`Sources/AgentCoding/` remain authoritative; this directory is the
parallel host-side rewrite.

## Solution layout

```
windows/
  Bromure.AC.sln
  Bromure.AC/                 WPF host shell (replaces SwiftUI views)
  Bromure.Platform/           IAppPaths / ISecretStore / ISettingsStore
  Bromure.SandboxEngine/      QEMU supervisor + QMP + qcow2 + vsock-bridge
  Bromure.AC.Mitm/            CA + leaves + swap + SigV4 + OAuth + proxy + agent
  Bromure.AC.Core/            Profile model + parsers + enrollment + SSO
  Bromure.Cloud/              CloudUploader + mTLS identity + LLM extractor
  Bromure.Spike/              Phase-0 spike CLI (boots Alpine under WHPX)
  Bromure.Tests/              xUnit — 105 / 105 passing across 20 files
guest/                       Rust workspace (fb-agent + clip-agent)
installer/                   Inno Setup script + build-installer.ps1
```

## Quickstart

```powershell
cd windows
dotnet build Bromure.AC.sln -c Release
dotnet test Bromure.Tests/Bromure.Tests.csproj -c Release   # 105 tests

# Launch the WPF host
dotnet windows\Bromure.AC\bin\Release\net8.0-windows\win-x64\BromureAC.dll

# Or boot Alpine under QEMU+WHPX through the Phase-0 spike
dotnet windows\Bromure.Spike\bin\Release\net8.0-windows\win-x64\bromure-spike.dll `
    --boot-iso ..\dist\images\alpine-virt.iso --grace-seconds 8 --headless
```

## Parity matrix

| macOS source | Windows port | Status |
|--------------|--------------|--------|
| `BromureAC.swift` (3267 LOC NSApplicationDelegate) | `Bromure.AC/App.xaml.cs` + `MainViewModel` | Skeleton WPF shell. Full state-machine port pending. |
| `UbuntuSandboxVM.swift` (492 LOC VZ config) | `Qemu/QemuSupervisor.cs` + `QemuCommandBuilder.cs` + `QmpClient.cs` | End-to-end exercised by Phase-0 spike. |
| `SessionDisk.swift` (`clonefile(2)`) | `Disk/EphemeralDisk.cs` (qcow2 backing-file overlay) | 76 ms cold-create on NVMe (Gate 2). |
| `SubscriptionTokenBridge.swift` (port 8446) | `Vsock/SubscriptionTokenBridge.cs` | Wire format identical; integration-tested. |
| `CodexTokenBridge.swift` (port 8447) | `Vsock/CodexTokenBridge.cs` | Same. |
| `Mitm/BromureCA.swift` + `CertCache.swift` | `Pki/BromureCa.cs` + `Pki/CertCache.cs` | BouncyCastle minting; DPAPI-LocalMachine private key. |
| `Mitm/SigV4Signer.swift` | `SigV4/SigV4Signer.cs` | Passes AWS get-vanilla reference vector byte-for-byte. |
| `Mitm/AWSResigner.swift` | `SigV4/AwsResigner.cs` | AWS-host detection, scope parsing, re-sign with real creds. |
| `Mitm/SessionTokenPlan.swift` | `Swap/SessionTokenPlan.cs` | HKDF-derived fakes, base62 alphabet, deterministic. |
| `Mitm/SubscriptionFakeMint.swift` | `Swap/SubscriptionFakeMint.cs` | JWT signature swap + Codex `rt_*` fake. |
| `Mitm/TokenSwap.swift` | `Swap/TokenSwapper.cs` + `TokenMap.cs` + `HostMatcher.cs` | Header swap, body sweep + CL patch, leak detection, consent gate. RFC-correct Content-Length. |
| `Mitm/CompromiseDetector.swift` | `Swap/AhoCorasick.cs` + `Swap/CompromiseDetector.cs` | Multi-pattern scanner + scope-violation detection. |
| `Mitm/ConsentBroker.swift` (NSAlert) | `Consent/ConsentBroker.cs` (+ `IConsentDialogPresenter`) | Broker logic + presenter seam. |
| `Mitm/OAuthRotationRewriter.swift` | `OAuth/OAuthRotationRewriter.cs` | Anthropic + Codex response-body rotation. |
| `Mitm/HTTPProxy.swift` (1491 LOC) | `Proxy/HttpMitmProxy.cs` (~370 LOC MVP) | CONNECT, TLS-MITM, swap, AWS-resign, OAuth-rewrite, forward, trace. |
| `Mitm/SecretsVault.swift` (Keychain) | `Vault/SecretsVault.cs` | AES-256-GCM, DPAPI-wrapped master key, same wire layout. |
| `Mitm/HostAgentClient.swift` (AF_UNIX) | `Ssh/HostAgentClient.cs` | NamedPipe / Unix / Tcp transports. |
| `Mitm/OpenSSHKeyFormat.swift` | `Ssh/OpenSshKeyFormat.cs` | ed25519 unencrypted PEM encoder, public-blob helper. |
| `Mitm/PrivateSSHAgent.swift` (subprocess) | `Ssh/PrivateSshAgent.cs` | In-process named-pipe agent with REQUEST_IDENTITIES + SIGN_REQUEST. |
| `Mitm/SSHAgent.swift` | `Ssh/SshAgentServer.cs` + `AgentKey.cs` | Per-profile key vault, consent-gated signing. |
| `Mitm/AWSCredentialServer.swift` | `Aws/AwsCredentialServer.cs` + `AwsCredentials.cs` | Fake-secret credential_process + real signing material. |
| `Mitm/CloudCredentials.swift` (registries) | `Pki/Registries.cs` (`ClientIdentityRegistry` + `ClusterCaTrustRegistry`) | Per-profile, per-host SecIdentity + cluster-CA tables. |
| `Mitm/MitmEngine.swift` | `Engine/MitmEngine.cs` | Process-lifetime owner of CA / swap / agent / proxy / consent / trace / vault. |
| `Mitm/TraceStore.swift` (JSONL) | `Trace/TraceStore.cs` + `TraceRecord.cs` | Microsoft.Data.Sqlite WAL; same record shape. |
| `CloudUploader.swift` | `Cloud/CloudUploader.cs` | Batched mTLS POST to `/ac-ingest`, 200 events / 5 s. |
| `CloudMTLSIdentity.swift` | `Cloud/CloudMtlsIdentity.cs` | DPAPI-wrapped leaf cert + key, in-memory X509Certificate2. |
| `CloudEvents.swift` | `Cloud/CloudEvent.cs` + `SessionTracker.cs` + `CloudEventEmitter.cs` | 20-min idle-rollover sessions; private-mode gate. |
| `LLMEventExtractor.swift` | `Cloud/LlmEventExtractor.cs` | Tool-name classification + Anthropic / OpenAI token counters. |
| `AWSConfigParser.swift` | `Imports/AwsConfigParser.cs` | Discovers SSO-capable profiles. |
| `AWSSSOResolver.swift` | `Imports/AwsSsoResolver.cs` | Cached-token reader + aws.exe sso login + role-credential fetch. |
| `DockerConfigImport.swift` | `Imports/DockerConfigImport.cs` | Reads `~/.docker/config.json`, normalises Docker Hub aliases. |
| `KubeconfigImport.swift` | `Imports/KubeconfigImport.cs` | YAML kubeconfig parser. |
| `TerminalAppDefaults.swift` (Terminal.app plist) | `Imports/TerminalDefaults.cs` (Windows Terminal settings.json) | Reads font + colors, falls back gracefully. |
| `DefaultSSHKey.swift` | `Ssh/DefaultSshKey.cs` | ed25519 keypair via BouncyCastle, OpenSSH pubkey text. |
| `Profile.swift` (2985 LOC) | `Model/Profile.cs` + `Credentials.cs` + `KubeconfigEntry.cs` + `ProfileColor.cs` | Data model + sub-records. Mutation helpers added on demand. |
| `ProfileStore` (in Profile.swift) | `Model/ProfileStore.cs` | JSON-on-disk persistence, atomic save. |
| `Enrollment.swift` | `Enrollment/Enrollment.cs` | Install identity, bearer, leaf cert + key persistence. |

## Phase-0 gate status

| Gate | Description | Status |
|------|-------------|--------|
| 1 | vsock-on-QEMU+WHPX round-trip ≤ 50 ms p95 | **Blocked → B-plan engaged.** MSYS2 QEMU build ships without vhost-vsock-pci; bridges fall back to TCP-on-NAT (wire format socket-agnostic). |
| 2 | qcow2 backing-file create ≤ 1.5 s | **PASS — 76 ms** (21× headroom). |
| 3 | Framebuffer / typing latency ≤ 30 ms p95 | Not yet measured; `guest/fb-agent/` ships the wire protocol skeleton. |
| 4 | virtio-9p throughput ≥ 200 MB/s | Architecture wired in `QemuConfig.Shares`; not yet measured. |
| 5 | Installer end-to-end | Skeleton (`installer/BromureAC.iss`) covers UAC + DISM + RunOnce-resume. |

## Test coverage (105 tests across 20 files)

```
dotnet test Bromure.Tests/Bromure.Tests.csproj -c Release
```

Notable security-critical coverage:

- **`SigV4SignerTests.GetVanilla_MatchesAwsReferenceSignature`** — pins
  AWS's reference vector. If this drifts, our re-signed Bedrock requests
  fail in production with `InvalidSignatureException`.
- **`HostMatcherTests.HostMatchesScope_StrictSubdomainOnly`** — pins the
  `anthropic.com.evil.com` substring-attack guard. Substring matching
  in the swap path would be a security hole.
- **`TokenSwapperTests`** — header swap, host-scope mismatch, body sweep
  + Content-Length patch, consent gating, leak detection.
- **`CompromiseDetectorTests`** — fake leaving for unscoped host fires;
  sibling subdomains under same registered domain stay legitimate.
- **`OAuthRotationRewriterTests`** — Claude + Codex token rotation,
  idempotence on already-fake tokens.
- **`PrivateSshAgentTests`** — full add → list-identities → sign →
  verify round-trip through the real named-pipe agent (BouncyCastle
  ed25519 verifier confirms the signature is genuine).
- **`BromureCaTests`** — CA persistence + per-host leaf caching +
  issuer-subject linkage.
- **`HttpMitmProxyTests`** — CONNECT 200, non-CONNECT 405.
- **`TokenBridgeTests`** — end-to-end SubscriptionTokenBridge /
  CodexTokenBridge round-trips through real named-pipe transport.
- **`EnrollmentStoreTests`** — install metadata persistence,
  bearer-token gating, atomic leaf-cert serial pointer.

## What's still missing for full parity

| Plan area | Status |
|-----------|--------|
| `WebSocketTrace.swift` deflate path | Frame decoder + permessage-deflate inflater ported (`WsFrameDecoder` / `WsInflater`); the proxy itself doesn't yet hook them on the WS upgrade path. |
| `RealtimeEventTap.swift` | Pending. |
| `ConversationParser` + the deeper LLM body capture | Pending; `LlmEventExtractor` covers tool classification + token counts. |
| `EnrollmentCLI.swift` | Pending; the GUI sheet covers the interactive flow. |
| `ProfileViews.swift` (3001 LOC) field-by-field editor | Slim port (display name + tool + auth + folders + delete/save). The full kubeconfig / git-creds / docker / manual-token / SSH-key tree editor is iterative. |
| `ConversationView.swift` (1318 LOC) chat view | Pending. |
| Localization (`.resw`) | English-only for now. |
| Inno installer compile + Authenticode signing | Skeleton only. Needs Inno Setup installed locally + EV cert ordered. |
| Rust guest agents (XDamage capture, real ICCCM clipboard) | Skeleton wire protocols; full capture pending WSL build. |

## Lines of code

~13,200 LOC of C# + 950 lines of XAML over the macOS Swift surface,
with the host state-machine + proxy + agent + cloud + UI all on
Windows-idiomatic APIs (DPAPI, Named Pipes, BouncyCastle, SslStream,
AesGcm, HwndHost, WPF MVVM).
