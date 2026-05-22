# Parity Audit 07 — Subscription / Codex Token Bridges, SubscriptionTokenCoordinator, AutomationServer, ScriptCommands

Scope: end-to-end subscription token swap (Claude + Codex) lifecycle on Windows, plus the AC automation surface (`bromure-ac` HTTP/MCP). Authoritative source = macOS Swift.

## Source map

| macOS file | LOC | Windows counterpart | LOC | Status |
|---|---|---|---|---|
| `Sources/AgentCoding/SubscriptionTokenBridge.swift` | 198 | `windows/Bromure.SandboxEngine/Vsock/SubscriptionTokenBridge.cs` | 178 | PARTIAL (transport + framing OK, not wired into VM lifecycle) |
| `Sources/AgentCoding/CodexTokenBridge.swift` | 175 | `windows/Bromure.SandboxEngine/Vsock/CodexTokenBridge.cs` | 156 | PARTIAL (same as above) |
| `Sources/AgentCoding/SubscriptionTokenCoordinator.swift` | 700 | `windows/Bromure.AC.Mitm/Engine/SubscriptionTokenCoordinator.cs` | 163 | DIFFERENT (only ~25% of behaviors; class never instantiated) |
| `Sources/AgentCoding/SubscriptionTokenSwapState.swift` | 19 | — | — | MISSING |
| `Sources/AgentCoding/SubscriptionTokenSwapSheet.swift` | 85 | — | — | MISSING (no consent UI) |
| `Sources/AgentCoding/AutomationServer.swift` | 447 | `windows/Bromure.AC/Automation/AutomationServer.cs` | 343 | PARTIAL (endpoints match for core, gating differs, exec shape diverged) |
| `Sources/AgentCoding/ScriptCommands.swift` | 422 | — | — | MISSING (AppleScript surface; partially substituted by extra HTTP endpoints on Win) |
| `Sources/AgentCoding/BromureAC.sdef` | 200+ | — | — | N/A (macOS-only) |

---

## 1. SubscriptionTokenBridge (Claude, vsock 8446)

### Feature: Bridge transport
- **macOS source**: `SubscriptionTokenBridge.swift:48–67` — `VZVirtioSocketDevice` + `VZVirtioSocketListener` on `forPort: 8446`. Real AF_VSOCK between VM and host via `Virtualization.framework`.
- **Windows status**: DIFFERENT
- **Detail**: `windows/Bromure.SandboxEngine/Vsock/VsockBridge.cs:41–54` uses **Windows Named Pipes** (`\\.\pipe\bromure-ac-vsock-8446`), NOT AF_HYPERV / hvsocket. The class is misleadingly named `VsockBridge` but never touches `HvSocket`. The in-VM agent would need to dial a named pipe — which is impossible from Linux. Impact: VM-side agents cannot connect; the host listener is unreachable in production. The bridge is currently usable only through host-side test harnesses (`TokenBridgeTests`).

### Feature: Wire format — newline-delimited JSON
- **macOS source**: `SubscriptionTokenBridge.swift:116–135` — sends `<json>\n`, no `id` field; response correlation is positional (FIFO queue).
- **Windows status**: DIFFERENT
- **Detail**: `SubscriptionTokenBridge.cs:132–152` adds an `id` field (monotonic `_idSeq`) and correlates responses by id. This is BETTER than macOS (no positional FIFO assumption) but it means the **Windows host is wire-incompatible with `claude-token-agent.py`** which does not echo an `id` (see `Sources/AgentCoding/Resources/vm-setup/claude-token-agent.py:34–35` and the upstream agent loop — there is no `id` round-trip on macOS). The test harness fakes the id round-trip; the real Python agent does not. Either the Python agent must be patched to echo `id`, OR the Windows bridge must fall back to positional matching.

### Feature: read() RPC
- **macOS source**: `SubscriptionTokenBridge.swift:86–97`
- **Windows status**: OK
- **Detail**: `SubscriptionTokenBridge.cs:103–115`. Both return `(access, refresh)` tuple or null. Same JSON shape (`{"op":"read"}` → `{"ok":bool,"access"?,"refresh"?}`).

