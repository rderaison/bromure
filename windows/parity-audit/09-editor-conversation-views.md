# Parity audit 09 — Profile editor + Conversation + Approvals + Trace Inspector

Audited macOS sources:
- `Sources/AgentCoding/ProfileViews.swift` (3496 LOC) — profile picker + editor + sub-row components.
- `Sources/AgentCoding/ConversationView.swift` (1318 LOC) — provider-aware AI exchange render.
- `Sources/AgentCoding/CredentialApprovalsView.swift` (163 LOC) — live consent grants list.
- `Sources/AgentCoding/TraceInspectorView.swift` (533 LOC) — MITM exchange browser.
- `Sources/AgentCoding/SetupViews.swift` (283 LOC) — first-run + init progress.

Audited Windows counterparts:
- `windows/Bromure.AC/Views/ProfileEditorWindow.xaml(+.cs)` — thin wrapper around `ProfilesView`.
- `windows/Bromure.AC/Views/ProfilesView.xaml(+.cs)` — picker + tabbed editor.
- `windows/Bromure.AC/Views/ApprovalsView.xaml(+.cs)` + `ApprovalsViewModel.cs`.
- `windows/Bromure.AC/Views/TraceInspectorView.xaml(+.cs)` + `TraceInspectorViewModel.cs`.
- `windows/Bromure.AC/ViewModels/ProfilesViewModel.cs` — backing VM for editor.
- `windows/Bromure.AC/ViewModels/{PhaseTemplateSelector,NavigationTemplateSelector}.cs`.

Cross-checked against `windows/Bromure.AC.Core/Model/Profile.cs` + `McpServer.cs` for backing fields. `windows/PARITY_IGNORE` declares all SwiftUI views as "track by feature, not by file" — this audit is the per-feature pass that file calls for.

---

## Part A — Profile editor (per pane on macOS, mapped to Windows tabs)

The macOS editor has a sidebar listing **10 categories** (`EditorCategory` at `ProfileViews.swift:285-330`). Visibility is conditional: `automation` only appears when opened via Preferences. The Windows editor has **5 tabs**: General, Folders, Credentials, Environment — plus a tab for `Profile SSH key` and `Imported SSH keys` folded into Credentials. No sidebar/category icons (macOS uses `GradientIcon` w/ colored gradient + SF symbol; Windows is a plain `TabControl`).

### A1. Editor: General pane

#### Feature: Profile name (TextField)
- **macOS source**: `ProfileViews.swift:578-584`
- **Windows status**: OK — `ProfilesView.xaml:128-132` two-way binds `Name`.
- **Detail**: Both present; macOS suppresses the field for the synthetic "Defaults" template (`draft.id != ProfileStore.templateID`), Windows has no template concept so no equivalent suppression — fine, not a regression.

#### Feature: Profile color picker
- **macOS source**: `ProfileViews.swift:586-595` — Picker with a filled `Circle().gradient` + label per case.
- **Windows status**: PARTIAL.
- **Detail**: Windows binds to a `ComboBox` of `ColorOptions` (`ProfilesView.xaml:136-140` + `ProfilesViewModel.cs:46`). No color swatch in the dropdown items; the user picks a name like `Blue` without seeing the chip. The profile-list row sidebar always uses `AccentBrush` (`ProfilesView.xaml:43-46`), so the chosen color isn't even reflected in the list dot — definitely a visual regression.

#### Feature: Keyboard layout picker (Auto + named XKB layouts)
- **macOS source**: `ProfileViews.swift:665-681` — "Auto (match macOS)" sentinel + `VMConfig.commonKeyboardLayouts`.
- **Windows status**: MISSING.
- **Detail**: No `KeyboardLayoutOverride` field in `Profile.cs` and no UI surface. WSL/Hyper-V guest keymap can't be pinned from the editor.

#### Feature: Key repeat delay & rate (with host-default sentinel)
- **macOS source**: `ProfileViews.swift:628-660` — pre-fills `hostKeyRepeat` (live macOS values), reverts to nil when the user types the same number back.
- **Windows status**: MISSING.
- **Detail**: No `keyRepeatDelayMs` / `keyRepeatRateHz` in `Profile.cs`. Guest receives a hard-coded autorepeat (or none).

#### Feature: Close-action picker (suspend / shutdown / ask)
- **macOS source**: `ProfileViews.swift:614-622` — `Profile.CloseAction` radio group.
- **Windows status**: MISSING.
- **Detail**: No `CloseAction` enum or field on `Profile.cs`. Windows session window simply closes; no suspend-on-close semantics surfaced anywhere.

#### Feature: Notes / comments multi-line TextField
- **macOS source**: `ProfileViews.swift:604-606` — `axis: .vertical, lineLimit(2...6)`, also shown in row `.help(comments)` (`ProfileViews.swift:115`).
- **Windows status**: MISSING.
- **Detail**: No `Comments` field on `Profile.cs`. Cannot annotate profiles.

#### Feature: Privacy / Private mode toggle
- **macOS source**: `ProfileViews.swift:1804-1816` — gated on `BACEnrollmentStore.load() != nil` (only shown if enrolled with bromure.io).
- **Windows status**: PARTIAL.
- **Detail**: Windows shows it unconditionally on the General tab (`ProfilesView.xaml:179-187`) regardless of enrollment state. On macOS it lives in the Tracing pane; Windows put it in General. Functional parity (the `PrivateMode` bool is wired) but: (a) no enrollment gating, (b) different pane location, (c) macOS gating prevented confusing users on un-enrolled installs.

