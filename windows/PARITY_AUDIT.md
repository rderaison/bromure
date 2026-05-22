# macOS ↔ Windows Parity Audit

**Audit date**: 2026-05-21
**macOS ref**: `Sources/AgentCoding/*.swift` + `Sources/AgentCoding/Mitm/*.swift` (HEAD, branch `windows`)
**Windows ref**: `windows/Bromure.AC.*` + `windows/Bromure.Cloud` + `windows/Bromure.Platform` + `windows/Bromure.SandboxEngine` (working tree)
**Method**: 10 parallel sub-agents read every Swift file in scope and the corresponding Windows files in full, then wrote feature-level gap reports. See `windows/parity-audit/01..10-*.md` for the detail.

This file is the **executive summary** and **gap index**. The full per-finding detail (with file:line references for every gap) lives in the section files.

---

## Headline result

**~245 feature-level gaps total** across the 10 subsystems audited. Of these:

| Severity | Count | Definition |
|----------|-------|------------|
| **CRITICAL** | 41 | Blocks production launch, silent data corruption, security regression, or "wired but disconnected" classes that have no call site at all |
| **HIGH** | 67 | Documented feature broken or missing on Windows; user-facing UX regression |
| **MEDIUM** | 64 | Feature partial; edge cases unhandled |
| **LOW** | 73 | Logging, validation helpers, error message polish |

The user-cited example — **the image-versioning alert prompting "use new image / use old image"** — is **CONFIRMED MISSING on Windows**, and worse: the current Windows code (`VhdxDisk.cs:65-72`) *silently wipes and recreates* the per-profile child VHDX whenever the parent VHDX is newer. The user gets a forced data wipe with no choice. See section 10 below.

---

## The 15 most urgent CRITICAL gaps (in priority order)

These are the items that, if you shipped today, would either lose user data, leak credentials, or produce a non-functional product. Every one of them is a class that exists on Windows but isn't wired into any call site, OR a macOS feature with no Windows counterpart at all.

| # | Subsystem | Gap | macOS source | Section |
|---|-----------|-----|--------------|---------|
| 1 | Image/VM | **Image-versioning alert missing; profile disk silently wiped on rebake** | `BromureAC.swift:2019-2041`, `SessionDisk.swift` | [10](parity-audit/10-image-session-vm.md) |
| 2 | Profile | **Secrets stored unencrypted in `profile.json` on disk** (`SecretsVault` not wired) | `Profile.swift:1353-1548`, `ProfileStore:1837-1871` | [01](parity-audit/01-profile-model.md) |
| 3 | AWS | **`AwsCredentialServer.SetCredentials` never called from any call site** — in-memory map permanently empty, signer pipeline disconnected | `AWSCredentialServer.swift`, `MitmEngine.swift:44` | [04](parity-audit/04-aws-sigv4.md) |
| 4 | AWS | **Vsock 8445 declared but no listener registered; `WriteCredentialProcessPayloadAsync` has zero call sites; guest helper script doesn't exist** | `AWSCredentialServer.swift` | [04](parity-audit/04-aws-sigv4.md) |
| 5 | AWS | **Real AWS secret written into the guest VM** via `SessionHomeBuilder.cs:113-121` — violates the entire fail-closed threat model | `AWSResigner.swift:11-13` | [04](parity-audit/04-aws-sigv4.md) |
| 6 | AWS | **SSO resolve + refresh loop never invoked at session start** — `SessionViewModel.StartAsync` never touches `_engine.AwsCreds` | `AWSSSOResolver.swift:86-113` | [04](parity-audit/04-aws-sigv4.md) |
| 7 | SSH | **SSH agent has no VM listener and no keys** — `MitmEngine.SshAgent` constructed but no hvsocket route to it, `SessionViewModel` never calls `SetKeys`. End-to-end dead. | `SSHAgent.swift` | [05](parity-audit/05-ssh-pki.md) |
| 8 | SSH | **`ExecCredentialPoller` missing** — every kubeconfig using an exec plugin (EKS / GKE / AKS default) silently 401s | `CloudCredentials.swift:451-551` | [05](parity-audit/05-ssh-pki.md) |
| 9 | SSH | **Client-cert + cluster-CA kubeconfig data dropped** — `KubeconfigMaterializer` returns them, `SessionViewModel.cs:228-244` only consumes the YAML | `KubeconfigImport.swift` | [05](parity-audit/05-ssh-pki.md) |
| 10 | SSH | **Imported SSH keys store plaintext PEM in profile JSON** + no passphrase keychain, no `importSSHKey` helper, no agent forwarding | `PrivateSSHAgent.swift`, `SSHAgent.swift:226-274` | [05](parity-audit/05-ssh-pki.md) |
| 11 | Cloud | **No CSR / leaf-cert issuance flow on Windows** — cloud uploader's mTLS handshake will fail every batch | `Enrollment.swift` | [06](parity-audit/06-trace-vault-mcp-cloud-enroll.md) |
| 12 | Cloud | **Wrong enrollment URL** (`/api/agentic-coding/enroll` vs macOS `/v1/enroll`) + missing `installPubkey` field — server-side enrollment will reject Windows | `Enrollment.swift` | [06](parity-audit/06-trace-vault-mcp-cloud-enroll.md) |
| 13 | Cloud | **Trace bodies stored unencrypted on disk** — `SecretsVault` (`IBodyEncryptor`) constructed but never passed to `TraceStore`; falls through to plaintext bytes | `TraceStore.swift` | [06](parity-audit/06-trace-vault-mcp-cloud-enroll.md) |
| 14 | Subscription | **`SubscriptionTokenCoordinator` is dead code** — no `new SubscriptionTokenCoordinator(`, no `RegisterClaude(`, no callbacks invoked anywhere in `windows/`. Plus bridge uses named pipes that are unreachable from Linux, plus Python token agents missing from guest image | `SubscriptionTokenCoordinator.swift`, `CodexTokenBridge.swift`, `SubscriptionTokenBridge.swift` | [07](parity-audit/07-subscription-automation.md) |
| 15 | UI | **Compromised-profile boot unblocked** — macOS refuses to launch a profile flagged compromised; Windows has no `SessionDisk.IsCompromised` gate, no wipe handler, no critical-alert UI | `BromureAC.swift:2011-2017, 2499-2554` | [08](parity-audit/08-ui-shell.md) |