### Feature: write() RPC + brm- prefix enforcement
- **macOS source**: `SubscriptionTokenBridge.swift:99–112`
- **Windows status**: OK on host wire
- **Detail**: `SubscriptionTokenBridge.cs:117–130`. Prefix shape enforcement is on the agent side (Python) on both platforms — the host just sends the value.

### Feature: Stop / cleanup
- **macOS source**: `SubscriptionTokenBridge.swift:68–79`
- **Windows status**: PARTIAL
- **Detail**: `SubscriptionTokenBridge.cs:154–166` (`DisposeAsync`). macOS also calls `socketDevice?.removeSocketListener(forPort:)` and unblocks pending continuations; Windows clears `_pending` but does NOT call `VsockBridge.StopListeningAsync(8446)` to tear down the listener, leaving the named-pipe server alive forever.

### Feature: Reconnect resilience
- **macOS source**: `SubscriptionTokenBridge.swift:154–168` — `setCancelHandler` failures the pending requests; the agent auto-reconnects every 2s.
- **Windows status**: PARTIAL
- **Detail**: `SubscriptionTokenBridge.cs:80–89` clears pending on disconnect but the Python agent's reconnect cadence is not exercised because the bridge is never reached.

---

## 2. CodexTokenBridge (Codex, vsock 8447)

Twin of SubscriptionTokenBridge with the three-token shape (`access`, `refresh`, `id_token`). All findings from §1 apply identically.

- **macOS source**: `CodexTokenBridge.swift:1–175`
- **Windows status**: PARTIAL — same transport mismatch (named pipe vs AF_VSOCK), same `id` field divergence, same not-wired-anywhere status. `CodexTokenBridge.cs:1–156`.

---

## 3. In-VM agents (claude-token-agent.py, codex-token-agent.py)

### Feature: In-VM agent shipped in guest image
- **macOS source**: `Sources/AgentCoding/Resources/vm-setup/claude-token-agent.py` + `codex-token-agent.py`, copied to `/mnt/bromure-meta/`, started by xinitrc. Connects to `HOST_CID=2` AF_VSOCK port 8446/8447.
- **Windows status**: MISSING
- **Detail**: Neither `windows/Bromure.SandboxEngine/Image/setup.sh` nor `setup-hcs.sh` installs `claude-token-agent.py` or `codex-token-agent.py`. The guest image has Claude Code + Codex installed (`npm install -g @anthropic-ai/claude-code`, `@openai/codex` — see setup.sh) but NO token agent. No xinitrc / systemd unit starts one. **The entire VM→host token-extraction channel is non-functional on Windows.** Even if the host bridge were wired and used AF_HYPERV, there is nothing in the guest to dial it.

---

## 4. SubscriptionTokenCoordinator

### Feature: Coordinator instantiation + wiring
- **macOS source**: `SubscriptionTokenCoordinator.swift:14–16` — `public static let shared = …` singleton, used from `BromureAC.swift` session-launch path.
- **Windows status**: MISSING (class exists but unreferenced)
- **Detail**: `windows/Bromure.AC.Mitm/Engine/SubscriptionTokenCoordinator.cs` defines the class. Grep across `windows/` finds zero `new SubscriptionTokenCoordinator(`, zero `RegisterClaude(`, zero `RegisterCodex(`, zero `HandleCleanClaudeAccessTokenAsync(` callers. `SessionViewModel.cs:160–328` (session boot) and `App.xaml.cs:16–31` (startup) never reference the coordinator. The class is dead code.

### Feature: Per-profile bridge registration
- **macOS source**: `SubscriptionTokenCoordinator.swift:38–44` — `register(profileID:, bridge:)` / `registerCodex(…)`.
- **Windows status**: PARTIAL
- **Detail**: `SubscriptionTokenCoordinator.cs:44–57` has `RegisterClaude/UnregisterClaude/RegisterCodex/UnregisterCodex`. Shape matches; but no caller exists.