#### Feature: Trace level picker
- **macOS source**: `ProfileViews.swift:1782-1795` — lives in the dedicated **Tracing** pane next to the body-capture explanation.
- **Windows status**: DIFFERENT.
- **Detail**: Present (`ProfilesView.xaml:170-176`) but lives in the General tab as a one-liner ComboBox. macOS has prominent inline explanation of what each level captures (encrypted body files, known-LLM-host gating, "View at Trace Inspector"); Windows has no help text — discoverability and "what does AiDetails do?" suffer.

### A2. Editor: Agent pane (multi-tool support)

#### Feature: Multi-tool config (primary + additional tools, per-tool auth)
- **macOS source**: `ProfileViews.swift:683-791` (Agent section) + `ToolConfigCard` `2921-3026`.
- **Windows status**: MISSING.
- **Detail**: Windows has ONE primary tool + auth-mode combo on the General tab. `Profile.cs:36` carries an `AdditionalTools` collection and `AllToolSpecs` enumerator, but the editor exposes no UI to add/remove additional tools, promote one to primary, or per-tool require-approval. macOS lets you enable Claude **and** Codex in the same profile with independent auth modes; Windows can't.

#### Feature: Bedrock auth mode + Default Model ID
- **macOS source**: `ProfileViews.swift:2991-3003`.
- **Windows status**: PARTIAL.
- **Detail**: `Profile.cs:89-90` exposes `BedrockEnabled` + `BedrockModelID`, but the editor never offers them — the auth-mode ComboBox lists every `AuthMode` enum value (including Bedrock if defined), but there's no Model ID input or the explanatory caption macOS shows. Picking Bedrock from the combo doesn't surface the AWS-credentials cross-reference.

### A3. Editor: Folders pane

#### Feature: Folder list with name + path display + 8-folder cap + folder picker
- **macOS source**: `ProfileViews.swift:793-843`, `addFolder()` `2236-2250`.
- **Windows status**: OK — `ProfilesView.xaml:195-234` + `ProfilesViewModel.cs:175-192`.
- **Detail**: Functional parity. macOS shows the folder's basename in bold + full path muted underneath; Windows shows just the full path in a single line. Both cap at 8 (`Selected.FolderPaths.Count >= 8`). Minor visual gap.

### A4. Editor: Credentials pane

The macOS pane is one big disclosure-group list with persistent expand state. The Windows version uses `Expander` controls — similar idea, but the contents differ section by section.

#### Feature: Git identity (user.name / user.email) always-visible block
- **macOS source**: `ProfileViews.swift:849-861`.
- **Windows status**: MISSING.
- **Detail**: `Profile.cs:49-50` carries the fields, but the credentials tab never renders them. Users can't set `user.name`/`user.email` for the generated `~/.gitconfig` from the UI.

#### Feature: Per-forge git-token groups (GitHub / GitLab / Bitbucket separate)
- **macOS source**: `ProfileViews.swift:872-903` — three separate disclosure groups with host-aware "open token page" button.
- **Windows status**: PARTIAL.
- **Detail**: Windows has one generic `Git HTTPS credentials` expander (`ProfilesView.xaml:306-367`). All hosts thrown together. No "open create-token page" launcher (macOS `openTokenPage(for:)` at `ProfileViews.swift:1754-1769`). No per-host icon (`cat.fill`/`fox.fill`).

#### Feature: Container registries with menu of well-known hosts + Docker config.json import
- **macOS source**: `ProfileViews.swift:1393-1456`, `importDockerConfigFile()` `1470-1534`.
- **Windows status**: PARTIAL.
- **Detail**: Windows offers a generic "Add Docker registry" defaulting to `docker.io` (`ProfilesView.xaml:439-494`). MISSING: dropdown of Docker Hub / ghcr.io / registry.gitlab.com / quay.io presets; import-from-`config.json` (skipping credsStore/credHelpers, dedupe by host+username, summary alert). No docker config import means users with existing `~/.docker/config.json` re-key by hand.

#### Feature: Kubernetes contexts with file import + bearer/cert/exec auth modes
- **macOS source**: `ProfileViews.swift:1131-1170`, `KubeconfigRow` `3033-3245`, `importKubeconfigFile()` `1174-1195`.
- **Windows status**: PARTIAL.
- **Detail**: Windows lists contexts (`ProfilesView.xaml:497-559`) with Name + Server URL + Namespace + RequireApproval, **bearer-token auth ONLY** — the XAML comment at line 502-505 explicitly says client-cert/exec-plugin are "iterative". MISSING: kubeconfig file import (`KubeconfigImport.parse`), CA cert PEM editor, client-cert mode (cert+key PEMs), exec-plugin mode (command/args/refresh-seconds), auth-method colored badges. Half the kube auth surface is unreachable from the UI.

#### Feature: DigitalOcean access token block
- **macOS source**: `ProfileViews.swift:1207-1230` — `SecureField` + "Open DO token page" launcher.
- **Windows status**: MISSING.
- **Detail**: `Profile.cs:79-80` carries `DigitalOceanToken` + `DigitalOceanRequiresApproval`, but the credentials tab never exposes them.

#### Feature: AWS auth — Static keys vs SSO with config discovery
- **macOS source**: AWS auth-mode picker `ProfileViews.swift:1254-1275`, Static `1278-1321`, SSO `1323-1390`. SSO discovers `~/.aws/config` via `AWSConfigParser.discover()`, populates a Picker, on selection sets `ssoAccountID` + `ssoRoleName` + `region` from the parsed profile.
- **Windows status**: PARTIAL.
- **Detail**: Windows AWS tab (`ProfilesView.xaml:243-303`) has Auth-mode + SsoProfile (free TextBox) + AccessKeyId + SecretAccessKey + SessionToken + RequireApproval. MISSING: SSO profile **discovery** (the macOS "Grant Access to ~/.aws" button kicks off a file-folder scope grant via NSOpenPanel + parses `config` for `[sso-session]`/`[profile]` blocks). MISSING: `region` TextBox (macOS has one — `Default region` row 1302). MISSING: "Open IAM credentials page" launcher. SSO mode reduced to manually typing the profile name.

