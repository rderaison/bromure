# What the web/Electron client does NOT port (or ports differently)

The web client (hosted at bromure.io/client and the Electron app for Linux &
Windows) mirrors the macOS fat client. This file lists every capability that
could not be carried over, or that works differently, and why.

## Platform-wide

- **SF Symbols** can't ship off Apple platforms (license). Every symbol is
  mapped to the closest Lucide glyph (`src/ui/icons.tsx`); shapes differ slightly.
- **SF Pro / SF Mono** are only used where the OS has them (macOS browsers).
  Elsewhere the bundled Inter Variable and the platform monospace render —
  metrics are close, not identical. Electron and the hosted app render the
  same on the same OS.
- **Window chrome.** The hosted app has no window controls (the browser owns the
  window), so the traffic-light area is an empty strip; Electron draws working
  macOS-style controls in the same spot. Secondary windows (Security, Settings,
  boards…) are in-app floating windows, not OS windows, in both shells.
- **Liquid-glass / vibrancy materials** are approximated with CSS
  `backdrop-filter`; there is no NSVisualEffectView behind-window blur.
- **Keyboard shortcuts** use Ctrl on Linux/Windows where macOS uses ⌘. Browser-
  reserved chords (Ctrl+W, Ctrl+T, Ctrl+N in a browser tab) can't be captured by
  the hosted app; Electron captures them.

## Transport / connection

- **Direct P2P rungs** (LAN host candidates, PCP/NAT-PMP port mapping, TURN-TCP/
  TURN-TLS relay) are not implemented in the web client: a browser can't open raw
  sockets. Peers are reached through the bromure.io **ws-relay** (opaque bytes,
  SSH stays end to end). Electron also uses the ws-relay for peers; it connects
  directly only to hosts saved by address.
- **System `ssh` / ControlMaster / ssh-agent** are not used: the client embeds
  its own SSH implementation (WebCrypto) with an Ed25519 key that never leaves
  the browser's key store (non-extractable).

## Security windows

- **Machine filter / "This Mac".** The Mac's Security window can mix this Mac's
  events with every mirrored host's (an "All machines / This Mac / <host>"
  pop-up, "host · workspace" in the Workspace column, the host in the
  search). A web window mirrors exactly one host, so the pop-up and the
  host prefix are omitted; the CSV's `machine` column is the host's name.
- **Protections (Overview).** The native fat client judges postures from the
  minimal profiles in `/state` (so most columns show defaults). The web reads
  each workspace's full profile (`GET /profiles/<id>?full=1`) and judges it
  like `SecurityPosture(profile:)`; the egress-ruleset "is active" and the
  OpenShell "confines guest" checks are text heuristics, not the Swift
  parsers, and the guest's reported sandbox status isn't available. A cell
  click dispatches `bromure:open {what:'settings', profileID, category}`.
- **Firewall / supply-chain quick actions** on Timeline rows are shown
  disabled with the remote-row tooltip, exactly as the Mac does for a mirrored
  host's rows ("Change this workspace's firewall rules in its settings on the
  Mac that runs it.").
- **OCSF ▾.** "Write OCSF JSON logs" streams the LOCAL engines' raw events to
  daily files and "Show OCSF Logs in Finder" opens them — neither applies to a
  mirrored host (its own setting writes its logs on the host). The web menu
  offers **Export OCSF JSON…** (the rows shown, as JSONL) and the schema
  choice (1.8.0 / 1.3.0 downgrade). Rows carry engine/condition/decision, not
  the raw event, so the OCSF class mapping is by engine and the raw fields go
  under `unmapped`.