---

## Per-subsystem summary

### 01 — Profile model + builders + imports (47 gaps; 8 critical)

Big-picture: ~20 fields on macOS `Profile.swift` have no equivalent on Windows `Profile.cs` — including `memoryGB`, `closeAction`, `networkMode`, `cursorShape`, `windowOpacity`, `keyboardLayoutOverride`, `customFontFamily/Size/Background/Foreground`, **`createdAt` / `lastUsedAt` / `baseImageVersionAtClone`** (this last one is the field that drives the image-versioning alert), `subscriptionTokenSwap` / `codexTokenSwap` consent state, `sshKeyRequiresApproval`. `ProfileSecrets` encryption split entirely missing — secrets are stored in plaintext JSON on disk. Stable per-profile MAC binding missing. Migration paths (legacy `folderPath` → `folderPaths`, inline secrets → `secrets.enc`) absent.

→ Full detail: [`parity-audit/01-profile-model.md`](parity-audit/01-profile-model.md)

### 02 — HTTP MITM proxy + WebSocket + RealtimeEventTap (12 gaps; 3 critical)

Subscription/Codex token-seen callbacks declared but never fired. RealtimeEventTap only logs, never emits cloud audit events. IPv6 listening not implemented. Cluster CA hostname-policy binding weaker on Windows. OAuth rotation rewriter is **enabled** on Windows but is **deliberately disabled** on macOS — divergence to audit before shipping.

→ Full detail: [`parity-audit/02-http-proxy.md`](parity-audit/02-http-proxy.md)

### 03 — Token swap + consent + OAuth rotation (17 gaps; 5 critical)

Aho-Corasick detector not rebuilt after OAuth-token rotation — stale scans miss leaks. DigitalOcean base64 pair (`base64("<tok>:<tok>")`) detection missing — naked token only. Subscription-token detection helpers (`detectSubscriptionAccessToken` / `detectCodexAccessToken`) entirely missing on Windows. Header end-of-frame off-by-4 means body sometimes truncated by upstream on body-mutating requests.

→ Full detail: [`parity-audit/03-token-swap.md`](parity-audit/03-token-swap.md)

### 04 — SigV4 + AWS resigner + credential server (22 gaps; 5 critical)