#### Feature: SSH key — generated keypair with "Generate ed25519" toggle, regen confirmation, copy public, open GitHub keys page
- **macOS source**: `ProfileViews.swift:1015-1071` (subsection) — toggle controls whether `ssh-keygen` runs on save; regenerate has explicit toggle.
- **Windows status**: PARTIAL.
- **Detail**: Windows auto-generates on profile create (`ProfilesViewModel.cs:119`), shows the public key in a read-only TextBox + Copy + Regenerate (`ProfilesView.xaml:562-592`). No "Generate" opt-in toggle for new profiles (always generated). No `requireApproval` toggle for the auto-generated key (macOS shows `requireApprovalToggle(isOn: $draft.sshKeyRequiresApproval)` at line 1063). MISSING: "Open GitHub keys page" launcher.

#### Feature: SSH key import with label + passphrase dialog + macOS Keychain integration
- **macOS source**: `ProfileViews.swift:1572-1663`, `presentImportPicker()` `1710-1736`, `completeImport()` `1738-1752`, `importSheetView` `1666-1708`.
- **Windows status**: PARTIAL.
- **Detail**: Windows offers `ImportSshKey` command via `OpenFileDialog` (`ProfilesViewModel.cs:252-277`) and reads the PEM directly into the model. MISSING: label input dialog (Windows uses the filename), passphrase input + ASKPASS / secret-store integration (Windows just stores `PrivateKeyPem` plaintext on the profile), per-key public-key fingerprint display, `lock.fill` indicator for passphrase-protected keys, public-key blob extraction + `requireApproval` gating disabled when `publicKeyText.isEmpty`. macOS preserves the .pub blob so the consent broker can match incoming SIGN_REQUESTs; the Windows flow stores no public key text at all, so the require-approval toggle on Windows (`ImportedSshKey.RequireApproval`) may not work end-to-end.

#### Feature: Manual / "Other API keys" tokens with name + env var + host filter + reveal-secret eye + require-approval
- **macOS source**: `ProfileViews.swift:1539-1570`, `ManualTokenRow` `2290-2346`.
- **Windows status**: PARTIAL.
- **Detail**: Windows has Name/Value/EnvVar/HostFilter/RequireApproval fields (`ProfilesView.xaml:370-436`) but value is a `PasswordBox` with no "reveal" toggle. Functional parity for the swap model; UX regression around inspecting the configured value.

### A5. Editor: Environment pane

#### Feature: env-var name validation regex
- **macOS source**: `ProfileViews.swift:2350-2382` — surfaces an orange warning when name doesn't match `[A-Za-z_][A-Za-z0-9_]*`.
- **Windows status**: PARTIAL.
- **Detail**: Windows env tab (`ProfilesView.xaml:648-696`) has Name + Value + IsSecret + Remove. No inline validation feedback. macOS only treats invalid names as a warning (still saved); Windows would happily ship invalid names into the guest's `proxy.env`.

#### Feature: "Secret" flag on env var
- **macOS source**: macOS doesn't have an `isSecret` toggle on `EnvironmentVariable`.
- **Windows status**: DIFFERENT.
- **Detail**: Windows has an extra `IsSecret` checkbox (`ProfilesView.xaml:676-678`). This is a Windows-only field that doesn't exist on macOS — minor divergence in model semantics.

### A6. Editor: MCP pane (entirely missing in Windows editor)

#### Feature: MCP server list with name + transport toggle + enable switch + form/JSON switch
- **macOS source**: `ProfileViews.swift:2100-2130`, `MCPServerRow` `2386-2635`.
- **Windows status**: MISSING.
- **Detail**: `Profile.cs:70` carries the `McpServers` collection and `McpServer.cs` carries the full shape (transport, command, args, url, env, bearer token env var, RawJson, OAuthState). But `ProfilesView.xaml` has no MCP tab at all — users cannot add/edit/enable/disable MCP servers in the editor. There is a `Bromure.AC.Mcp` project (visible in `git status`) and `McpConfigBuilder.cs` builds the guest config, but the UI to drive any of it is unreachable. Critical gap given MCP is a tier-1 feature.

#### Feature: MCP HTTP transport — OAuth "Authorize…" button + state display + revoke + "or static token" fallback
- **macOS source**: `ProfileViews.swift:2461-2542`, `authorizeOAuth()` `2545-2581`.
- **Windows status**: MISSING.
- **Detail**: Even though `McpOAuthState` exists on the model and `windows/Bromure.AC.Mitm/OAuth/McpOAuthBroker.cs` is present (visible in `git status` as untracked), there's no UI surface to kick off authorization, see expiry, or revoke. Authorization can only happen via direct broker calls.

#### Feature: MCP stdio transport — command + args TextFields
- **macOS source**: `ProfileViews.swift:2449-2460`.
- **Windows status**: MISSING.

#### Feature: Raw JSON editor with validity highlighting
- **macOS source**: `ProfileViews.swift:2583-2611` — TextEditor in monospaced font, red-stroked border when JSON parse fails.
- **Windows status**: MISSING.

### A7. Editor: Tracing pane