### Feature: Auto-seed on fresh VM (template-derived defaults)
- **macOS source**: `SubscriptionTokenCoordinator.swift:52–207` — `autoSeedIfNeeded()`. Reads `profile.defaultClaudeTokens` / `defaultCodexTokens`, waits up to 60s for bridge, calls `bridge.read()` to skip if VM already has creds, derives fakes via `SessionTokenPlan.deriveFake` / `SubscriptionFakeMint`, registers swap entries for `api.anthropic.com`/`console.anthropic.com` (Claude) and `chatgpt.com`/`api.openai.com`/`auth.openai.com` (Codex) — including `acceptSiblings: true`, then writes fakes via `bridge.write()`.
- **Windows status**: MISSING
- **Detail**: No equivalent of `autoSeedIfNeeded` on Windows. `Profile.cs:97–98` carries `DefaultClaudeTokens` / `DefaultCodexTokens` but nothing consumes them at boot. Impact: even after a successful manual login, the user has to log in again every session — defeats the whole "save as default" UX.

### Feature: Subscription token detection hook (Anthropic)
- **macOS source**: `Mitm/HTTPProxy.swift:182–198` calls `swapper.detectSubscriptionAccessToken(in: rawRequest)` which fires `SubscriptionTokenCoordinator.shared.handleCleanAccessToken(...)`.
- **Windows status**: MISSING
- **Detail**: `MitmEngine.cs:78–80` declares `SubscriptionTokenSeen` / `CodexTokenSeen` callback properties but they are NEVER invoked. `TokenSwapper` has no `DetectSubscriptionAccessToken` / `DetectCodexAccessToken` method (confirmed by parity-audit/02 and 03). `SubscriptionTokenCoordinator.HandleCleanClaudeAccessTokenAsync` exists but has no caller. The user is never prompted on first OAuth outbound.

### Feature: Codex token detection hook (OpenAI/ChatGPT)
- **macOS source**: `SubscriptionTokenCoordinator.swift:337–354` — `handleCleanCodexAccessToken(_:)`. Wired via the proxy on `chatgpt.com`/`api.openai.com`.
- **Windows status**: MISSING
- **Detail**: Same as Claude — no detection, no callback fired.

### Feature: Per-(profile, provider) throttle
- **macOS source**: `SubscriptionTokenCoordinator.swift:30–34, 318–321, 343–344` — `askedClaude` / `askedCodex` sets. One sheet at a time per provider per profile.
- **Windows status**: PARTIAL (logic exists, never reachable)
- **Detail**: `SubscriptionTokenCoordinator.cs:35–36, 69–71` mirrors with `_askedClaude` / `_askedCodex` concurrent dicts. macOS removes entry on error to allow retry; Windows does not remove on `prompt.AskFirstSwapAsync` decline OR on later seed failure — once asked, **never re-asked**, even on transient failure. macOS retries on next outbound request after a swap exception (`SubscriptionTokenCoordinator.swift:450, 480`: `askedClaude.remove(profile.id)`).

### Feature: Consent sheet presentation
- **macOS source**: `SubscriptionTokenSwapSheet.swift:1–85` + `SubscriptionTokenCoordinator.swift:358–424` — SwiftUI NSWindow, three buttons (Swap / Not now / Never for this profile). Wired via `NSHostingView` on `@MainActor`.
- **Windows status**: MISSING
- **Detail**: `ISubscriptionConsentPrompt` interface exists (`SubscriptionTokenCoordinator.cs:153–156`) and a debug stub `AlwaysAllowSubscriptionPrompt` (lines 158–162) that returns `Task.FromResult(true)`. No WPF dialog implements `ISubscriptionConsentPrompt`. Even if wired, **the prompt is binary (allow/deny) — no "Not now" semantics**, so the macOS state of "asked this session, defer to next session" can't be expressed.

### Feature: SubscriptionTokenSwapState enum
- **macOS source**: `SubscriptionTokenSwapState.swift:15–19` — `unset` / `accepted` / `declined`.
- **Windows status**: MISSING
- **Detail**: No equivalent enum in `windows/Bromure.AC.Core/Model/`. `Profile.cs` has `DefaultClaudeTokens` / `DefaultCodexTokens` but no `SubscriptionTokenSwap` / `CodexTokenSwap` decision fields. The "Never for this profile" decision cannot be persisted on Windows. Already flagged in parity-audit/01-profile-model.md:66–67.

