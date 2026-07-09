# Native Terminal Plan — replace Framebuffer+X11 with host-rendered PTYs

Status: Phases 0–1 implemented on branch `worktree-ghostty` (ghostty pinned
at v1.3.1 via `tools/ghostty.commit`; xcframework built by
`tools/build-ghostty.sh`; native path behind the per-workspace
"Native terminal (experimental)" toggle). Phases 2–4 not started.
Scope: bromure-ac only. The browser product keeps its framebuffer; nothing in
`Sources/SandboxEngine/Resources/vm-setup` (browser image) changes.

## Motivation

Today the agent-coding VM runs Xorg + kitty (on Mesa llvmpipe — every frame is
software-rendered on guest CPU, see `LIBGL_ALWAYS_SOFTWARE=1` in
`Resources/vm-setup/setup.sh`) purely to draw terminals, which the host then
displays as pixels through `VZVirtualMachineView` (`SessionPane.swift`,
`FramebufferView`). Consequences:

- Only one tmux window is visible per VM at a time — a grid/split view is
  structurally impossible (one framebuffer per VM).
- A stack of workarounds exists solely because the terminal is remote pixels:
  `ScrollBridge.swift`, the kitty shortcut marker files
  (`UbuntuSandboxVM.swift:135`), `TerminalAppDefaults` → kitty config
  translation, host-DPI → kitty font-size plumbing, `scroll-agent.py`,
  `keyboard-agent.py`, the spice-vdagent clipboard chain, xorg input confs.
- Guest CPU burns on compositing; text is blurry vs. native Retina rendering;
  no native selection/copy, IME, or accessibility.

Target: terminals become **host-native views fed by PTY bytes over vsock**;
tmux (already authoritative for the tab model) stays in the guest as the
session/persistence daemon. This is the architecture Supacode, cmux, and
Superset converged on — except our state daemon (tmux-in-VM) already exists.

## What already exists (leverage, don't build)

| Piece | Where | Notes |
|---|---|---|
| Interactive PTY over vsock | `Sources/AgentCoding/Resources/vm-setup/shell-agent.py` `_run_interactive` | vsock port 5800, guest-initiated pool. JSON request `{cmd, interactive: true, cols, rows}` → `pty.fork()` → framed pump |
| Frame protocol | same, host twin in `CLICommands.swift` (`InteractiveExec`, `sendFrame`) | `[u8 type][u32be len][payload]`; DATA=0, RESIZE=1 (`u16be cols, u16be rows`), EXIT=2 (`i32be code`), EOF=3 |
| Host-side pump | `CLICommands.swift:1179` `InteractiveExec.run` | raw-mode stdio ↔ framed stream, SIGWINCH → RESIZE, Ctrl-] overlay hook |
| Control-socket exec route | `AutomationServer.swift` (`/vms/{id}/exec`, `handleExec`) | interactive mode hijacks the client fd and bridges to a pooled `ACShellProxyConnection` |
| tmux as tab authority | `SessionWindow.swift` `TabsModel`/`applyTabList`, roster ticks in `BromureAC.swift` | Tab index == tmux window index; worktree tabs carry `worktreeBranch` |
| Per-tab agent status | `BromureAC.swift:1004` | Claude hook keyed by tmux window index — drives grid cell status borders for free |
| Single-mount stage | `UnifiedSessionWindow.swift:389` `mountSelected(_:)` | the exact seam the grid replaces |

## Key decisions

1. **Terminal emulator: libghostty** (full library, Metal renderer), vendored
   as a pinned-commit `GhosttyKit.xcframework` we build ourselves.
   Rationale: production-proven multi-surface embedding (Ghostty.app, cmux,
   Supacode at 50+ surfaces), kitty graphics protocol support, best-in-class
   rendering. SwiftTerm remains the documented fallback (pure-Swift, feeds
   bytes directly, no Zig) if GhosttyKit packaging stalls — the transport and
   grid layers below are emulator-agnostic by design.
   Prototyping with `Lakr233/libghostty-spm` (prebuilt, patched) is fine;
   **ship** only our own pinned build.

2. **Attach model: tmux grouped sessions.** Two clients on one tmux session
   mirror the same active window, so each terminal view gets its own *grouped*
   session sharing the `bromure` window set:
   ```
   tmux new-session -t bromure -s view-<uuid> \; set -s destroy-unattached on \;
        set -s status off \; setw aggressive-resize on \; select-window -t <idx>
   ```
   Independent current-window per view, shared windows/processes, session
   auto-destroys when the view detaches. (Later refinement, not v1: tmux
   control mode à la iTerm2 `-CC` for host-native scrollback.)