#### Feature: Subscription-token-swap state row (Claude / Codex) with "Active / Declined" badge + reset
- **macOS source**: `ProfileViews.swift:1818-1871`.
- **Windows status**: MISSING.
- **Detail**: `Profile.cs` has `DefaultClaudeTokens` / `DefaultCodexTokens` but no equivalent `subscriptionTokenSwap` / `codexTokenSwap` `.unset/.accepted/.declined` tri-state, and no UI to inspect or reset the decision. Users who clicked "Never for this profile" on the swap prompt can't change their mind without editing JSON.

### A8. Editor: Appearance pane

The entire macOS Appearance pane is **MISSING** in Windows.

#### Feature: Font family picker (system font list, filters dotted prefixes)
- **macOS source**: `ProfileViews.swift:2135-2156`, `allFontFamilies` `2217-2221`.
- **Windows status**: MISSING.

#### Feature: Font size stepper (8–32 pt)
- **macOS source**: `ProfileViews.swift:2148-2155`.
- **Windows status**: MISSING.

#### Feature: Cursor shape picker
- **macOS source**: `ProfileViews.swift:2159-2169`. `Profile.CursorShape.allCases`.
- **Windows status**: MISSING.

#### Feature: Foreground / Background color pickers
- **macOS source**: `ProfileViews.swift:2172-2183`.
- **Windows status**: MISSING.

#### Feature: Window opacity slider
- **macOS source**: `ProfileViews.swift:2186-2193`.
- **Windows status**: MISSING.

#### Feature: "Reset to Terminal.app" defaults button
- **macOS source**: `ProfileViews.swift:2197-2208`.
- **Windows status**: MISSING.

#### Feature: Backing fields on `Profile`
- **Windows status**: MISSING (no `CustomFontFamily`, `CustomFontSize`, `CursorShape`, `CustomForegroundHex`, `CustomBackgroundHex`, `WindowOpacity` on `Profile.cs`).

### A9. Editor: Resources pane

The entire macOS Resources pane is **MISSING** in Windows.

#### Feature: Storage stack — 3-layer visual (home / profile disk / base image) with sizes, mtimes, and per-layer reset
- **macOS source**: `StorageStackView` `2644-2823`, `StorageLayerRow` `2826-2913`. Reads `URLResourceKey.totalFileAllocatedSize`, formats with `ByteCountFormatter`, computes relative age.
- **Windows status**: MISSING.
- **Detail**: No layered storage UI at all. Users can't see disk usage, can't "Erase home" or "Reset to base" from the profile editor. There's no equivalent of macOS's `ACAppDelegate.resetProfile` / `resetHomeProfile` wired to a button.

#### Feature: VM memory stepper (2–32 GB)
- **macOS source**: `ProfileViews.swift:1899-1909`.
- **Windows status**: MISSING.
- **Detail**: No `MemoryGB` field on `Profile.cs`. HCS sandbox spec hard-codes RAM elsewhere — users can't tune per profile.

#### Feature: Network mode (NAT / bridged) + bridged interface picker
- **macOS source**: `ProfileViews.swift:1913-1949`. Enumerates `VZBridgedNetworkInterface.networkInterfaces`.
- **Windows status**: MISSING.
- **Detail**: No `NetworkMode` / `BridgedInterfaceID` field on `Profile.cs`. HCS networking is NAT by default; no way to choose bridged from the editor.

### A10. Editor: Automation pane (Preferences-only)

#### Feature: Enable HTTP automation server + port + bind address + MCP-client config snippet
- **macOS source**: `ProfileViews.swift:1994-2096`. Uses `AutomationDefaultsStore` (UserDefaults bridge).
- **Windows status**: PARTIAL (different surface).
- **Detail**: Windows exposes automation toggles via the Preferences/Settings pane (per `SettingsViewModel.cs`, modified in `git status`). The macOS pane uniquely also displays a copy-pasteable MCP client config snippet (`mcpConfigSnippet` `2086-2096`); this snippet is not surfaced on Windows. The address bind-warning when not 127.0.0.1 is also macOS-only.

### A11. Editor: Per-row UX (cross-cutting)

#### Feature: "Require approval to use" reusable checkbox helper
- **macOS source**: `ProfileViews.swift:1238-1249`.
- **Windows status**: OK.
- **Detail**: Present per-row on Windows for AWS / Git / Manual / Docker / Kube / SSH-imported. Functional parity.

#### Feature: Reveal-secret eye toggle for SecureField inputs
- **macOS source**: `HTTPSCredentialRow` `3252-3327`, `DockerRegistryRow` `3331-3396`, `ManualTokenRow` `2316-2334`.
- **Windows status**: MISSING.
- **Detail**: Windows uses `PasswordBox` (always masked) with `PasswordBoxBinding.Password` two-way binding. No reveal toggle anywhere. Pasting a wrong-typed secret can't be verified in place.

#### Feature: "Open token page" launcher for known forges
- **macOS source**: `openTokenPage` `1754-1769`; surfaced on the HTTPSCredentialRow.
- **Windows status**: MISSING.

#### Feature: Save / cancel + dirty-state semantics
- **macOS source**: Modal dialog footer `ProfileViews.swift:499-512` — explicit "Save" / "Cancel" with `keyboardShortcut(.defaultAction/.cancelAction)`. `disabled(!isValid)` gates save on a non-empty name.
- **Windows status**: DIFFERENT.
- **Detail**: Windows persists on every edit via `RemoveAndSave` and per-Add command (`ProfilesViewModel.cs:290-296` + comments at line 705 of XAML "Edits in this pane persist on every change"). The "Save" button forces an explicit write but cancel doesn't roll back — there's NO dirty-state with revert. The footer text in XAML explicitly admits this. No `isValid` gate (empty name profiles can be saved). Different semantic model; arguably a regression because typos auto-persist.

