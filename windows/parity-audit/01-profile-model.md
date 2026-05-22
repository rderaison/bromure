# Parity Audit: Profile Model + Persistence + Builders + Imports

**Scope**: macOS `Profile.swift`, AWS/Docker/Kubeconfig/Terminal imports vs Windows `Bromure.AC.Core/Model/*` + `Bromure.AC.Core/Imports/*`.

## Findings Summary — 47 gaps

| Severity | Count |
|----------|-------|
| CRITICAL (blocking launch) | 8 |
| HIGH (data loss / UX) | 9 |
| MEDIUM (feature incomplete) | 14 |
| LOW (edge cases) | 12 |
| DEFERRED (v1-noted) | 3 |
| ARCHITECTURAL | 1 |

## Top 5 Most Impactful Gaps

### 1. CRITICAL — Secrets Encryption Missing (ProfileSecrets split)
- **macOS**: Profile.swift:1353–1548 — extract secrets into JSON blob, AES-GCM encrypt to `secrets.enc` alongside plaintext `profile.json`.
- **Windows status**: MISSING entirely.
- **Impact**: All secrets (API keys, tokens, docker passwords, SSH keys, AWS secrets) are serialized in plaintext in profile JSON on disk — compliance/audit blocker. Comment in `ProfileStore.cs` says "Phase B+ moves to ISecretStore" but the split isn't implemented yet.

### 2. CRITICAL — Default OAuth Token Reuse Missing
- **macOS**: `defaultClaudeTokens` / `defaultCodexTokens` fields on Profile + `AWSSSOResolver.startRefreshLoop` (lines 86–113). Tokens captured after a successful login are auto-seeded on next session boot.
- **Windows status**: `StoredOAuthTokens` shape exists on `Profile.cs` but `savedAt` is missing; no subscription token reuse across sessions; SSO refresh loop is implemented but isn't wired into the session lifecycle.
- **Impact**: Users re-login to Claude/Codex on every session.

### 3. CRITICAL — Stable MAC Address Binding Missing
- **macOS**: `MACBindings` singleton + `profile-macs.json` (Profile.swift:1565–1638). Per-profile MAC persisted with NSLock-guarded concurrent access.
- **Windows status**: MISSING.
- **Impact**: Every session VM gets random MAC → DHCP leases thrash, breaking networking assumptions. Future-proof on macOS, not yet on Windows.

### 4. HIGH — Profile Lifecycle Metadata Missing
- **macOS**: `createdAt`, `lastUsedAt`, `baseImageVersionAtClone` (Profile.swift:870–876). `ProfileStore.touch()` updates on every session.
- **Windows status**: MISSING from `Profile.cs`.
- **Impact**: No "last used X ago" sorting, no base-image staleness detection, no profile-age UI. **This is also where the user's "image versioning alert" lives — when `baseImageVersionAtClone` ≠ current image, macOS surfaces an alert.**

### 5. HIGH — Terminal Theme Inheritance Missing
- **macOS**: `useTerminalAppDefaults`, `customFontFamily`, `customFontSize`, `customBackgroundHex`, `customForegroundHex` + `resolveStyle()` helper (Profile.swift:989–993, 1320–1329) + `TerminalAppDefaults.seedAppearance` (236–246).
- **Windows status**: `KittyConfigBuilder` uses hardcoded defaults only; no `TerminalDefaults` integration, no profile-level overrides.
- **Impact**: No visual continuity from user's terminal theme.

---

## Detailed Gaps by Category

### A. Profile Data Model (`Profile.cs`)