The SigV4 signer itself is byte-exact (passes AWS reference vector). Everything around it is broken: credentials never delivered to the server, vsock port never listened, SSO never resolved, real secrets handed to the guest. The Bedrock + S3 + ECR pipelines will not work as-shipped. See top-5 above.

→ Full detail: [`parity-audit/04-aws-sigv4.md`](parity-audit/04-aws-sigv4.md)

### 05 — SSH agent stack + Bromure CA + cert cache + cloud credentials (24 gaps; 6 critical)

The SSH agent is the worst-affected subsystem. End-to-end dead: no transport listener, no keys ever loaded into the server, no consent gate, no imported-key support, no passphrase storage, no host-agent forwarding for imported keys. K8s exec-plugin auth (EKS / GKE / AKS default) silently 401s because `ExecCredentialPoller` doesn't exist. Client-cert + cluster-CA kubeconfig auth completely broken because `SessionViewModel` drops the data. Two architectural wins on Windows: `BromureCa` uses DPAPI (safer than the macOS plaintext file), and `SSH_AGENTC_ADD_IDENTITY` is supported.

→ Full detail: [`parity-audit/05-ssh-pki.md`](parity-audit/05-ssh-pki.md)

### 06 — Trace + vault + MCP + cloud + enrollment (≈32 gaps; 4 critical)

Enrollment posts to the wrong URL, omits `installPubkey`, never sends a CSR — every cloud upload mTLS handshake will fail. Trace bodies stored unencrypted (`IBodyEncryptor` never wired). mTLS private key persists to user CAPI store (`%APPDATA%\Microsoft\Crypto\RSA`) — macOS keeps it in-memory only. No `/heartbeat` ping, no `unenroll()` flow, no `enroll` / `unenroll` / `status` CLI subcommands. MCP `get_profile_setting` supported-keys drifted; MCP debug tools (`vm_exec`, `read_file`, `write_file`) absent.

→ Full detail: [`parity-audit/06-trace-vault-mcp-cloud-enroll.md`](parity-audit/06-trace-vault-mcp-cloud-enroll.md)

### 07 — Subscription tokens + automation (24 gaps; 8 critical)

The subscription/Codex token-swap pipeline is **non-functional end-to-end**. Classes exist but the graph is unreachable. Bridges use named pipes (`\\.\pipe\bromure-ac-vsock-…`) which Linux can't dial — needs hvsocket. Python token agents not even shipped in the Windows guest setup. Wire format adds an `id` field the Python agent doesn't echo. `SeedClaudeAsync` writes fakes to the VM **before** registering the swap map — exact race macOS comments warn against. AutomationServer is always-on (no `automation.enabled` gate, security regression vs macOS default-off).

→ Full detail: [`parity-audit/07-subscription-automation.md`](parity-audit/07-subscription-automation.md)

### 08 — UI shell + main app state machine (36 gaps; 2 critical, 15 high)