#### Feature: Delete confirmation
- **macOS source**: Delete from picker via `onDelete(profile)` callback — `ACAppDelegate` shows an `NSAlert` confirm.
- **Windows status**: PARTIAL.
- **Detail**: `DeleteSelected` in `ProfilesViewModel.cs:126-135` deletes with NO user confirmation; only safety gate is "must have ≥1 profile". A misclick on "Delete" in the header strip permanently destroys a profile (and via `ProfileSshKey.Delete` its SSH key too).

#### Feature: Editor sidebar with gradient-icon categories (macOS) vs flat tabs (Windows)
- **macOS source**: `ProfileViews.swift:471-484`, `categoryIcon` `554-570` (including custom SVG for the MCP icon loaded from the resource bundle).
- **Windows status**: DIFFERENT.
- **Detail**: Windows uses a plain `TabControl` with text-only headers. No icons, no colored gradient blocks. Visual brand-parity gap.

### A12. Picker (profile chooser before launch)

The macOS `ProfilePickerView` (`ProfileViews.swift:51-221`) is the standalone window opened from the menu/dock; the Windows port reuses the same `ProfilesView` UserControl in two roles.

#### Feature: "Open Session" launch button tinted in profile color + meta line under it
- **macOS source**: `ProfileViews.swift:155-203` — large prominent `.borderedProminent` button + meta `Label`s showing tools / authMode / folder count / SSH key / memory.
- **Windows status**: DIFFERENT.
- **Detail**: Windows doesn't have a launch-from-picker flow inside `ProfilesView`; sessions launch from the Sessions navigation pane via `SessionsViewModel`. Meta line summarising the selected profile (tools+auth+folders+SSH+RAM in one strip) MISSING.

#### Feature: Profile row badges — running (green dot) + compromised (red exclamation octagon)
- **macOS source**: `ProfileRow` `223-269` — `isRunning` and `isCompromised` from sets supplied by `ACAppDelegate`.
- **Windows status**: MISSING.
- **Detail**: `ProfilesView.xaml:36-54` has just a color dot + name + tool subtitle. No running indicator, no compromised marker. The MITM compromise detector's output isn't wired to the picker UI on Windows.

#### Feature: Context menu on a profile row — Launch / Edit / Duplicate / SSH key / Reset / Delete
- **macOS source**: `ProfileViews.swift:104-114`.
- **Windows status**: MISSING.
- **Detail**: No `ContextMenu` on the Windows ListBox items. Duplicate command nowhere in `ProfilesViewModel`. "Reset disk" not exposed.

#### Feature: Keyboard shortcut ⌘N to add a new profile
- **macOS source**: `ProfileViews.swift:131`.
- **Windows status**: MISSING — no `InputBindings` or `KeyBinding` for Ctrl+N.

---

## Part B — ConversationView (chat-style transcript)

The macOS file is **1318 LOC of provider-aware parser + render code**. The Windows project ships `windows/Bromure.AC.Mitm/Conversation/ConversationParser.cs` (so parsing is partially ported — exists in tests too) but **no UI** consumes it.

#### Feature: Provider-aware conversation parser (Anthropic, OpenAI Chat, OpenAI Responses, Cohere, Gemini) + WebSocket transcript walker
- **macOS source**: `ConversationView.swift:48-1058` — six provider parsers, SSE accumulators, WS transcript dedup-by-fingerprint.
- **Windows status**: PARTIAL.
- **Detail**: `Bromure.AC.Mitm/Conversation/ConversationParser.cs` exists with tests, but only the UI surface integrates it via `ConversationEventEmitter` for cloud streaming — there's no in-app inspector view.

#### Feature: Chat-style bubble layout (user right, assistant/system/tool left) with color-coded bubble backgrounds
- **macOS source**: `MessageBubble` `1193-1249`.
- **Windows status**: MISSING.

#### Feature: System-prompt collapsible bubble
- **macOS source**: `SystemBubble` `1170-1191`.
- **Windows status**: MISSING.

#### Feature: Raw request-envelope disclosable JSON bubble
- **macOS source**: `RequestEnvelopeBubble` `1139-1168`.
- **Windows status**: MISSING.

#### Feature: Tool-use block (purple, wrench icon, monospaced JSON arguments)
- **macOS source**: `BlockView.toolUse` `1261-1278`.
- **Windows status**: MISSING.

#### Feature: Tool-result block (green ok / red error, monospaced output)
- **macOS source**: `BlockView.toolResult` `1279-1299`.
- **Windows status**: MISSING.

#### Feature: Image attachment marker (mediaType only — not rendered)
- **macOS source**: `BlockView.image` `1300-1306`.
- **Windows status**: MISSING.

#### Feature: Conversation header (provider icon + name + model pill + input/output tokens)
- **macOS source**: `header` `1092-1117`.
- **Windows status**: MISSING.

#### Feature: Text selection + copy on every body block
- **macOS source**: `.textSelection(.enabled)` throughout.
- **Windows status**: MISSING (no consumer).

#### Feature: Code-block syntax highlighting
- **macOS source**: NOT present — macOS just uses monospaced `.font(.caption, design: .monospaced)`. The audit task asked about this; the answer is "macOS doesn't ship syntax highlighting either, and neither does Windows". OK as parity baseline.

#### Feature: Search across conversation messages / jump-to-trace links
- **macOS source**: NOT present. macOS has no in-conversation search or jump-to-trace beyond surfacing the same Conversation in the Trace Inspector's detail pane when you pick the matching row.
- **Windows status**: N/A on macOS, MISSING on Windows.

---

## Part C — CredentialApprovalsView