3. **Surface I/O: helper subprocess per surface.** libghostty spawns and owns
   each surface's command; it cannot adopt an fd. Each surface runs
   `bromure-ac __attach-window <vm> <window-idx>` — a thin hidden subcommand
   that is `InteractiveExec.run` minus the overlay: raw stdio ↔ control socket
   ↔ vsock ↔ guest PTY. This is exactly today's `vm attach`
   (`CLICommands.swift:277`) pointed at one window. Zero new transport.

4. **Pool starvation must be fixed first.** `shell-agent.py` has
   `POOL_SIZE = 4` and replenishes only when a connection *closes*. A grid of
   N long-lived terminals would exhaust the pool and starve roster ticks and
   `exec`. Fix in the guest agent: replenish immediately when an interactive
   session **starts** (not ends), and lift the cap on concurrent interactive
   sessions (they're cheap: one thread + one PTY each).

## Phases

### Phase 0 — GhosttyKit packaging spike (isolated, no app changes)

Deliverable: `tools/build-ghostty.sh` producing `GhosttyKit.xcframework` from
a pinned ghostty commit, and a 200-line scratch app proving 4 surfaces render.

- Pin a ghostty commit (record in `tools/ghostty.commit`); build with the
  matching Zig (0.15.x; use Homebrew zig — Xcode-bundled linker issue is
  patched there).
- `zig build` → `libghostty.a` + `include/ghostty.h` + `module.modulemap` →
  `xcodebuild -create-xcframework`. Copy Ghostty's resource bundle
  (terminfo `xterm-ghostty`, shell integration) — without it terminals
  misbehave.
- Add as SPM `binaryTarget` in `Package.swift`, dependency of `bromure-ac`
  only. Extend `build.sh` to copy the ghostty resources into the app bundle
  (same pattern as the existing `Bundle.module` copy).
- CI: Jenkins (`Jenkinsfile.ac`) needs zig. Cache the xcframework keyed on
  `tools/ghostty.commit` so most builds skip the zig step. Do NOT commit the
  xcframework to git (~100 MB); artifact cache only.
- Spike acceptance: scratch app shows 4 concurrent surfaces running `htop`,
  clean teardown (no crash on rapid open/close ×50 — teardown races are a
  known libghostty sharp edge; retire surfaces like we retire VZ sessions).

### Phase 1 — Native terminal path behind a toggle (framebuffer untouched)

Deliverable: a per-workspace "Native terminal (experimental)" toggle that
renders the selected tab natively; framebuffer remains the default. Both paths
can coexist live on one VM — they're two views of the same tmux session.

Guest (`Sources/AgentCoding/Resources/vm-setup/shell-agent.py`):
- Replenish-on-claim for interactive sessions (see decision 4).
- Handshake gains `{"window": <idx>, "view": "<uuid>"}`; when present the
  agent runs the grouped-session attach from decision 2 instead of a plain
  shell. (Keeps the protocol change server-side; host still just sends JSON.)
- Set `allow-passthrough on` on the `bromure` session (kitty graphics via
  tmux, harmless otherwise).

Host — new files under `Sources/AgentCoding/Terminal/`:
- `GhosttyApp.swift` — process-wide `ghostty_app_t` singleton: runtime config,
  wakeup→main-queue tick, action callback fan-out (title, bell,
  child-exited), clipboard callbacks → `NSPasteboard`.
- `TerminalSurfaceView.swift` — NSView (CAMetalLayer) wrapping
  `ghostty_surface_t`; NSEvent → `ghostty_surface_key/mouse/text`; frame
  changes → `ghostty_surface_set_size`; first-responder handling. Surface
  command = `__attach-window` helper (decision 3). Config: font/colors mapped
  from `TerminalAppDefaults` (host-side this time — no kitty translation).
- `TerminalSessionController.swift` — owns (profileID, windowIndex) →
  surface lifecycle; reattach-on-exit with backoff (a dropped vsock or VM
  reboot = respawn helper; tmux holds state so this is cheap); retire-don't-
  free teardown discipline.
- CLI: hidden `__attach-window <vm> <idx>` subcommand in `CLICommands.swift`
  (refactor `InteractiveExec.run` internals; no behavior change to `vm
  attach`).
- UI: `SessionPane` grows a `nativeTerminalView` alternative to `vmView`;
  `mountSelected` mounts it when the toggle is on. Kill `ScrollBridge` usage
  on this path (tmux mouse mode on for view sessions; option-drag = native
  selection).

Acceptance: claude-code TUI, vim, htop all correct; resize reflows; ⌘C/⌘V,
scroll, CJK input work; toggling back to framebuffer shows the same session;
`swift test --filter AgentCodingTests` green (add frame-codec round-trip +
grouped-session command-builder tests).

### Phase 2 — Grid view (the actual feature)

Deliverable: a grid mode on the stage showing N terminals at once — all
worktree tabs of one VM, or a cross-VM fleet view. This is where FleetView
finally exists.

- `TerminalGridModel` — cells = (profileID, windowIndex), derived from
  `TabsModel` + the roster; layout 1/2×1/2×2/3×2/3×3 by count (cap 9 v1,
  paginate beyond).
- `TerminalGridView` — replaces the single mount in `paneSlot` when grid mode
  is active (`mountSelected` becomes `mountStage(_ mode:)`). Cells:
  `TerminalSurfaceView` + header (branch name, VM, agent status color from
  the existing per-window Claude-hook status). Click = keyboard focus;
  double-click or ⌘↩ = zoom to single-pane; Esc = back to grid.
  Unfocused cells are read-only viewers (input only to focused cell).
- Sidebar/toolbar entry points: "Show all worktrees" on a VM; "Fleet view"
  across running VMs. Pop-out (`TabbedSessionWindow`) gets the same grid
  mode.
- Perf note: libghostty throttles unfocused surfaces; 9 cells ≈ 18 background
  threads — measure, but expected fine. Suspended/off VMs render as inert
  cards (reuse `EmptyStageView` visuals) in fleet view.

Acceptance: 3×3 grid over ≥2 VMs stays smooth while agents stream output;
cell teardown on worktree close leaks nothing (Instruments pass); status
borders update from hooks.

### Phase 3 — Native by default, slim the image

Only after Phase 2 has soaked.

- Default new workspaces to native; framebuffer becomes a per-workspace
  "Legacy display" escape hatch for one release, then removed.
- Image (`Resources/vm-setup/setup.sh`): drop kitty/xterm, xinit/Xorg + all
  xorg confs, the kitty config block, spice-vdagent; boot target becomes
  tmux on a getty (keep a serial console for recovery).
- Remove the legacy guest Python agents that exist only to serve the
  framebuffer/X11 path, plus their launch wiring (xinitrc/setup.sh) and
  host-side twins:
  - `keyboard-agent.py` (vsock 5006, host layout → setxkbmap) + the
    host `KeyboardBridge` — native surfaces encode keys host-side, no
    guest X keymap to sync;
  - `scroll-agent.py` (host wheel → tmux copy-mode for the framebuffer)
    + the host `ScrollBridge` — native views use tmux mouse mode;
  - the kitty shortcut marker-file chain and CJK/X11 input plumbing.
  Audit before deleting: confirm no second consumer of each (the
  transport/credential agents — `shell-agent.py`, `bromure-vm-bridge.py`,
  token/AWS/loopback agents — all stay).
- Drop `VZVirtioGraphicsDeviceConfiguration` from `UbuntuSandboxVM` (keep the
  vsock + virtiofs devices). Measure and record: image size, boot time, idle
  CPU/RAM deltas (expect all four to improve; llvmpipe compositing goes away).
- Delete host-side: `ScrollBridge.swift`, kitty font-size plumbing, kitty
  branch of `TerminalAppDefaults`.

### Phase 4 — Remote stage mirroring over the SSH bridge

Deliverable: from host B's bromure-ac, connect to host A (where the VMs live)
and get the **same grid, same layout, same statuses, live** — the experience
is identical wherever the VMs run. tmux-for-GUIs, over the existing embedded
SSH server.

Why this is cheap after Phases 1–3: a grid cell is already
(emulator-agnostic view) + (subprocess helper) + (framed PTY protocol).
Remote = the helper dials SSH instead of the local control socket, and the
grid model is fed by host A instead of the local roster. The emulator, grid
view, and frame codec don't change at all.

Transport — extend `RemoteAccessServer` / `RemoteSSHHandlers`:
- Interactive sessions (PTY + shell) stay forced into `__remote-menu`
  (`RemoteSSHHandlers.swift:260`) — human `ssh` is unchanged.
- Add a machine-client path: SSH `exec`-channel requests with a whitelisted
  verb set (no PTY allocation; the channel is a byte pipe):
  - `bromure attach <vm> <window>` — carries the existing framed protocol
    (DATA/RESIZE/EXIT/EOF) end-to-end into the same host-A code path
    `__attach-window` uses. RESIZE frames stand in for SSH window-change.
  - `bromure state` — one-shot JSON: protocol version, profiles, running
    VMs, tab roster (window index, branch, agent status), and the persisted
    `StageLayout`.
  - `bromure events` — long-lived channel streaming JSON-lines: roster
    deltas, agent-status changes, layout changes. Host B's grid subscribes
    and mirrors.
- One SSH connection per remote host, N+2 multiplexed channels (8 terminals
  ≠ 8 TCP connections). Auth is the bridge's existing ed25519 host key +
  `authorized_keys`; no new credential machinery. Attach capability is not
  new — the remote menu already grants it to authorized keys.

Layout as host-A state:
- `StageLayout` (grid mode, ordered cells as (profileID, windowIndex),
  focused cell) becomes a serializable, persisted property of the workspace
  on host A — not transient window state. The local GUI, and every remote
  client, render from it.
- Connecting from B reproduces A's layout exactly; layout edits made on B
  (rearrange, zoom, add cell) are sent back (`bromure layout set`) so A and
  any other client converge — same experience everywhere. A `--detached`
  local-only arrangement mode is explicitly not v1.

Host B UI:
- "Remote hosts" section in the sidebar (add host = address + port + client
  key; store under the existing remote/ support dir). Expanding a host lists
  its VMs/tabs from `bromure state`; fleet-view and per-VM grids work
  identically, cells spawn `__attach-window --remote <host> <vm> <idx>`.
- Reconnect with backoff on channel or connection drop (reuse
  `TerminalSessionController`'s respawn loop); tmux on host A's VMs holds
  all state, so reconnect is a repaint, not a loss. Cells show a
  "reconnecting" veil meanwhile.

Constraints / notes:
- Host A must be running the bromure-ac app (VMs live in its process). It
  can sit headless-ish on a rack Mac mini with the GUI closed, but this
  phase does not build a separate daemon.
- Version skew: `bromure state` leads with a protocol version; refuse major
  mismatches with a clear error.
- WAN friendliness: SSH channel windowing provides backpressure; tmux
  coalesces redraws. Keystroke echo pays one network RTT — same as any ssh;
  rendering stays local to host B, which is the point.
- Bind guidance unchanged: keep the bridge on a VPN/Tailscale interface.

Acceptance: 8-cell grid on A; from B, add host → fleet view shows the
identical 8-cell layout with live status borders; typing in any cell
round-trips; pull A's network cable → cells veil and recover on reconnect;
close a worktree on A → the cell disappears on B via the event stream;
rearrange the grid on B → A's stage matches.

## Risks & mitigations

- **libghostty API flux (no tagged release).** Pin the commit; upgrade
  deliberately; the emulator sits behind `TerminalSurfaceView` so a SwiftTerm
  swap stays possible.
- **Surface teardown races** (upstream issue class, e.g. use-after-free on
  free-during-present). Retire pattern + serialize teardown on main; soak
  test in Phase 0.
- **Pool starvation / vsock churn.** Fixed at the source in Phase 1 (guest
  replenish-on-claim); reattach loop with backoff hides transient drops.
- **tmux-owned scrollback/selection** (alt-screen). v1: mouse mode +
  copy-mode, native option-drag. The real fix (control mode) is deliberately
  deferred.
- **Zig on CI.** Cached xcframework keyed by pinned commit; zig runs only on
  bumps.
- **Remote layout divergence** (Phase 4): two clients editing the stage
  concurrently. Last-writer-wins on host A with the event stream echoing the
  result to all clients; layout writes are whole-`StageLayout` replacements,
  so there's no partial-merge state.
- **SSH bridge surface area** (Phase 4): the exec-verb whitelist is parsed
  host-side before anything runs; verbs map to in-process handlers, never to
  a shell. The bridge already grants attach via the menu, so the capability
  set is unchanged — but the doc (`REMOTE_CONTROL_AC.md`) must be updated to
  describe the machine-client verbs.
- **Anything graphical left in the AC VM?** Audit found none (no browser in
  the AC image; X11 exists to run kitty). Phase 3 audit re-verifies before
  deletion.

## Explicitly out of scope

- Browser product image/display — untouched.
- tmux control mode (`-CC`-style) integration — future work.
- Replacing the TUI (`RemoteMenu`/`TUI.swift`) — it's already text over SSH
  and benefits unchanged.