| Feature | macOS Source | Windows | Detail |
|---------|--------------|---------|--------|
| `memoryGB` | Profile:889–902 | MISSING | Int + `defaultMemoryGB()` scaling helper. |
| `closeAction` | Profile:907–923 | MISSING | Enum (suspend/shutdown/ask). |
| `networkMode` | Profile:925–939 | MISSING | Enum (nat/bridged) + `bridgedInterfaceID`. |
| `cursorShape` | Profile:945–954 | MISSING | Enum (block/beam/underline) passed to kitty. |
| `windowOpacity` | Profile:978 | MISSING | Double 0.3–1.0, applied to kitty + window alpha. |
| `keyboardLayoutOverride` | Profile:963 | MISSING | XKB layout pin (default nil = live sync from host). |
| `keyRepeatDelayMs` / `keyRepeatRateHz` | Profile:971–972 | MISSING | `xset r rate` overrides. |
| `useTerminalAppDefaults` | Profile:989 | MISSING | Bool to seed custom* fields from host terminal. |
| `customFontFamily` | Profile:990 | MISSING | String?. |
| `customFontSize` | Profile:991 | MISSING | Int?. |
| `customBackgroundHex` | Profile:992 | MISSING | Hex. |
| `customForegroundHex` | Profile:993 | MISSING | Hex. |
| `baseImageVersionAtClone` | Profile:876 | MISSING | String? — captured at clone, drives stale-image alert. |
| `createdAt` | Profile:870 | MISSING | Date — "newest first" sort. |
| `lastUsedAt` | Profile:871 | MISSING | Date? — "last used" UI + sort. |
| `subscriptionTokenSwap` | Profile:805 | MISSING | Enum (unset/accepted/declined) — Claude OAuth swap consent. |
| `codexTokenSwap` | Profile:812 | MISSING | Enum — Codex/ChatGPT swap consent. |
| `defaultClaudeTokens` | Profile:821 | PARTIAL | Field exists but `savedAt` timestamp missing. |
| `defaultCodexTokens` | Profile:825 | PARTIAL | Same. |
| `sshKeyRequiresApproval` | Profile:868 | MISSING | Per-sign consent gate for auto-generated SSH key. |

### B. Credentials Data Model (`Credentials.cs`)

| Feature | macOS | Windows | Detail |
|---------|-------|---------|--------|
| `ManualToken.realValue` | Profile:207 | PARTIAL | Windows field is `Value` — semantic drift. |
| `ImportedSSHKey.filename` | ImportedSSHKey:148 | DIFFERENT | macOS persists encrypted PEM under `profiles/<id>/agent/imported/`; Windows stores `PrivateKeyPem` inline plaintext. |
| `ImportedSSHKey.publicKeyText` | ImportedSSHKey:151 | MISSING | Pub-key cached at import for editor display. |
| `ImportedSSHKey.hasPassphrase` | ImportedSSHKey:153 | MISSING | Bool; macOS stores actual passphrase in Keychain. |
| `EnvironmentVariable.isSecret` | Credentials.cs:63 | ADDED on Windows | Not in macOS — Windows-only per-row mask flag. |
| `StoredOAuthTokens.savedAt` | Profile:1342 | MISSING | Date timestamp. |

### C. KubeconfigEntry Shape Mismatch

- macOS: Codable struct with Swift enum `Auth` (associated values: `bearerToken(String)`, `clientCert(certPEM:, keyPEM:)`, `execPlugin(command:, args:, refreshSeconds:)`).
- Windows: record + sealed subclasses (`BearerTokenAuth`, `ClientCertAuth`, `ExecPluginAuth`).
- JSON discriminator "kind" matches in both, but `KubeconfigImport.parse()` on Windows doesn't generate IDs — caller responsibility. macOS auto-assigns UUIDs.

### D. Profile Persistence (`ProfileStore`)

| Feature | macOS | Windows | Detail |
|---------|-------|---------|--------|
| Secrets encryption | ProfileStore:1837–1871 + SecretsVault | MISSING | Atomic write of plaintext `profile.json` + AES-GCM(secrets).enc (chmod 600), NSLock-guarded. **Critical data security gap.** |
| MAC address binding | MACBindings singleton:1565–1638 | MISSING | Per-profile stable MAC. |
| Template profile UUID | ProfileStore:1683–1712 | uses `Guid.Empty` | macOS uses `BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB`. Schema mismatch if profiles cross-sync. |
| Legacy `folderPath` migration | Profile decoder:1139–1148 | MISSING | macOS migrates single → array. |
| Inline secrets → encrypted migration | ProfileStore:1791–1812 | MISSING | macOS auto-detects + migrates. |
| Home directory layout | ProfileStore:1768–1775 | No equivalent | macOS mounts persistent `~/home/` virtiofs overlay. |
| SSH key directory migration | ProfileStore:2405–2410 | No equivalent | macOS moves legacy `ssh/` → `.ssh/` in home mount. |

### E. Builders (Kitty, MCP, SessionHome, AWS)