#### Feature: List of live consent decisions, auto-refresh every 2 s
- **macOS source**: `CredentialApprovalsView.swift:13-72` — polls `broker.snapshot()` on a 2 s `Task.sleep` loop, drives a SwiftUI List.
- **Windows status**: OK.
- **Detail**: `ApprovalsViewModel.cs:24-28` uses a `DispatcherTimer` 2 s tick to call `Refresh()`. Same polling cadence.

#### Feature: Distinct icon + color per kind (allow / session-scoped / deny)
- **macOS source**: `iconName(for:)` `117-122` returns `nosign` / `infinity.circle.fill` / `clock.fill`; `iconColor` returns red / blue / orange.
- **Windows status**: PARTIAL.
- **Detail**: Windows shows just a text "ALLOW" / "DENY" column (`ApprovalsView.xaml:41`). No icon, no color coding. Color-blind users on macOS have the "Denied" word lead too (line 94-97); Windows accessibility is fine because the label is the only signal. But the at-a-glance visual is gone.

#### Feature: Per-row "Revoke" + global "Revoke all"
- **macOS source**: `CredentialApprovalsView.swift:30-37, 105-112`. Global revoke has `keyboardShortcut(.delete, modifiers: [.command])`.
- **Windows status**: OK.
- **Detail**: Both present (`ApprovalsView.xaml:23-28, 44-52`). Windows missing the Cmd-Delete keyboard shortcut equivalent (no `InputBindings`).

#### Feature: Profile-name lookup (UUID → display name)
- **macOS source**: `profileNames: [UUID: String]` parameter, used in `Text(profileNames[entry.profileID] ?? "(unknown profile)")` line 86.
- **Windows status**: DIFFERENT.
- **Detail**: Windows shows `ProfileShort = entry.ProfileId.ToString("D")[..8]` — first 8 chars of the GUID, NOT the profile's name. Less readable.

#### Feature: Remaining-time label ("rest of session", "%d min remaining", "%d sec remaining")
- **macOS source**: `remainingLabel(for:)` `145-157`.
- **Windows status**: PARTIAL.
- **Detail**: Windows computes `ScopeLabel` once at row-construction time (`ApprovalsViewModel.cs:58-61`) and doesn't refresh per tick — the displayed remaining time only updates when the 2 s poll rebuilds the row. Acceptable but not granular.

#### Feature: Empty-state placeholder + loading state
- **macOS source**: `placeholder(...)` `131-143`, two messages.
- **Windows status**: MISSING.
- **Detail**: Empty DataGrid just shows blank rows. No "No active credential decisions" copy.

#### Feature: "remember decision" toggle on the consent prompt
- **macOS source**: Not in this view — it's in the modal consent dialog (a SwiftUI sheet not in scope). The Approvals view shows the *result* of that toggle. No gap here.
- **Windows status**: Out of scope for this view.

#### Feature: Expiry display + automatic cleanup on tick
- **macOS source**: Built into the broker, list refreshes pick up the removals on the 2-second tick.
- **Windows status**: OK — same model.

---

## Part D — TraceInspectorView

#### Feature: Two-pane NavigationSplitView (list left, detail right) with min width 900x560
- **macOS source**: `TraceInspectorView.swift:52-70`, frame `.frame(minWidth: 900, minHeight: 560)`.
- **Windows status**: DIFFERENT.
- **Detail**: Windows uses a top-to-bottom vertical layout (`TraceInspectorView.xaml:7-12` — `DataGrid` above, `200pt` detail panel below). Master/detail vertical split instead of horizontal. Less efficient with wide monitors; common pattern on Windows but a UX divergence.

#### Feature: Filter bar — profile picker + leaks-only + conversations-only + host search
- **macOS source**: `filterBar` `153-190`.
- **Windows status**: PARTIAL.
- **Detail**: Windows has only a single host/path text filter (`TraceInspectorView.xaml:27-32`). MISSING: profile-picker filter (cannot show only one profile's traffic), MISSING: "Leaks only" checkbox, MISSING: "Conversations only" checkbox (the `isConversation` flag exists on the macOS `TraceRecord` but the Windows equivalent doesn't have that filter UI).

#### Feature: Conversation / Raw mode toggle in detail header
- **macOS source**: `detailHeader(for:conversationAvailable:)` `326-377` — segmented picker between "Conversation" and "Raw", auto-falls back to Raw when the parser can't make sense of the body.
- **Windows status**: MISSING.
- **Detail**: No mode toggle. Detail panel always shows the raw swaps/leaks list — no chat-style view ever surfaces in the inspector. This is the same gap as ConversationView absence (Part B).

#### Feature: Row badges — leak triangle, swap arrow, body-captured doc
- **macOS source**: `row(_:)` `238-289` — colored exclamation triangle for leaks, blue arrows for swaps, document icon for `bodyStored`.
- **Windows status**: PARTIAL.
- **Detail**: Windows uses text columns `SwapsLabel = "%d swap(s)"` and `LeaksLabel = "⚠ %d leak(s)"` (`TraceInspectorViewModel.cs:60-61`). No body-captured indicator. No status-code colored dot (macOS `statusDot` + `statusColor` 291-302).

#### Feature: Detail header meta cells — Profile / Latency / Request / Response / Time
- **macOS source**: `metaCell` `452-457`, used at lines `346-355`. Sizes formatted via `ByteCountFormatter.string(fromByteCount:countStyle:.file)`.
- **Windows status**: PARTIAL.
- **Detail**: Windows shows only Host + Path (`TraceInspectorView.xaml:67-70`). No Profile/Latency/Request-bytes/Response-bytes/Timestamp summary in the detail pane (Latency/Time exist in the list row only).

#### Feature: Leaks section in raw detail (red, exclamation shield, header + value preview + suspicion reason)
- **macOS source**: `rawDetail` `384-402`.
- **Windows status**: OK.
- **Detail**: Windows shows leaks as red text lines (`TraceInspectorView.xaml:92-107`). Functional parity though less visually elaborate.