### Feature: persistClaude / persistCodex (write swap state to profile)
- **macOS source**: `SubscriptionTokenCoordinator.swift:542–556`
- **Windows status**: MISSING
- **Detail**: No persistence of swap decisions; tied to missing enum above.

### Feature: offerSaveAsDefault (NSAlert after successful swap)
- **macOS source**: `SubscriptionTokenCoordinator.swift:642–685` — modal asks the user if real tokens should be promoted to the template's `defaultClaudeTokens` / `defaultCodexTokens` so future profiles auto-seed.
- **Windows status**: MISSING
- **Detail**: No equivalent. The "save as default" UX path is absent. Users have no way to promote a one-time login into a profile template default — except by manually editing the template via Preferences.

### Feature: recordRotation (after OAuth refresh response rewrite)
- **macOS source**: `SubscriptionTokenCoordinator.swift:237–306` — called by `OAuthRotationRewriter` callers. Updates `profile.defaultClaudeTokens` / `defaultCodexTokens` when they were set; also rotates the template's defaults when the pre-rotation refresh token matches.
- **Windows status**: MISSING
- **Detail**: `MitmEngine.OAuthRotated` callback property exists (line 82) but has no callers. `OAuthRotationRewriter.cs` returns the new tokens but nothing persists them to the profile or template. Impact: after an OAuth refresh, the next session auto-seed (already missing — §4 autoSeed) would use stale tokens. Already flagged in parity-audit/02:13.

### Feature: resetSessionDecision (re-enable prompt from editor)
- **macOS source**: `SubscriptionTokenCoordinator.swift:224–227`
- **Windows status**: MISSING

### Feature: unregister on session teardown
- **macOS source**: `SubscriptionTokenCoordinator.swift:209–220` — closes sheet windows, stops bridges, clears asked sets.
- **Windows status**: PARTIAL — `UnregisterClaude` / `UnregisterCodex` clear asked sets and forget the bridge, but do NOT close any consent UI (because none exists) and do NOT call `bridge.DisposeAsync`. macOS calls `bridges[profileID]?.stop()`; Windows leaks the bridge.

### Feature: Salt scheme for fakes
- **macOS source**: `SubscriptionTokenCoordinator.swift:494–508, 578–590` — `"anthropic-oauth-access:<uuid>"`, `"anthropic-oauth-refresh:<uuid>"`, `"codex-oauth-access:<uuid>"`, `"codex-oauth-refresh:<uuid>"`, `"codex-oauth-id:<uuid>"`.
- **Windows status**: OK
- **Detail**: `SubscriptionTokenCoordinator.cs:98–127` uses the same five salt strings via `Encoding.UTF8.GetBytes($"…:{profileId:D}")`. Length matches.

### Feature: Swap entry set after read()
- **macOS source**: `SubscriptionTokenCoordinator.swift:514–528, 600–619` — both Claude and Codex register entries BEFORE writing fakes to the VM (to avoid 401 races).
- **Windows status**: PARTIAL
- **Detail**: `SubscriptionTokenCoordinator.cs:103–115` writes fakes FIRST then registers entries. **Inverted order — this introduces the exact race macOS comments call out.** macOS comment at line 511–514: "Register both swaps before we tell the VM to write fakes — otherwise an in-flight Claude API call could hit the proxy with the now-fake access token before the swap is live and get a 401." Windows reverses this.
- **Detail (Codex)**: `SubscriptionTokenCoordinator.cs:135–146` — same inversion. Additionally, Codex registers only 4 entries vs macOS's 6: missing `(fakeRefresh → chatgpt.com refresh body)` and `(fakeID → auth.openai.com)`. See macOS `:610–618`.

---

## 5. AutomationServer

### Feature: Transport, port, bind
- **macOS source**: `AutomationServer.swift:43–48` — `127.0.0.1:9223` default, HTTP over raw `Darwin.socket` BSD sockets.
- **Windows status**: OK
- **Detail**: `AutomationServer.cs:58–65` uses `HttpListener` bound to `http://127.0.0.1:9223/`. Default port and bind match. `HttpListener` requires URL ACL registration on Windows when not loopback — fine for `127.0.0.1`.