`BromureAC.swift` is 3492 LOC on macOS; the WPF shell is a fraction of that. Compromised-profile boot gate missing. **No menu bar at all** — About, Check for Updates, Enroll, Preferences, Rebuild Base, Trace Inspector, Credential Approvals, Hide all unreachable. **Zero keyboard shortcuts** (Ctrl+N, Ctrl+W, Ctrl+1..9, Ctrl+, Ctrl+Shift+I — all missing; macOS has a sophisticated `NSEvent.addLocalMonitorForEvents` interceptor). Drift-detection prompt when `baseImageVersionAtClone` differs absent (this is the user's headline example). Restart-required prompts on profile field change absent (macOS has 19 `RestartChange` categories). Single-instance enforcement missing. Exit-on-last-window kills running VMs. Sparkle/auto-updater absent. 8 `.lproj` localizations on macOS vs English-only on Windows.

→ Full detail: [`parity-audit/08-ui-shell.md`](parity-audit/08-ui-shell.md)

### 09 — Profile editor + ConversationView + approvals + trace inspector (48 gaps; 17 high)

**MCP server editor pane entirely absent** — model + builder + broker all exist, but `ProfilesView.xaml` has no MCP tab. Tier-1 feature unreachable. **No ConversationView surface** — `ConversationParser.cs` is ported with tests but no UI consumer renders chat bubbles / tool_use blocks / system prompt. **Trace inspector has no request/response body rendering, no copy button, no filters**. **Appearance + Resources panes entirely missing** (memory stepper, NAT/Bridged toggle, three-layer storage stack with "Erase home"/"Reset to base", font/cursor/colors/opacity). Delete-without-confirmation. Kubeconfig file import + cert/exec auth modes missing. AWS SSO discovery missing. Docker config.json import missing. Subscription token swap reset UI missing.

→ Full detail: [`parity-audit/09-editor-conversation-views.md`](parity-audit/09-editor-conversation-views.md)

### 10 — Image manager + session disk + session window + VM lifecycle (44 gaps; ≥3 critical)

**The user's headline example lives here.** macOS's 3-button NSAlert ("Reset and launch" / "Launch as-is" / "Cancel") at `BromureAC.swift:2019-2041` has no Windows counterpart. Worse, `VhdxDisk.cs:65-72` *silently deletes and recreates* the per-profile child VHDX whenever the parent VHDX is newer — forced data wipe, no choice. No `imageVersion` constant. No `base.version` stamp file. No `Profile.BaseImageVersionAtClone` field. No "stale base" nag at app launch. No rebuild-confirmation Settings command. Also missing: per-profile persistent MAC + machine identifier (HCS resume depends on file path alone); compromise flag + boot-time refuse + wipe + picker badge (entire security feature absent); profile-driven RAM and NAT/Bridged toggle (Windows hardcodes 2 GB); outbox event channel pieces (URL relay, 5s IP refresh, `tabs-alive.txt` reconciliation, `closed-<uuid>.txt` exit signal).

The HCS engine itself is mid-pivot but structurally close to macOS. The 5 critical gaps above are bounded edits — the alert flow needs a ~1-line stamp + ~3-property profile field + ~20-line MessageBox at `SessionsViewModel.LaunchAsync` + the `VhdxDisk` mtime check made opt-in.

→ Full detail: [`parity-audit/10-image-session-vm.md`](parity-audit/10-image-session-vm.md)

---

## Cross-cutting patterns

Several gap categories repeat across subsystems and should be tackled as themes rather than one-off fixes:

### Pattern A: "Wired but disconnected"
Classes are ported, tests pass in isolation, but the class is **never instantiated or called** by any production code path. This is the #1 type of critical gap in the audit. Examples:
- `AwsCredentialServer.SetCredentials` (§4)
- `SubscriptionTokenCoordinator.RegisterClaude` (§7)
- `MitmEngine.SshAgent.SetKeys` (§5)
- `SubscriptionTokenSeen` / `CodexTokenSeen` callbacks (§2, §7)
- `WriteCredentialProcessPayloadAsync` (§4)
- `ExecCredentialPoller` — class doesn't even exist (§5)
- `SecretsVault` constructed but `TraceStore` never given it as `IBodyEncryptor` (§6)
- `KubeconfigMaterializer.ClientIdentities` / `.ClusterCas` returned but `SessionViewModel` drops them (§5)
- `AwsSsoResolver.StartRefreshLoopAsync` never started at session start (§4)

**Why this happens**: the Windows port was built bottom-up (ports of leaf classes first, with tests), but the top-level glue in `App.xaml.cs` / `ShellViewModel` / `SessionViewModel` was never finished. Fix is to do an integration sweep where every public method on every Mitm/Cloud/Engine class is grepped for at least one production call site outside its own tests.

### Pattern B: Secrets-at-rest unencrypted
Three independent subsystems write secrets to disk without encryption that macOS encrypts:
- `Profile.json` — all credentials inline (§1)
- `TraceStore` body files — `IBodyEncryptor` not wired (§6)
- `ImportedSshKey.PrivateKeyPem` — plaintext field in profile JSON (§5)

Plus mTLS private key persists to `%APPDATA%\Microsoft\Crypto\RSA` instead of in-memory (§6).

**Theme fix**: implement the DPAPI-backed `ISecretStore` and wire it everywhere `Keychain` is used on macOS. Then audit every `File.Write`/`File.WriteAllText` call site for unencrypted secret material.

### Pattern C: Profile-field-driven behavior hardcoded
Several Windows code paths hardcode values that on macOS come from `Profile`. Examples: RAM (2 GB), network mode (NAT only), kitty font size (28pt), cursor shape (block), scroll direction (positive). The fix is two-stage: (1) add the missing fields to `Profile.cs`, (2) thread them through the relevant builder / VM-config path.

### Pattern D: Transport mismatch
Windows uses Windows-Named-Pipes in places where Linux/VM needs to dial in (hvsocket). Affects subscription token bridge (§7), and probably AWS credential vsock (§4) and SSH agent (§5). The right answer is an `HvSocketTcpBridge` shared across all three.

### Pattern E: UI surface gaps with backing model present
`McpServer`, `ConversationParser`, `ProfileColor`, several token-swap states, etc. — code paths exist but no XAML surface renders them. ProfileEditorWindow and TraceInspectorView are particularly thin compared to their SwiftUI counterparts. The right fix is to tile out the missing tabs/panes from the SwiftUI mockups (ProfileViews.swift is 3496 LOC of literal layout).

### Pattern F: Localization
8 `.lproj` directories on macOS (de / en / es / fr / ja / pt / zh-Hans / zh-Hant) vs English-only on Windows. Translation tables aren't ported. Note that `ProfileViews.swift` and `BromureAC.swift` use `String(localized:)` heavily — every visible string. The `.resw` infrastructure is documented as pending in `windows/README.md`.

---

## Suggested remediation order

If the goal is "ship a Windows build that's functionally equivalent to macOS," tackle the 15 critical gaps in this order:

**Week 1 — Wire the disconnected classes (cheapest, highest impact)**
- `AwsCredentialServer.SetCredentials` call site at session start (§4)
- `MitmEngine.SshAgent.SetKeys` at session start; route hvsocket to it (§5)
- `SubscriptionTokenCoordinator` registration + bridge transport swap to hvsocket (§7)
- `IBodyEncryptor` passed to `TraceStore` (§6)
- `SessionViewModel` consumes `KubeconfigMaterializer.ClientIdentities` / `.ClusterCas` (§5)
- `SubscriptionTokenSeen` / `CodexTokenSeen` callbacks fired from proxy hook (§2, §7)

**Week 2 — Image versioning + compromise gate (security + the user's headline example)**
- Add `Profile.BaseImageVersionAtClone` (§1, §8, §10)
- Add `imageVersion` constant + `base.version` stamp file (§10)
- Add `SessionDisk.IsCompromised` flag + `BromureAC.swift:2011-2017` boot gate equivalent (§8, §10)
- Replace silent VhdxDisk wipe with a 3-button MessageBox (§10)

**Week 3 — Enrollment + CSR + heartbeat + secrets-at-rest**
- Fix enrollment URL + `installPubkey` + CSR flow (§6)
- mTLS private key in-memory only (§6)
- Implement `ISecretStore` (DPAPI) and split `ProfileSecrets` out of `profile.json` (§1)
- Plaintext `ImportedSshKey.PrivateKeyPem` → file-on-disk + passphrase via `ISecretStore` (§5)

**Week 4 — AWS guest helper + credential transport**
- Vsock 8445 listener + credential_process helper script in guest image (§4)
- Stop writing real `aws_secret_access_key` into `.aws/credentials` (§4)
- Wire `AwsSsoResolver.StartRefreshLoopAsync` to session start (§4)
- Install `ExecCredentialPoller` for K8s exec plugins (§5)

**Week 5 — UI/UX gap closure**
- Menu bar + keyboard shortcuts (§8)
- MCP editor pane (§9)
- ConversationView UI (§9)
- Trace inspector body rendering + filters (§9)
- Appearance + Resources profile panes (§9)
- Single-instance enforcement + "exit on last window" handling + Sparkle equivalent (§8)

The remaining ~165 medium / low gaps can be picked off opportunistically; the per-section files have file:line references for each.

---

## Reproducing this audit

```powershell
# Walk the existing file-level parity check first (the AC tree is anchored)
pwsh windows/scripts/check-parity.ps1 -Verbose

# Section files (open each for the per-finding detail):
ls windows/parity-audit/
```

The 10 section files cover ~280 KB of detail with file:line references for every finding.

When a finding is fixed, update the corresponding section file (move the row to a "Closed" section or strike it through), then re-audit. When a feature is intentionally not going to be ported, add it to `windows/PARITY_IGNORE` with a one-line reason — the file-level parity script will then skip it.