#### Feature: Swap report section (blue, header + fakePreview → realPreview)
- **macOS source**: `rawDetail` `404-422`.
- **Windows status**: OK — `TraceInspectorView.xaml:72-90`.

#### Feature: Request / response body section with size warning + copy-full-content button
- **macOS source**: `rawDetail` `424-437`, `section(... copy:)` `460-496`, `copyableString` `501-505`, `bodyView` `508-528`.
- **Windows status**: MISSING.
- **Detail**: Windows detail pane has NO request/response body rendering. The macOS view best-effort decodes UTF-8, falls back to hex preview for binary, has a Copy button per body that puts the FULL content on the clipboard (not just lineLimit-truncated). All missing. Users can't see request/response bodies, copy them, or even know if they were captured.

#### Feature: "Reload from disk" button + record count footer
- **macOS source**: `list` footer `131-148`.
- **Windows status**: PARTIAL.
- **Detail**: Windows has a "Refresh" button at the top (`TraceInspectorView.xaml:33-37`) bound to `RefreshCommand`. No "%lld records (last %lld in memory)" footer count. Auto-refreshes via `DispatcherTimer` 2 s (`TraceInspectorViewModel.cs:28-31`). On macOS the `TraceStore` is `@Observable` so updates push automatically; Windows polls — different mechanism, observable behaviour roughly equivalent (2 s lag).

#### Feature: Keyboard navigation (↑/↓/PgUp/PgDn/Home/End) in the list
- **macOS source**: `moveSelection(by:proxy:)` + `.onKeyPress` handlers `122-128`, `196-216`.
- **Windows status**: PARTIAL.
- **Detail**: `DataGrid` ships with arrow-key navigation by default, but the macOS view scrolls the new selection into the center anchor (`proxy.scrollTo(target, anchor: .center)`) explicitly — Windows DataGrid bring-into-view behaviour is sufficient. PgUp/PgDn delta 10 (macOS) vs page-size (Windows) — close enough. Home/End — handled by DataGrid. Mostly OK.

#### Feature: Status-code coloring (2xx green / 3xx blue / 4xx orange / 5xx red)
- **macOS source**: `statusColor(_:)` `294-302`.
- **Windows status**: MISSING.
- **Detail**: Windows status column is plain text (`TraceInspectorView.xaml:54`). No color cue.

#### Feature: Search across traces (host substring)
- **macOS source**: `hostFilter` TextField → `filteredRecords` 218-227.
- **Windows status**: PARTIAL.
- **Detail**: Windows filters on Host OR Path (slightly more permissive — `TraceInspectorViewModel.cs:42-46`); macOS filters Host only. Net coverage roughly equivalent. macOS shows the count of filtered vs. in-memory records ("12 records (last 200 in memory)"); Windows doesn't.

#### Feature: JSON pretty-print of bodies
- **macOS source**: Not done — body is just UTF-8 decoded `Text`. The Conversation tab is where the structured parser kicks in.
- **Windows status**: N/A on macOS, MISSING on Windows (no body view at all).

#### Feature: Body-size warning
- **macOS source**: Not explicit, but body is `lineLimit(40)` + `truncationMode(.tail)` so long bodies are clipped in render but copied fully via the Copy button.
- **Windows status**: MISSING (no body render at all).

#### Feature: Export traces
- **macOS source**: NOT present — copying body content is the only export. The `store.reload()` button can be considered a session-bound refresh, not export.
- **Windows status**: MISSING (also not present on macOS — parity OK).

#### Feature: Initial profile filter pre-selection when opened from per-session toolbar
- **macOS source**: `init(... initialProfileFilter:)` `23-29`.
- **Windows status**: MISSING.
- **Detail**: Windows can only open the global trace inspector via the sidebar; no "show only this session's traffic" entry point.

---

## Part E — SetupViews (first-run + init progress)

Included for cross-reference because the picker hands off to setup when no base image exists.

#### Feature: Welcome view (icon + title + description + "Get Started" button)
- **macOS source**: `SetupView` `132-165`.
- **Windows status**: Cross-checked in audit 06; covered by `WelcomeView.xaml`. Visually different but functionally OK.

#### Feature: Determinate progress bar driven by installer log-line count + console disclosure
- **macOS source**: `InitProgressModel` `12-126`, `InitializingView` `171-283`.
- **Windows status**: Outside this audit's scope; `InitProgressViewModel.cs` is in `git status` modified — refer to setup-flow audit.

---

## Summary by severity

Severity scale used:
- **HIGH** — feature is unreachable from the Windows UI, materially limits usability or security.
- **MEDIUM** — feature is partially present or has UX regressions.
- **LOW** — visual / cosmetic / branding deltas, or minor missing affordances.

### HIGH — 17 gaps