### Feature: Server lifecycle (opt-in via UserDefaults)
- **macOS source**: `BromureAC.swift:614–620` — server is OFF by default; gated on `defaults read io.bromure.agentic-coding automation.enabled` boolean. Users opt in.
- **Windows status**: DIFFERENT
- **Detail**: `ShellViewModel.cs:195` (`StartAutomationServer()`) is called unconditionally from the ctor. **No `automation.enabled` gate.** Server starts on every launch. Settings keys `automation.enabled`, `automation.port`, `automation.bindAddress` are not read from `ISettingsStore`. Security/footprint difference: Windows runs an open loopback HTTP API for any local process to call without the user knowing.

### Feature: Authentication
- **macOS source**: None — relies on loopback bind.
- **Windows status**: OK (same)
- **Detail**: Neither side has bearer tokens, mTLS, or per-request auth. Acceptable for loopback-only; would need rework for non-loopback bind.

### Feature: CORS
- **macOS source**: None.
- **Windows status**: OK (same).

### Feature: Endpoint — GET /health
- **macOS source**: `AutomationServer.swift:179–184`
- **Windows status**: OK
- **Detail**: Same payload shape `{status, service, debugEnabled}`.

### Feature: Endpoint — GET /profiles
- **macOS source**: `AutomationServer.swift:186–188`
- **Windows status**: OK
- **Detail**: Same wrapped-array shape `{profiles: [...]}`. Same field set (id/name/color/tool/authMode/mcpServerCount).

### Feature: Endpoint — GET /sessions
- **macOS source**: `AutomationServer.swift:190–192`
- **Windows status**: OK

### Feature: Endpoint — POST /sessions
- **macOS source**: `AutomationServer.swift:194–213` — `{profile: "<name-or-uuid>"}`, returns 201 with `AutomationSessionInfo`.
- **Windows status**: OK
- **Detail**: Same. Accepts both `profile` and `profileId` keys.

### Feature: Endpoint — GET /sessions/{id}
- **macOS source**: `AutomationServer.swift:251–258`
- **Windows status**: OK
- **Detail**: Same. ID matches `profileId` or `profileName`.

### Feature: Endpoint — DELETE /sessions/{id}
- **macOS source**: `AutomationServer.swift:259–273`
- **Windows status**: OK