| Feature | macOS | Windows | Detail |
|---------|-------|---------|--------|
| Kitty font scaling | TerminalAppDefaults.kittyConfig:104–110 | KittyConfigBuilder.Build | macOS scales Terminal.app 12pt × 1.5 → 18pt (empirical 96 DPI match). Windows hardcodes 28pt; no Terminal integration. |
| Kitty keybinding contention | TerminalAppDefaults:185–195 | MISSING | macOS disables kitty `super+t/w/...` so NSWindow tabs win. Windows hardcodes ctrl+c/v; no `discard_event` context. |
| Kitty scroll direction | TerminalAppDefaults.scrollDirectionStanza:210–222 | MISSING | macOS reads `com.apple.swipescrolldirection`; Windows hardcodes positive. |
| Tab bar styling | hidden by macOS | shown by Windows | Opposite UX intent — Windows shows kitty tab bar tinted by profile color. |
| Docker Hub canonicalization | DockerConfigImport:106–130 | SessionHomeBuilder:247–256 | Identical (`docker.io` → `https://index.docker.io/v1/`). ✓ |
| Git credential helpers | SessionDisk:2208–2231 | SessionHomeBuilder.BuildGitConfig:156–173 | Both write `credential.helper=store`; both emit per-host gh/glab YAML. ✓ |
| MCP token injection | macOS Profile.mcpServers w/ broker refresh | Windows McpConfigBuilder | Windows has `OAuthState` field but **no refresh loop**. |

### F. Import Logic

| Feature | macOS | Windows | Detail |
|---------|-------|---------|--------|
| AWS SSO token cache scan | AWSSSOResolver:117–168 | AwsSsoResolver:98–138 | SHA1 hash lookup + session-name fallback + content scan. ✓ |
| AWS SSO login | AWSSSOResolver.runSSOLogin:203–229 | AwsSsoResolver.RunSsoLoginAsync:180–197 | Both call `aws sso login --profile`. ✓ |
| AWS credential refresh loop | AWSSSOResolver.startRefreshLoop:86–113 | AwsSsoResolver.StartRefreshLoopAsync:64–94 | Same 5-min-early refresh; **not wired into Windows session lifecycle yet**. |
| Kubeconfig auth parsing | KubeconfigImport:98–117 | KubeconfigImport:112–142 | Identical. ✓ |
| Docker config import | DockerConfigImport:40–86 | DockerConfigImport:24–70 | Identical. ✓ |
| Terminal.app defaults | TerminalAppDefaults.load:26–56 (plist) | TerminalDefaults.Load (JSON) | Different sources, same intent. Looks complete. ✓ |
| SSH key import builder | (implicit) | MISSING | macOS persists imported keys to disk + Keychain. Windows stores PEM inline; no import UI. |

### G. Validation Helpers

| Feature | macOS | Windows | Detail |
|---------|-------|---------|--------|
| `Profile.resolveStyle()` | Profile:1320–1329 | MISSING | Resolves custom font/color fields against TerminalAppDefaults w/ fallback. |
| `ManualToken.isUsable` | Profile:232–234 | MISSING | `!realValue.isEmpty` check. |
| `GitHTTPSCredential.isUsable` | Profile:286–290 | MISSING | host/username/token non-empty + trim. |
| `DockerRegistryCredential.isUsable` | Profile:353–357 | MISSING | host/username/password check. |
| `AWSCredentials.isUsable` | Profile:448–456 | MISSING | authMode-aware. |
| `MCPServer.isUsable` | Profile:606–612 | McpServer:64–76 | ✓ Present. |
| `EnvironmentVariable.isValidName()` | Profile:519–526 | MISSING | POSIX env-var name validator. |

### H. Architectural

| Area | macOS | Windows | Impact |
|------|-------|---------|--------|
| Secrets vault backend | Keychain + AES-GCM `SecretsVault` | Phase-B placeholder | Windows inlines secrets in JSON — regulatory/audit risk. Needs DPAPI-backed Secret Store. |
| Session metadata share | virtiofs `bromure-meta/` + `bromure-outbox/` runtime mount | ISO-based provisioning | Less flexible for mid-session updates. |
| Token swapping (fakes) | `SessionTokenPlan` HKDF-derived fakes substituted in VM secrets | "Real tokens in ISO" v1 | Credential exposure if VM is compromised. |

---

## Summary

47 gaps total. The biggest items are:
1. Secrets at rest are unencrypted on Windows.
2. OAuth refresh tokens / default tokens not reused → re-login every session.
3. Stable per-profile MAC missing → DHCP churn.
4. No `lastUsedAt` / `createdAt` / `baseImageVersionAtClone` metadata → no "last used" UX, no stale-image alert (this is where the user's example feature lives).
5. Kitty/terminal customization not parameterized — hardcoded.