1. **MCP server editor pane entirely missing** (Part A6). Model + builders exist; no UI. Users cannot configure MCP servers.
2. **Conversation view entirely missing as a UI surface** (Part B). Parser ported, no consumer. Trace inspector has no chat view.
3. **Trace Inspector: no body rendering, no copy-bodies** (Part D, "Request / response body section"). Users can't inspect captured request/response bytes.
4. **Trace Inspector: no Conversation/Raw mode toggle** (Part D). Even if a body parses as a chat exchange, no way to surface it.
5. **Editor: Agent pane missing — multi-tool config, primary/additional, Bedrock model ID** (Part A2). Cannot enable Claude + Codex in one profile.
6. **Editor: Appearance pane entirely missing** (Part A8). No font/cursor/colors/opacity/Terminal-defaults reset.
7. **Editor: Resources pane entirely missing — memory, network mode, storage stack** (Part A9). Cannot tune RAM or switch to bridged.
8. **Editor: Storage layer reset actions (Erase home / Reset to base) absent** (Part A9). No way to wipe a profile's disk/home without leaving the app.
9. **Editor: SSH key import lacks passphrase + public-key blob capture** (Part A4). Per-key require-approval gating depends on the public-key blob, which Windows doesn't capture.
10. **Editor: AWS SSO discovery from `~/.aws/config` missing** (Part A4). Users with SSO must type profile names verbatim.
11. **Editor: kubeconfig file import + client-cert / exec-plugin auth modes missing** (Part A4). Only bearer-token auth reachable.
12. **Editor: Docker config.json import missing** (Part A4). No bulk-import path.
13. **Editor: Subscription-token swap state row (Claude / Codex) missing** (Part A7). Users can't reset "Never for this profile" decisions.
14. **Editor: Git identity fields not exposed in Credentials tab** (Part A4). Cannot configure `user.name`/`user.email` via UI even though fields exist on model.
15. **Editor: DigitalOcean token block not exposed in Credentials tab** (Part A4). Fields on model, no UI.
16. **Editor: Delete confirmation missing** (Part A11). Misclick destroys profile + SSH key irrecoverably.
17. **Profile model fields missing entirely**: `MemoryGB`, `NetworkMode`, `BridgedInterfaceID`, `CloseAction`, `Comments`, `KeyboardLayoutOverride`, `KeyRepeatDelayMs`, `KeyRepeatRateHz`, `CursorShape`, `CustomFontFamily`, `CustomFontSize`, `CustomBackgroundHex`, `CustomForegroundHex`, `WindowOpacity`, `SshKeyRequiresApproval`, `SubscriptionTokenSwap`, `CodexTokenSwap` (Profile.cs only carries the subset listed in this audit).

### MEDIUM — 17 gaps

18. **Color picker has no visual swatches** (Part A1) — and the profile list row uses `AccentBrush` regardless of `Color`.
19. **Trace level picker has no inline help text** (Part A1).
20. **Trace level pane wiring scattered**: macOS has dedicated Tracing pane with prominent body-capture explanation; Windows scatters across General.
21. **Folders pane shows full path only (no name + path two-line layout)** (Part A3).
22. **Per-forge git-token grouping flattened to one expander** (Part A4). No host-specific create-token launchers.
23. **AWS pane missing "Default region" + "Open IAM page" affordances** (Part A4).
24. **Manual token row has no reveal-secret eye toggle** (Part A4). PasswordBox is always masked.
25. **Reveal-secret toggle missing across all secret rows** (Part A11).
26. **Open-token-page launchers missing across forge rows** (Part A11).
27. **Editor footer says "Edits persist on every change"** — explicit Save/Cancel + dirty-state revert missing (Part A11). Cancel does nothing.
28. **Profile name validation gate missing** — empty-name profiles savable (Part A11).
29. **Picker row: running indicator + compromised badge missing** (Part A12).
30. **Picker row context menu missing — Launch/Edit/Duplicate/Reset/Delete unavailable** (Part A12). No Duplicate command in VM at all.
31. **Picker: ⌘N (Ctrl+N) shortcut missing** (Part A12).
32. **Approvals: profile name shown as 8-char GUID prefix, not name** (Part C).
33. **Approvals: row icons + color coding missing** (Part C).
34. **Approvals: empty state placeholder missing** (Part C).

### LOW — 14 gaps

35. **Editor sidebar: gradient icons + colored category blocks → flat tabs** (Part A11).
36. **Env var name validation feedback missing** (Part A5).
37. **`IsSecret` env var flag on Windows isn't on macOS** (Part A5) — minor model divergence.
38. **MCP automation pane: MCP-client config snippet not displayed** (Part A10).
39. **Non-loopback bind-address warning missing** (Part A10).
40. **`Imported from…` badges (AWS SSO, Docker login, kubeconfig) not surfaced anywhere** (Parts A4) — macOS doesn't really have them either; treat as parity LOW.
41. **Picker: launch button tinted to profile color + meta line (tools+auth+folders+SSH+RAM)** missing (Part A12).
42. **Trace Inspector: vertical (top/bottom) split instead of horizontal (left/right)** (Part D).
43. **Trace Inspector: no status-code coloring** (Part D).
44. **Trace Inspector: no body-captured indicator on row** (Part D).
45. **Trace Inspector: no detail-header meta cells** (Profile/Latency/Request bytes/Response bytes/Time) (Part D).
46. **Trace Inspector: no "Conversations only" filter** (Part D).
47. **Trace Inspector: no profile filter** (Part D).
48. **Trace Inspector: no record-count footer + reload-from-disk button** (Part D).

### Cross-cutting / structural

- The macOS picker doubles as a launch screen; the Windows port routes launching through `SessionsViewModel`. Architecturally fine; UX gap is the "selected profile glance" meta strip absent from the Windows picker.
- `ProfileEditorWindow` on Windows is a single shared `ProfilesView` UserControl with `EditorOnly = true` to hide the picker column — clever reuse but means the "selected pane on open" feature (`bromureACSelectEditorCategory` AppleScript bridge) has no equivalent (no automation route to deep-link to a tab).
- The macOS `ProfileColor` swatch UI, `GradientIcon`, `StorageLayerRow`, `ToolConfigCard`, and several other reusable views give the editor a "browser settings" aesthetic that the WPF TabControl-based port doesn't approach. Visual polish is a HIGH-frequency LOW-severity gap.

---

## Total gap count: 48 (17 HIGH, 17 MEDIUM, 14 LOW)