- **Clear** empties the window's copy; as on the Mac's fat client, the host's
  next head refills it (the host's log is the audit trail).
- **Default range** is 24 h: Preferences › Tracing's default range is a
  UserDefaults value on the Mac, not mirrored.
- **Relative times** in Latest blocks ("4 min. ago") and the Timeline's date
  format follow the browser locale, English abbreviations only.
- **Table**: column widths are the native defaults (resizable by dragging
  header edges); no column sorting (the Swift table has none). Selection is
  click / ⇧-click / Ctrl-click; Return or double-click opens a row's lineage.
- **SF Symbols** for the tiles/engines are Lucide glyphs; the filled
  "checkmark.circle.fill" / "xmark.circle.fill" marks are drawn as tinted
  discs.
- **Alert sheets** (host prompts, compromise remedies) are drawn in the page,
  not NSAlert: the app icon is a shield glyph; button order/Return/Escape
  follow NSAlert (first button rightmost; no Return on "Wipe").
- **Credential Approvals…** (Window menu) lists the LOCAL consent broker's
  grants; there is no remote route, so it is not available on a mirrored host
  (the Mac's fat client doesn't offer it either).
- **Trace Inspector**: WebSocket-captured conversations (Codex sessions) are
  not rebuilt turn by turn (raw view only); the list pane has a fixed 460pt
  width (native: draggable 380–600); materials are flat colours; Copy uses the
  browser clipboard. `?traceDemo=1` (dev relay only) shows sample records.
- **Network lineage**: some step icons are the nearest Lucide glyphs; the
  sheet's subtitle omits the machine label (one host per window); Copy uses
  the browser clipboard.

## Sidebar & toolbar

- **Network tunnel toggle** (RemoteToolbarBar's first icon — direct
  192.168.x.x access to the remote's VMs through a macOS system extension) is
  not offered: a browser/Electron app can't install a host network route.
- **Toolbar** follows UnifiedToolbarBar's layout (dimmed Terminal pill + globe
  while a session's machine sleeps, as in the reference renders) rather than
  the older RemoteToolbarBar order. No **Sandbox drawer** shield
  (PolicyDrawerButton) and no **"Sending…" outgoing indicator** in the strip;
  no **Engine badge / streaming dot**. "Pop Out to Its Own Window" is left out
  of the machine menu (no second OS window per machine); Force Reboot is the
  machine menu opened with Alt held (macOS shows it as an ⌥ alternate item).
- **Context-menu submenus** ("Move to Room", a room's "Color") open as a second
  menu at the same spot (the kit menu has no cascading submenus).
- **Alerts** (delete session/room/workspace, branch fate, reboot, compromise)
  are in-page sheets with stacked buttons, not NSAlert sheets.
- **Search** matches titles, opening messages, folders and @nicknames. The
  macOS app's search through the conversation text (with the words around the
  match) uses this Mac's transcript copies — a fat client has none, so it's
  absent on the Mac's fat client too.
- **Row tooltips** show the machine name, not the agent's last reply (the
  fat client has no local transcript copy).
- **⌘1–9**: off macOS these are Ctrl+1–9 (holding Ctrl shows the numbers);
  the hosted app can't override browser-reserved tab chords in some browsers.
  ⌃⌘S (Ctrl+Alt+S off macOS) folds the sidebar to the rail; dragging the
  divider below 160pt does too.
- **Undo toast** after Archive ("Archived “X” — Undo") is not shown; Unarchive
  is in the row menu and the Archived fold.
- **Virtual Machines**: the row's hover "Pop out" / "Close this VM" buttons
  (no-ops on the Mac's fat client too) are omitted; the Docker node opens the
  dashboard but doesn't list containers/attach tabs underneath; Kubernetes /
  Registries / Connector rows are simplified (name, phase, menu) and their
  actions are dispatched as `bromure:open {what:'kube-action'}`; the messaging
  connector row is not shown. Fleet admission rows (pending/blocked native
  machines) are not shown. Grid drag-and-drop of terminals onto the Grid node
  is not supported (rows can be removed from the Grid by right-click).
- **Unread orb** is a CSS conic gradient turning every 6 s (no glow shader).
- **Agent glyphs** are the app's own SVGs (Resources/icons), so they match;
  the Switchboard's "wand.and.rays" and the Automations "bolt.badge.clock"
  are Lucide stand-ins.

## Connect, palette & new session

- **Connect window is the start screen, not a separate window.** "Connect to
  Remote Bromure" fills the app when no server is open (a 480pt window-style
  card, same layout as RemoteConnectView); ⇧⌘K / the palette return to it and
  its Cancel goes back to the mirror you came from. Electron draws the window
  controls on the card's titlebar.
- **Hosted app: no "add by address".** A browser can't open TCP sockets, so the
  saved-servers half, the +/− control and the address form are hidden there,
  with a caption saying why; every server is a bromure.io peer. Electron (and
  dev, through the local relay) keeps both halves.
- **Peers ride the bromure.io ws-relay only** (`ControlPlane.dialRelay`):
  no P2PBroker direct/TURN path, so "Connecting to X via bromure.io…" is the
  only peer phase. The peer's host key is pinned under the same
  `bromure-peer-<deviceID>` alias the Mac uses, but in this client's own store
  (the pins are not shared with a Mac's known_hosts).
- **No local login name to guess.** The Mac defaults the remote user to its own
  NSUserName(); the web has none, so a peer uses its published `sshUsername`
  (else the one that worked last time) and the add-by-address form requires a
  Remote user (Connect stays disabled until one is typed).
- **Password fallback** follows the Swift (inline retry + shake, editable
  Remote user). An SSH connection allows three password tries; after the
  third the client silently re-dials and keeps asking inline. A server that
  refuses passwords (password sign-in off) shows "Can't connect" with how to
  authorize this device's key, rather than a password field that can't work.
- **Enterprise (managed) identity** doesn't exist off the Mac: the account bar
  always offers Sign Out (no "Managed by your organization").
- **Sign-in on the hosted app navigates this tab** to bromure.io/app/enroll
  (`return_to=/client/`) and completes from `#enroll?…` on return; Electron
  opens the system browser and completes on the `bromure-client://enroll` deep link
  (its own scheme — `bromure://` belongs to the macOS app / Bromure; needs
  bromure.io to honour `return_scheme=bromure-client`).
  Both check the `state` nonce (kept in sessionStorage across the round trip).
- **The menu bar is drawn in the window.** A web page / frameless Electron
  window has no system menu bar, so the native one (Bromure · Workspaces · Edit
  · View · Window · Help) sits in the titlebar strip after the window controls,
  with the items the Mac's fat-client window answers, in the same order, with
  the same key equivalents (⌘ → Ctrl, ⌃⌘ → Ctrl+Alt off macOS) and the same
  context enabling (machine / tab / worktree on stage). Next to it, the
  server pill: Connect to Another Server… / Disconnect / Sign Out of
  bromure.io. Left out because they act on the LOCAL Mac only: Rebuild Base
  Image…, Base Image…, Install Command-Line Tool…, Hide/Hide Others/Show All,
  Messaging Connector…, Quick Task…, Open ext4 file…, Copy Pane History,
  Toggle Sandbox Drawer, Inference Metrics…, Credential Approvals…, Inference
  Engine Log…, New Workspace from configs. The hosted app's Edit › Paste is
  disabled (a page can't read the clipboard from a menu click; the shortcut
  works). Off macOS a terminal keeps its own Ctrl chords unless Shift/Alt is
  held; in the hosted app the browser reserves Ctrl/⌘+N/T/W.
- **Palette "In conversations" (transcript search)** isn't offered — the Mac
  fat client doesn't index a mirror's transcripts either.
- **New session: folder drops.** Files (and pasted images) attach; a dropped
  folder can't be read by a browser as a tree, so it isn't packed/uploaded.
  The "@" mention palette in the opening message isn't ported yet.
- **Footnote copy off macOS** uses the Mac app's mobile variant ("…on your Mac,
  not on this device"), since the client isn't the Mac.

## Session stage & chat

- **Typing into the agent** goes only through the server's `POST /vms/<id>/type`
  (the server runs PaneTypeGuard and confirms the Enter). An older server
  without that route can't be typed into from the web: the Mac's step-by-step
  `runType` fallback (menu detection, AgentInputBox Enter confirmation) needs
  the per-agent screen-phrase tables and isn't ported — the message lands on the
  strip as "Not sent".
- **Terminal-screen scanning** (`scanTerminal`: trust-folder / login / picker /
  privacy-notice / approval dialogs as cards, SessionFailure from the screen,
  "screen says busy") is not ported. The chat shows what the transcript says;
  a dialog the agent draws in its TUI is answered in the terminal (View ›
  Terminal). Pending AskUserQuestion rounds ARE live cards (answered with the
  picker keys over guest exec). Host sign-in from a chat card isn't offered.
- **Held / queued messages** are kept in memory for the page's life (no
  `ChatQueueStore` persistence across reloads, no automatic re-delivery once
  the agent is idle): a message that couldn't be typed stays on the strip with
  why, to Edit or delete.
- **Slash-command output cards** (`CommandCard`: the TUI's answer to /cost,
  /model… captured from the screen, the inline live terminal) are not ported;
  a slash command is typed and its answer is in the terminal view. The `/term`
  scratch-terminal drawer (and ⌃`) is ported.
- **Session time / tokens / model in the header** (the stopwatch flamegraph,
  token gauge, model from the transcript index) aren't shown: the web has no
  transcript search index. The model shows when the server sends `lastModel`.
  The Squelch item shows its on/off icon only (no savings popover).
- **New Branch…** is a reduced sheet: no git-state probe, no "Start from" base
  branch picker, no `.worktreeinclude` note. It starts the worktree session
  through the same route.
- **Display MCP cards** (show_media / show_chart / send_file) show the
  request (title, path, caption, chart spec) instead of the picture/chart:
  reading guest files as images and a Vega renderer aren't ported.
- **Markdown** is a small built-in renderer (no MarkdownUI): code fences get a
  light keyword/string/comment highlighter instead of highlight.js themes;
  ```mermaid fences render as code, not diagrams.
- **Reply chunking / render windowing** (2000-char row pieces, lazy-stack
  budgets) isn't needed in the DOM: replies render whole, a huge reply (>40k
  chars) or long message of yours collapses with Show all.
- **Dropped folders** can't be read by a browser as a tree: files and pasted
  images attach and upload (guest file ops); folders don't.
- **Demo fixtures:** fixture sessions (no VM) read the server's copy of their
  conversation (`GET /agent-sessions/<id>/transcript`); dev runs can instead
  serve the fixture dir and pass `?fixtures=<base-url>`.

## Terminals & rooms

- **libghostty → xterm.js.** The macOS surface is libghostty (Metal renderer,
  GPU shaders, its own font shaping/ligatures, kitty keyboard protocol, kitty
  graphics). The web uses xterm.js 6 with the WebGL renderer (falls back to
  xterm's DOM renderer — xterm 6 has no canvas addon) + unicode11 + web-links.
  No ligatures, no custom shaders, no ghostty font-feature settings; glyph
  rasterization differs slightly.
- **Image protocols** (kitty graphics, sixel, iTerm inline images) are not
  rendered. The Mac also disables them by default (`image-storage-limit = 0`
  unless `terminal.allowGraphics`); the web has no opt-in.
- **Terminal.app defaults.** The Mac seeds a workspace without its own
  appearance from this Mac's Terminal.app default profile (font, size,
  colours). A browser can't read it, so the web uses the shipped fallback
  (`TerminalAppDefaults.fallback`: JetBrains Mono 14, #c9d1d9 on #0d1117) with
  ghostty's default 16-colour palette. Workspace overrides (fontFamily,
  fontSize, backgroundHex, foregroundHex in /state) apply as on the Mac.
- **Fonts.** JetBrains Mono / SF Mono are used only when installed on the
  viewer's OS (no font is bundled); otherwise Menlo / Cascadia Mono / DejaVu
  Sans Mono / Consolas. Cell metrics follow the face actually used.
- **Copy/paste chords.** Linux/Windows use Ctrl+Shift+C / Ctrl+Shift+V (plain
  Ctrl+C must stay ^C); macOS keeps ⌘C / ⌘V. Font zoom is ⌘/Ctrl = - 0. Links
  open on ⌘/Ctrl-click. ⌘T / ⌘W are browser-reserved in the hosted app (they
  work in Electron).
- **Size authority** works as on the Mac (attach `sizePassive`, grant
  `!ignore-size` only while focused with input in the last 3 min), but
  "actively used" is `document.hasFocus()` + this page's own input — the
  browser can't see machine-wide idle time (CGEventSource).
- **Machine tabs** are listed in the sidebar, as on the Mac (the optional
  `MachineTabStrip` above the terminal is off by default — `showTabs`). The
  server has no rename or reorder verb for tabs, so neither client offers them.
- **Boot cue** ports only the dive HUD: the watchdog / disk-failure panels are
  local-only on the Mac too (the fat client wires no-op handlers).
- **Rooms — the zoom shockwave** (a Metal distortion shader) is a CSS ripple
  ring; matchedGeometry zoom is a short scale/fade.
- **Room timeline window** is reduced to one lane per member spanning created
  → last seen, tinted by state; the Mac's per-turn timeline
  (SessionTimelineStore, built from live chat models) isn't available.
- **Room "Remove from Room"** has no undo toast yet.
- **Asleep-target composer** (wakes the session) has no "@" peer-mention
  palette.
- **Scratch terminal**: ⌃` toggling belongs to the chat that hosts the drawer;
  the drawer itself only offers hide (chevron) / close (✕).

## Coding tasks & automations

- **Boards live on the stage**, as natively (their sidebar row selected);
  `openTaskBoard` / `openAutomationBoard` can still detach one into an in-app
  window.
- **Planning conversation window** (Plan First's live interview, tailed from the
  guest and typed into) is not ported: Plan First starts the planner on the
  host; a card that is planning opens its session on the stage instead.
- **Quick Task panel** (⇧⌥Space from any app) can't exist in a browser; New Task
  on the board is the way in.
- **Review window** is a reduced port: summary banner, landing actions and the
  landing confirmation are faithful; the diff is a file list + unified diff with
  per-line and whole-change comments. Not ported: side-by-side view, the
  "viewed" per-file marks, the plan tab, base choices other than
  branch / uncommitted / last commit, and the worktree relocation ("Looking
  for the worktree…") retry loop. The guest diff command keeps the native
  safety (`RepoGitPrograms.off`, `--no-ext-diff --no-textconv`) but drops the
  dirty-submodule listing; the summary's remote pick is the first non-option
  remote, not `BranchMergeCommands.pickRemoteShell`.
- **Drag and drop on the boards** uses HTML5 drag (Backlog reorder, Backlog →
  In Progress to start, Review → Done); no spring-loaded animation.
- **Answer sheet attachments**: files dropped on the sheet go as base64 (11 MB
  cap, like the fat client); folders can't be packed from a browser drop.
- **Live run window**: the native run window embeds the run's live terminal;
  the web one offers "Open Session" (the tab on the main stage) while the run
  is live, then the transcript / outcome view.
- **Transcripts** are rendered by a light reader (Claude Code JSONL, Codex
  rollouts; anything else as text), not the full beautified transcript view.
- **"Load older runs…"** reads the viewer's own run archive in the native fat
  client (always empty for a mirror); the web shows "No archived runs." the same.
- **Automation editor**: the folder "Choose…" guest browser isn't offered (type
  the path); the time picker is the browser's `<input type=time>`; the poll
  status line ("Last check failed…") isn't mirrored by the host, so a saved
  event automation shows only "First check runs within 30 seconds of saving.".
- **Code Review tab** is reduced: Overview is a few stat tiles + a pipeline bar;
  Findings is a list + detail with Fix / Ask the Switchboard / Ask a session /
  status; Repositories lists the watches. The watch editor covers the native
  fields except the reviewed-through marker and the token-rejected check.
- **The "need you" state of a running task** is derived from the mirrored
  session/tab state; against the manual's demo fixture every In Progress card
  shows "Working", as the native DemoMode does.

## Machines, files & branches

- **System-wide network tunnel (utun) / SOCKS forwarder.** The macOS fat client can install a privileged helper that routes the remote host's VM subnet through a local utun interface (and a per-app SOCKS forwarder), so any local app can reach a remote guest's ports. A browser can't create interfaces or listen on sockets, and Electron would need an elevated helper per OS; not ported. The VM dashboard's Listening Ports card shows and copies the endpoints, but they are only reachable from the host's own network.
- **Cloudflare quick tunnels** (the ports card's globe — expose a guest web service at a trycloudflare.com URL) run `cloudflared` as a local subprocess on the Mac; not available in the web client. The globe is omitted.
- **Local browser pane VM** (the fat client's per-workspace Chromium VM next to the stage, and its browser-MCP relay) needs Virtualization.framework on the client; not ported. The toolbar globe explains this instead of opening a pane; agents' browser-MCP calls are then handled by the server itself, exactly as when no Mac client is attached.
- **Remote Access settings** (the server's SSH front door) are changed on the server itself; the palette entry explains where.
- **Files pane drag-out** (dragging a guest file to the Finder/desktop as a lazily-downloaded file promise) has no web equivalent; use the row's context menu › Save to Downloads (browser download / Electron save dialog). Drag-in of files **and folders** works (folders travel as one gzipped tar the guest unpacks, built in the browser).
- **Pop-out file viewer window** (full-screen-capable) is not ported; the preview stays in the pane's split.
- **Syntax highlighting** in the file preview (Highlightr / highlight.js) is not bundled (no new dependencies): source previews are plain monospaced text. Video previews aren't shown (images are).
- **Diff line comments to the agent from the Files pane** (typed into the agent's tab through the pane-type guard) are not ported; the Review window's comments (stored on the server's session record and sent with "Send to Agent") are.
- **Reboot ⌥-force**: hold Alt (Option) while clicking Reboot for a forced reboot — same as macOS, but Alt-click may be captured by some Linux window managers.
- **New Machine** opens the workspace editor's new-workspace flow (editor surface); the credential-scan wizard variant is not offered here.

## Configuration editor

The workspace Settings / Preferences / New workspace editor
(`src/features/editor/`) is the same `ProfileEditorView`, round-tripped like
the macOS fat client: `GET /profiles/<id>?full=1` → draft → `PUT` of only the
changed keys; Preferences via `GET/PUT /preferences` + `/models/settings`;
New workspace via `POST /profiles` (drafted from the host's template).

- **Automation pane** (Preferences › App) is not shown: it edits the local
  Mac's app-wide settings, which a remote editor doesn't target (the macOS
  fat client's remote Preferences hides it too).
- **"Settings for:" picker** (This Mac / remotes) is gone: a web window
  mirrors exactly one host, so Preferences always edits that host's template.
- **Unsaved changes**: closing the window (⌘W / close button) with edits asks
  "Discard your changes?"; the native editor just closes. Cancel discards
  without asking, as natively.
- **Overlay scrollbars**: the detail pane scrolls without a visible bar
  (the macOS overlay look); Linux/Windows have no scroll indicator there.
- **Folders**: no folder browser — shared folders live on the server and the
  client can't share its own disk into a remote VM; "Add folder…" takes a typed
  server path (as on iOS).
- **Browser**: the "Browser image" status and Download/Update/Re-download
  controls are left out (as on iOS) — they manage the local app's image.
- **MCP**: "Authorize with OAuth…" isn't available (localhost callback on the
  host); an existing authorization shows and can be revoked; static tokens work.
- **Resources**: Erase home / Reset to base / Restore home / Upgrade storage are
  done on the server Mac (disabled, as in the macOS fat client). Bridged
  networking can't list the server's interfaces; the server picks one.
- **Appearance**: no Terminal.app profile or local font list — Reset and unset
  values use Bromure's built-in defaults; fonts come from a fixed list.
  ColorPicker is the browser's color input.
- **Credentials**: SSH key "Import…" / "From host agent…" disabled (key files
  and ssh-agent are on the server; same as the macOS fat client). AWS SSO can't
  browse `~/.aws` (type the profile name). Kubeconfig "Import file…" not
  ported. OpenShell "Attach provider profile…" disabled. A redacted singleton
  secret (DigitalOcean, Linear, AWS, Twilio) can't be cleared remotely (blank
  means keep). "Get 1Password CLI" has no equivalent.
- **Guardrails**: no live consent-grant badges / allow-deny-revoke menu (host
  consent broker has no remote route); Credential Approvals window and
  Security History settings are local-only.
- **Models**: sign-in uses the host's sign-in run (`POST /subscriptions/register`)
  and opens its page here; providers needing a localhost OAuth callback can't
  finish from the web (device-code flows work). Agent model menus and the Fusion
  judge list curated ids only (live `/v1/models` needs server-held keys; use
  "Custom id…"). "Test Connection" for a custom server runs from the client
  (a host-only or CORS-less server fails here). On-device catalog = bundled
  baseline + server-reported models. Model menus are flattened (no submenus).
- **Squelch**: savings come from the host's ledger (`GET /squelch`) — the
  macOS fat client shows the client's (empty) ledger.
- **Sandbox Policy (OpenShell)**: guest-sandbox / kernel-sentry / attestor
  status lines, the organization boundary ("Set from file…", "Clear") and the
  org's sentry minimum are host-only — the host enforces them on save. The YAML
  check is a tolerant subset of the native parser. No "rules changed outside
  the editor" banner for the firewall. Import/Export use the browser's file
  picker / download.
- **Supply Chain**: the trusted-packages list doesn't update live when the
  host's override prompt adds one while the editor is open.
- **Prompt Injection / PII**: no model-download confirmation/progress; the
  host downloads the detector model when needed.
