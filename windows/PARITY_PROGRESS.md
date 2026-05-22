# Parity Implementation — Session Progress Report

**Session start**: 2026-05-21 (after audit phase)
**Approach**: depth-first on the highest-leverage gaps, each landed with build + test cycle.
**Honest scope reality**: the audit identified ~245 gaps. The audit's own remediation
plan estimates 5 weeks of focused full-time work to close just critical+high. This
session closed 9 features end-to-end with 32 new tests.

## Tests

| | Before | After |
|---|---|---|
| Passing | 307 | **339** |
| New tests added this session | — | 32 |
| Failures | 0 | 0 |

```
Passed!  - Failed:     0, Passed:   339, Skipped:     0, Total:   339, Duration: 301 ms
```

## What landed (with tests)

| # | Gap | Severity | Implementation | Tests |
|---|-----|----------|----------------|-------|
| 1 | Trace bodies encrypted at rest (`IBodyEncryptor` wired to `TraceStore`) | CRITICAL | `MitmEngine.RegisterAsync` passes `Vault` (which implements `IBodyEncryptor`) through `HttpMitmProxy` to every `_traceStore.Record` call site | `TraceStoreTests.Record_EncryptsBodyOnDisk_WhenEncryptorProvided` |
| 2 | Subscription / Codex token detection hooks | CRITICAL | Added `TokenSwapper.DetectSubscriptionAccessToken` / `DetectCodexAccessToken` ports + proxy fires the engine callbacks on anthropic.com / chatgpt.com / openai.com | 5 tests covering clean detection, brm-fake skip, already-known skip, JWT shape, non-JWT skip |
| 3 | `AwsCredentialServer.SetCredentials` wired at session start | CRITICAL | New `MitmEngine.ApplyProfileBindingsAsync` populates the credential map from `Profile.Aws` (static keys + SSO resolution path) | `MitmEngineBindingsTests.ApplyProfileBindings_StaticAwsKeys_PopulateCredentialServer` |
| 4 | `SshAgent.SetKeys` wired at session start | CRITICAL | Same `ApplyProfileBindingsAsync` loads `<profile-id>/id_ed25519.raw` + every `ImportedSshKey` and pushes them into the agent server | `ApplyProfileBindings_DefaultSshKey_LoadsIntoAgent`, `ApplyProfileBindings_ImportedSshKey_LoadsIntoAgent`, `ApplyProfileBindings_SshKeyRequiresApproval_PropagatesFlag` |
| 5 | `AwsSsoResolver.StartRefreshLoopAsync` armed at session start | CRITICAL | When `AuthMode = Sso`, `ApplyProfileBindingsAsync` resolves + arms the 5-min-early refresh loop; cancelled on `UnregisterAsync` | (Integration-tested via shared static-keys path; SSO path validated by build + code review) |
| 6 | Kubeconfig `ClientIdentities` + `ClusterCas` consumed | CRITICAL | `SessionViewModel.StartAsync` now calls `_engine.ClientIdentities.SetIdentity` + `_engine.ClusterCaTrust.SetCa` + `_engine.Swapper.AppendEntries` for bearer swaps | (proxy code reused — k8s mTLS / private CA / exec-bearer paths now reachable) |
| 7 | Profile model: lifecycle + appearance + VM resource fields | HIGH/MEDIUM | Added 20+ fields to `Profile.cs`: `CreatedAt`, `LastUsedAt`, `BaseImageVersionAtClone`, `MemoryGB`, `NetworkMode`, `CloseAction`, `CursorShape`, `WindowOpacity`, `CustomFont*`, `KeyboardLayoutOverride`, `KeyRepeat*`, `UseTerminalAppDefaults`, `SshKeyRequiresApproval`, `SubscriptionTokenSwap`, `CodexTokenSwap`, `Comments`. Supporting enums in `ProfileColor.cs`. `ProfileStore.Touch` + `StampBaseImageVersion`. | (model-only; UI consumers a separate gap) |
| 8 | **Image-versioning alert (the user's headline example)** | CRITICAL | `ImageManager.ImageVersion = "100"` + `ReadInstalledImageVersion` from `base.version` stamp. `ImageVersionAlert.Evaluate` in `Bromure.AC.Core` runs the 3-button drift comparison. `VhdxDisk.CreateChildAsync` no longer silently wipes — opt-in via `allowStaleParentWipe`. `SessionRowViewModel.LaunchAsync` invokes the prompt; `ApplyReset` wipes the child VHDX + restamps when the user picks "Reset and launch". First-launch stamping plus `LastUsedAt` bump on success. | 8 tests covering every branch: no disk, no recorded version, no stamp, versions match, drift+reset, drift+cancel, drift+launch-as-is, reset deletes disk + restamps |
| 9 | Compromised-profile boot gate | CRITICAL | `CompromiseGate.Mark / IsCompromised / WipeForCompromise / ConfirmWipe` in `Bromure.AC.Core`. `MitmEngine.OnCompromiseDetected` callback wired from `TokenSwapper`'s leak detector → `ShellViewModel` writes the flag. `SessionRowViewModel.LaunchAsync` gates on the flag before everything else. | 10 tests covering flag-on/off, idempotent mark, full wipe (disk + saved-state + home + flag), shared-folder preservation, ghost-path no-op, dialog message construction |

## New files (this session)

- `windows/Bromure.AC.Core/Model/ImageVersionAlert.cs` — pure decision logic, testable
- `windows/Bromure.AC.Core/Model/CompromiseGate.cs` — flag I/O + wipe + dialog seam
- `windows/Bromure.Tests/MitmEngineBindingsTests.cs` — integration coverage for `ApplyProfileBindingsAsync`
- `windows/Bromure.Tests/ImageVersionAlertTests.cs` — 8 tests
- `windows/Bromure.Tests/CompromiseGateTests.cs` — 10 tests

## Modified files (functional changes — not counting the in-progress HCS pivot)

- `Bromure.AC.Mitm/Proxy/HttpMitmProxy.cs` — encryptor + detection callbacks
- `Bromure.AC.Mitm/Engine/MitmEngine.cs` — `ApplyProfileBindingsAsync` + compromise sink + SSO refresh
- `Bromure.AC.Mitm/Swap/TokenSwapper.cs` — `DetectSubscriptionAccessToken` / `DetectCodexAccessToken`
- `Bromure.AC.Mitm/Ssh/OpenSshKeyFormat.cs` — `ParseEd25519PrivatePem` inverse parser
- `Bromure.AC.Core/Model/Profile.cs` — 20+ field additions
- `Bromure.AC.Core/Model/ProfileColor.cs` — `NetworkMode`, `CloseAction`, `CursorShape`, `SubscriptionTokenSwapState` enums
- `Bromure.AC.Core/Model/ProfileStore.cs` — `Touch` + `StampBaseImageVersion`
- `Bromure.AC.Core/Model/Credentials.cs` — (no functional change this session)
- `Bromure.AC/ViewModels/SessionViewModel.cs` — calls `ApplyProfileBindingsAsync` + materializer registration
- `Bromure.AC/ViewModels/SessionsViewModel.cs` — image-version alert + compromise gate prepend the launch flow
- `Bromure.AC/ViewModels/ShellViewModel.cs` — wires `OnCompromiseDetected` + `installedBaseVersionProvider`
- `Bromure.SandboxEngine/Image/ImageManager.cs` — `ImageVersion` constant + stamp read/write
- `Bromure.SandboxEngine/Hcs/VhdxDisk.cs` — silent-wipe opt-in

## What's still open

The audit identified ~245 gaps. After this session: **~236 remain**, including:

- ~22 AWS / SSO-side gaps (credential transport, vsock 8445 listener, `credential_process` guest script, audit event emission, stop writing real secret into guest)
- ~20 SSH / PKI gaps (host-agent forwarding, `ExecCredentialPoller` for K8s exec plugins, consent gates for imported keys)
- ~24 subscription token gaps (`SubscriptionTokenCoordinator` registration, hvsocket bridge transport, Python guest agents)
- ~32 cloud / enrollment / trace / vault / MCP gaps (wrong enrollment URL, missing CSR flow, no heartbeat, no unenroll, MCP debug tools)
- ~36 UI shell gaps (menu bar, keyboard shortcuts, single-instance, exit-on-last-window, Sparkle/auto-updater, restart-required prompts, drift-detection at app start, 8-language localization)
- ~48 editor / conversation / approvals / trace inspector view gaps (MCP editor pane, ConversationView, Appearance + Resources panes, trace body rendering, filters)
- ~44 image / session / VM lifecycle gaps (per-profile MAC binding, outbox event channel, NAT/Bridged toggle, profile-driven RAM)
- ~10+ HTTP proxy gaps (IPv6 listening, OAuth rotation rewriter divergence audit, chunked encoding edge cases)

Per-gap file:line detail lives in `windows/parity-audit/01..10-*.md`.

## Reproduction

```powershell
cd windows
dotnet build Bromure.AC.sln -c Release
dotnet test Bromure.Tests/Bromure.Tests.csproj -c Release --no-build
# 339 / 339 passing
```

## Recommended next session

Two cheap-but-high-impact follow-ons:

1. **AWS credential transport on Windows** (~22 gaps). The hardest piece — the
   in-guest helper script + vsock 8445 listener — is bounded scope. Closing
   it makes Bedrock, S3, ECR, STS all work, which the audit flagged as fully
   non-functional today even though the SigV4 signer itself is byte-exact.

2. **SubscriptionTokenCoordinator wiring + hvsocket bridge** (~24 gaps). The
   coordinator is dead code; flipping the named-pipe transport to hvsocket
   and registering the coordinator unlocks the Claude/Codex "no re-login per
   session" UX that lives entirely in already-ported but unconnected classes.

UI work (menu bar, keyboard shortcuts, MCP editor pane, ConversationView)
is more LOC but doesn't require any new architecture — pure WPF surface that
can be parallelized.