### Feature: Endpoint — GET /app/state (debug-gated)
- **macOS source**: `AutomationServer.swift:215–222` — gated on `BROMURE_DEBUG_CLAUDE`.
- **Windows status**: OK (same gating)
- **Detail**: Payload differs in keys: macOS returns `locale/mainWindowOpen/editorOpen/profileCount/sessionCount/hasBaseImage`; Windows returns `phase/profileCount/sessionCount/hasBaseImage/windowVisible`. No `locale` (Windows can't introspect AppleLanguages), no `editorOpen` (Windows uses a single shell window). Acceptable platform divergence but tests that read specific keys will need a Windows-aware path.

### Feature: Endpoint — POST /sessions/{id}/exec (debug-gated)
- **macOS source**: `AutomationServer.swift:279–311` — uses `ACShellProxyConnection` over a vsock shell-agent, returns `{stdout, stderr, exitCode}`. Wire format: u32be length + JSON `{cmd, timeout}` ↔ `{stdout, stderr, exit_code}`. Waits up to 10s for shell connection.
- **Windows status**: DIFFERENT
- **Detail**: `AutomationServer.cs:172–193` calls `OnExecInSession(sid, cmd)` which goes through `GuestCommand.RunAndCollectAsync` (host-side hvsocket cmd-server). **Returns a single `output` string** instead of `{stdout, stderr, exitCode}`. Tests that expect the macOS schema will break. No timeout parameter accepted in the body.

### Feature: Endpoint — GET /profiles/{id}/json
- **macOS source**: NOT present in HTTP layer — reachable only via the AppleScript `get profile json` command.
- **Windows status**: ADDED on Windows (`AutomationServer.cs:229–236`).
- **Detail**: Windows extends the surface to compensate for missing AppleScript. Returns the raw JSON-serialized Profile blob. Pragmatic; acceptable.

### Feature: Endpoint — PUT /profiles/{id}/json
- **macOS source**: NOT present in HTTP layer.
- **Windows status**: ADDED (`AutomationServer.cs:238–248`).
- **Detail**: Body: `{json: "<encoded profile>"}`. Preserves id (matches macOS ScriptCommands `setProfileJSON` behavior). Acceptable substitute for AppleScript.

### Feature: Endpoint — GET /profiles/{id}/settings/{key}
- **macOS source**: NOT present in HTTP layer; AppleScript `get profile setting` instead.
- **Windows status**: ADDED (`AutomationServer.cs:251–260`).
- **Detail**: Returns `{value: ...}`. Set of supported keys is much smaller on Windows than macOS (see §6 below).

### Feature: Endpoint — PUT /profiles/{id}/settings/{key}
- **macOS source**: NOT present in HTTP layer.
- **Windows status**: ADDED (`AutomationServer.cs:261–268`).

### Feature: Endpoint — GET/SET app settings
- **macOS source**: AppleScript only (`ScriptCommands.swift:376–422` — keys: `automation.enabled`, `automation.port`, `automation.bindAddress`, `managed.serverURL`, `managed.acIngestURL`).
- **Windows status**: MISSING
- **Detail**: No `/app/settings/{key}` endpoints. No way to toggle `automation.enabled` from outside. Tests can't set `managed.serverURL` either. Set of app-wide settings keys is unreachable via the Windows automation surface.

### Feature: Endpoint — quit app
- **macOS source**: AppleScript `quit` (`BromureAC.sdef:6–8`).
- **Windows status**: MISSING
- **Detail**: No `/app/quit` endpoint. Tests can shut the app down only by killing the process.

### Feature: Endpoint — open/close editor / set editor category
- **macOS source**: AppleScript `open ac profile editor`, `close ac profile editor`, `select editor category` (`BromureAC.sdef:51–66`).
- **Windows status**: MISSING
- **Detail**: No HTTP equivalent for editor navigation. Screenshot tooling (`Tests/ac-e2e.mjs`) cannot drive the WPF profile editor remotely.

### Feature: Endpoint — get main/editor window IDs
- **macOS source**: AppleScript `get main window id`, `get editor window id` (`BromureAC.sdef:68–76`).
- **Windows status**: N/A (CGWindowID is macOS-only)
- **Detail**: Windows uses HWNDs, not CGWindowIDs. `SessionInfo.WindowId` is hardcoded to 0 in `ShellViewModel.cs:226`. Screenshot tooling that captures by window ID won't work on Windows.

### Feature: Response framing
- **macOS source**: `AutomationServer.swift:366–381` — `HTTP/1.1`, `Connection: close`, `Content-Type: application/json`, pretty-printed sorted-keys JSON.
- **Windows status**: PARTIAL
- **Detail**: `AutomationServer.cs:316–331` uses pretty-printed JSON but no `sorted keys` order — `JsonNode.ToJsonString` does not sort. Tests doing string-compare against macOS golden files will diff.

### Feature: Concurrent request handling
- **macOS source**: `AutomationServer.swift:118–121` — one request per dispatched global-queue task.
- **Windows status**: OK
- **Detail**: `AutomationServer.cs:90` uses `Task.Run` per accepted context.

### Feature: Idle / heartbeat
- **macOS source**: None — no keepalive, no heartbeat ping.
- **Windows status**: OK (same).

### Feature: Rate limiting
- **macOS source**: None.
- **Windows status**: OK (same).

---

## 6. ScriptCommands (AppleScript surface)

The macOS `sdef` defines 17 commands. Windows port these through HTTP endpoints (see §5) or omits them. Detailed mapping:

| macOS command | macOS handler | Windows path | Status |
|---|---|---|---|
| `quit` | NSQuitCommand | — | MISSING |
| `get app state` | `BromureACGetAppStateCommand` | `GET /app/state` (debug-gated) | OK with payload diff (see §5) |
| `list profiles` | `BromureACListProfilesCommand` | `GET /profiles` | OK |
| `create ac profile` | `BromureACCreateProfileCommand` | — | MISSING (no `POST /profiles`) |
| `delete ac profile` | `BromureACDeleteProfileCommand` | — | MISSING |
| `open profile manager` | `BromureACOpenProfileManagerCommand` | — | MISSING |
| `open ac profile editor` | `BromureACOpenProfileEditorCommand` | — | MISSING |
| `close ac profile editor` | `BromureACCloseProfileEditorCommand` | — | MISSING |
| `select editor category` | `BromureACSelectEditorCategoryCommand` | — | MISSING |
| `get editor window id` | `BromureACGetEditorWindowIDCommand` | — | MISSING / N/A |
| `get main window id` | `BromureACGetMainWindowIDCommand` | — | MISSING / N/A |
| `get profile json` | `BromureACGetProfileJSONCommand` | `GET /profiles/{id}/json` | OK |
| `set profile json` | `BromureACSetProfileJSONCommand` | `PUT /profiles/{id}/json` | OK |
| `get profile setting` | `BromureACGetProfileSettingCommand` | `GET /profiles/{id}/settings/{key}` | PARTIAL (key surface smaller) |
| `set profile setting` | `BromureACSetProfileSettingCommand` | `PUT /profiles/{id}/settings/{key}` | PARTIAL (key surface smaller) |
| `open ac session` | `BromureACOpenSessionCommand` | `POST /sessions` | OK |
| `close ac session` | `BromureACCloseSessionCommand` | `DELETE /sessions/{id}` | OK |
| `list ac sessions` | `BromureACListSessionsCommand` | `GET /sessions` | OK |
| `get ac app setting` | `BromureACGetAppSettingCommand` | — | MISSING |
| `set ac app setting` | `BromureACSetAppSettingCommand` | — | MISSING |

### Profile-setting key coverage gap
- **macOS source**: `ScriptCommands.swift:250–305` — 13 keys: `name, color, comments, tool, authMode, apiKey, closeAction, memoryGB, folderPath, folderPathsCount, mcpServerCount, keyboardLayoutOverride, keyRepeatDelayMs, keyRepeatRateHz`.
- **Windows status**: PARTIAL
- **Detail**: `ShellViewModel.cs:370–409` supports 9 keys: `name, color, tool, authMode, apiKey, folderPathsCount, mcpServerCount, privateMode, traceLevel`. Missing: `comments, closeAction, memoryGB, keyboardLayoutOverride, keyRepeatDelayMs, keyRepeatRateHz`. Windows added `privateMode` and `traceLevel` (reasonable). Tests that touch any of the missing keys via the automation API will fail.

### Live `automation.enabled` toggle
- **macOS source**: `ScriptCommands.swift:404–408` — setting `automation.enabled` via AppleScript calls `d.startAutomationServerIfNeeded()` / `stopAutomationServer()` so the HTTP server can be turned on/off without restarting the app.
- **Windows status**: MISSING
- **Detail**: Server starts unconditionally (§5); cannot be toggled at runtime.

---

## 7. MCP CLI shim (bromure-ac-mcp)

### Feature: MCP CLI shim binary
- **macOS source**: `bromure-ac mcp` subcommand (per AutomationServer.swift comment line 7).
- **Windows status**: OK
- **Detail**: `windows/Bromure.AC.Mcp/Program.cs` is a standalone JSON-RPC stdio MCP server that translates MCP tool calls into HTTP against `http://127.0.0.1:9223`. Matches macOS shape. Default API URL identical.

### Feature: MCP tool surface
- **macOS source**: macOS exposes the same `tools/list` (see AutomationServer.swift comment + ac-e2e.mjs).
- **Windows status**: not audited here in detail — separate file. Defer to a future audit if needed.

---

## Summary by severity

### CRITICAL (subscription/Codex token flow non-functional end-to-end)
1. **In-VM token agents not installed** (§3) — guest never connects to the bridge. `claude-token-agent.py` + `codex-token-agent.py` are not copied into the Windows guest image. setup.sh/setup-hcs.sh need the same copy + xinitrc start as macOS.
2. **SubscriptionTokenCoordinator never instantiated** (§4) — class exists but no caller. App.xaml.cs / ShellViewModel / SessionViewModel must build one and wire it.
3. **Bridge transport is named pipes, not AF_HYPERV** (§1) — guest cannot dial named pipes from Linux. `VsockBridge.cs` must use `HvSocket` (AF_HYPERV `SOCK_STREAM`, service GUID per port) like `HvSocketTcpBridge.cs` already does for RDP.
4. **Bridge wire format has extra `id` field** (§1) — incompatible with `claude-token-agent.py`. Either patch the Python agent to echo `id`, OR revert to positional FIFO matching like macOS.
5. **Detection hooks not fired** (§4) — `MitmEngine.SubscriptionTokenSeen` / `CodexTokenSeen` callbacks are declared but never invoked by the proxy. Also blocks token-rotation prompts. (Already in parity-audit/02.)
6. **Auto-seed on fresh VM missing** (§4) — defeats the "save as default" UX even after a manual swap is performed.
7. **Swap-entry-vs-write ordering inverted** (§4) — Windows writes fakes to VM before registering swap map → in-flight calls get 401.
8. **Codex swap entry set incomplete** (§4) — 4 entries vs macOS 6; missing chatgpt.com refresh-body and auth.openai.com id-token entries.

### HIGH
9. **SubscriptionTokenSwapState enum + Profile fields missing** (§4) — cannot persist "Never for this profile" decision.
10. **Consent UI missing** (§4) — `ISubscriptionConsentPrompt` has no WPF implementation; only `AlwaysAllowSubscriptionPrompt` stub. No "Not now" / "Never" distinction.
11. **OAuth rotation persistence missing** (§4) — `OAuthRotated` callback declared, never wired; rotated tokens not saved back to profile/template.
12. **`automation.enabled` opt-in gate missing** (§5) — server runs unconditionally; cannot be disabled at runtime.
13. **Throttle never reset on swap failure** (§4) — once asked, never re-asked, even if the swap failed.
14. **`recordRotation` / template-defaults-rotation missing** (§4) — stale defaults after refresh.

### MEDIUM
15. **Exec endpoint schema diverged** (§5) — returns `{output}` not `{stdout, stderr, exitCode}`.
16. **`app state` payload keys differ** (§5) — no `locale`, no `editorOpen`; new `phase`/`windowVisible`. Tests will diverge.
17. **Response JSON not sorted** (§5) — diff vs macOS golden files.
18. **Profile setting key surface smaller** (§6) — `comments`, `closeAction`, `memoryGB`, `keyboardLayoutOverride`, `keyRepeatDelayMs`, `keyRepeatRateHz` unreachable.
19. **App-settings endpoints absent** (§5/§6) — `automation.*` and `managed.*` keys can't be set via the API.
20. **Bridge `DisposeAsync` doesn't tear down the listener** (§1) — leaks the named-pipe server.

### LOW
21. **No `quit` / editor / window-ID endpoints** (§6) — screenshot tooling cannot drive WPF editor.
22. **`resetSessionDecision` missing** (§4) — user can't re-enable prompts from the editor.
23. **`offerSaveAsDefault` missing** (§4) — no UX to promote one-time login to default.
24. **Coordinator unregister doesn't dispose bridges** (§4) — `bridge.DisposeAsync` not called.

### OK
- Bridge JSON shape for read/write/op.
- Salt derivation strings.
- Per-(profile, provider) bridge dictionaries.
- HTTP endpoints for core /health, /profiles, /sessions, /sessions/{id}.
- Default port 9223, loopback bind, debug gating via `BROMURE_DEBUG_CLAUDE`.
- Per-port concurrent request handling.
- MCP CLI shim (`Bromure.AC.Mcp`) shape.

---

## Tally
- CRITICAL: 8
- HIGH: 6
- MEDIUM: 6
- LOW: 4
- Total gaps: **24**

## Top 5 most impactful (block subscription UX entirely)
1. In-VM token agents not installed in Windows guest image (no Python agents in `setup.sh`).
2. SubscriptionTokenCoordinator instantiated nowhere; coordinator + bridges are unreachable dead code.
3. Bridge transport uses Windows Named Pipes — Linux guest cannot dial it. Needs AF_HYPERV / hvsocket.
4. No detection hook — `MitmEngine.SubscriptionTokenSeen` / `CodexTokenSeen` callbacks are never invoked by the proxy.
5. Wire format mismatch — Windows bridge adds an `id` field that the Python agent does not echo (would also need to fix swap-entry vs write ordering to avoid 401s).
