# Bromure Agentic Coding — Remote Fat Client Plan

Make bromure-ac remotely accessible over SSH, as a **fat client**: a local
bromure-ac (host **B**) connects to a remote bromure-ac (host **A**, where the
VMs live) and mirrors A's full UI **1:1** — the grid, the workspaces with their
tabs / worktrees, and the automations. Every change made on either side is
reflected on the other, live. Interactive terminals feel local. The browser
pane renders locally but its page traffic is tunneled so the local browser
hitting `192.168.64.x` actually reaches the **remote** VM subnet.

This is the same idea as the (unimplemented) Phase 4 in `NATIVE_TERMINAL_PLAN.md`
("tmux-for-GUIs, over the existing embedded SSH server"), taken all the way:
full state mirroring, bidirectional edits, a browser pane, system-wide network
encapsulation, and a multi-host fleet.

## Design decisions (locked)

- **Browser pane:** local Chromium VM + subnet tunnel (true fat client), not a
  streamed remote browser.
- **Network reachability:** system-wide — any local process hitting the remote
  subnet is tunneled, via a `utun` interface, not just the browser VM.
- **Fleet:** one fat client mirrors **multiple** remote hosts at once.

---

## Implementation status

**Phases 1–3 are implemented and verified end-to-end** (branch `fat-client`) with two
isolated local instances — a server (SSH enabled) and a client (SSH server off) —
mirroring 1:1 over the tunnel. **Auth UX** (host-key TOFU + password fallback) and the
**Phase 4 network tunnel** are also implemented + verified; the utun/browser-pane
integration and fleet handling remain.

### Phase 4 — network tunnel (implemented + verified)

The reach-the-remote-subnet tunnel works, byte-exact, over SSH:

- **`bromure-fatclient/1 forward <ip> <port>`** SSH exec verb — restricted to the remote's
  vmnet subnet (`VmnetSubnet.containsGuest`). Client side: **`__forward`** (local port →
  remote guest, ssh-L style) and **`__forward-socks`** (SOCKS5 — the browser path; the
  literal destination is resolved on the remote side, so navigating to
  `http://192.168.64.5:3000` reaches the remote guest). `/state` advertises `vmnetSubnet`.
- **THE CRITICAL FINDING** (the spike the plan called for): the plan assumed the server
  could dial its own guests (`http://<guestIP>:<port>`, cloudflared-style). **It cannot** —
  the bromure-ac process **and every child it spawns** get `EHOSTUNREACH` connecting to a
  guest, even though an unrelated process (a terminal `curl`, or `cloudflared` — a
  *detached* subprocess) reaches it fine. So `bromure forward` must NOT dial the guest from
  the app process tree.
- **The fix**: route the forward over **vsock** to the guest's own **loopback-relay
  (vsock 5010, always-on)** — the host connects, sends `"<port>\n"`, and the guest splices
  to its `127.0.0.1:<port>` (where its 0.0.0.0-bound dev server lives). vsock host↔guest
  works reliably; the guest's own loopback trivially reaches the dev server. `forward
  <ip> <port>` finds the running VM whose IP is `<ip>` and uses its vsock 5010 relay
  (`ACAppDelegate.resolveFatClientForward`). Verified: curl over the SOCKS proxy →
  remote `192.168.64.x` dev server, byte-exact.

**Landed since (networking primitives, unit-tested):**

- **Auth is now askpass-free.** The password bootstrap runs through an embedded swift-nio-ssh
  **client** (`FatClientNIOSSH.enrollWithPassword`): password auth + client-key enrollment in
  one connection, no system `ssh`/`SSH_ASKPASS`. (Also fixed a real server bug — the control
  bridge didn't flush `pendingInbound`, so a pipelined request that beat the control-socket
  connect was silently dropped; `startControlBridge` now flushes like the forward bridge.)
- **Auto-SOCKS.** `RemoteHostController` starts a per-host `RemoteSocksForwarder` (ephemeral
  loopback port, stoppable) on connect and reads `/state`'s `vmnetSubnet` (previously dropped).
- **PAC generator** (`FatClientPAC`) — SOCKS for each remote subnet, DIRECT otherwise; CIDR/host
  inputs validated against JS injection; fleet-aware (one clause per host, alias subnets included).
- **Fleet router** (`FleetRouter`) — route literally when the subnet is free, else assign a
  `100.64.<n>.0/24` alias; `remap()` does the host-octet-preserving address rewrite for the relay.

**Still to do in Phase 4:**

- **Browser pane on `RemoteHostWindow`** (the main refactor). `RemoteHostWindow.stage` is
  single-occupant (grid *or* one terminal) — port the `paneSlot | browserPaneHost` right-split
  from `UnifiedSessionWindow` and give `RemoteHostController` the per-`Profile.ID`
  `browserControllers`/`browserModels`. Instantiate `WorkspaceBrowserController` per remote
  workspace on B.
- **Browser data plane wiring** (the primitives above compose here):
  - Add an **explicit-octet knob** to `VMNetSwitch.configure()` (today: only ascending/descending,
    and a no-op after start) and thread it → `startVmnetLocked` → `chooseSubnetOctet`. Pin B's
    browser switch to an octet **disjoint** from the remote's (e.g. 127) so navigating to the
    remote `192.168.64.x` is off-subnet and egresses to the host, where the PAC catches it.
  - Make `WorkspaceBrowserController.browserConfig()` proxy-aware: instead of `directConnection`,
    inject `--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,<FatClientPAC>` via
    `extraChromeFlags`. The PAC's proxy host is the **browser switch gateway** (e.g. 192.168.127.1);
    bind `RemoteSocksForwarder` there (not 127.0.0.1) so the browser VM can reach it.
  - **Empirical check first** (plan spike #1, still unrun): confirm the browser VM's off-subnet
    traffic actually reaches a host-side listener on the gateway before committing this shape.
- **`browser-mcp` relay channel.** New `bromure-fatclient/1 browser-mcp <vm>` verb; server tees
  `BrowserMCPVsockBridge`'s agent JSON-RPC onto the channel (mind the multi-connection id-space
  caveat); client runs a line loop → B's own `BrowserMCPServer.handle(line:)` (transport-agnostic).
  For an aliased host, rewrite the advertised address via `FleetRouter.remap`.
- **System-wide `utun`** (privileged): app-side userspace forwarder over `serveForward` per flow +
  a launchd SMJobBless helper (open utun, hand back fd) + host routes per connected subnet. Needs
  admin consent and the plan's spike #1 (does vmnet-NAT'd off-subnet guest traffic hit a host utun
  route?) run first. SOCKS/PAC is the no-privilege fallback and works without this.

### Phases 1–3

What shipped, and where it differs from the sketch below:

- **Transport = tunnel the control socket, not per-verb channels.** A single SSH `exec`
  verb `bromure-fatclient/1 control` (`FatClient.swift`) bridges the channel to the
  remote's `control.sock` (`SSHPTYSessionHandler.startControlBridge`, RemoteSSHHandlers.swift).
  The client speaks the existing HTTP API over it, so `state`/`attach`/commands are all
  "the control socket, remoted". The **client is the system `ssh` binary** over a
  socketpair (`SSHTunnel.dial`, FatClientRemote.swift) — not a NIOSSH `.client` — which
  removed the biggest greenfield risk. `ControlClient` gained a pluggable `dial` so the
  same `request`/`openStream` (and therefore `InteractiveExec`) run over SSH unchanged.
- **State feed = poll `GET /state`, not a push stream.** New trusted routes
  `/state` `/workspaces` `/grid-layout` `/automations` (+ edits) on `ACAutomationServer`;
  the client's `RemoteHostController` polls `/state` every 0.75s and reconciles into the
  reused `SessionListModel` / `GridLayoutStore` / `ScheduledAutomationStore` / `TabsModel`,
  which the reused `SessionSidebar` + `GridStageView` render 1:1 (`RemoteHostWindow`).
  A dedicated `bromure events` push stream remains a latency optimization, not built.
- **Terminals**: `__attach-window --remote <hostID> <vm> <win>` builds a remote-dialing
  `ControlClient`; `TerminalSessionController`/`GridStageView` thread a `remoteHost` and
  emit that command. Full tmux paint + keystroke→guest→output round-trips confirmed.
- **Bidirectional edits**: tab/worktree/lifecycle/automation/grid verbs POST over the
  tunnel to the same handlers the local GUI uses; last-writer-wins on whole objects.

Three bugs/subtleties found and fixed during the end-to-end bring-up (all load-bearing):

1. **`ControlClient.openStream` still used the hardcoded AF_UNIX `connect`, not the new
   `dial`** — so terminals silently failed over SSH (`agentNotRunning`) while polling
   worked. Fixed to use `dial()`.
2. **`ssh -o` values with spaces** ("Application Support") re-tokenize like a config line
   → must be double-quoted inside the option string; and the **ControlMaster socket path**
   overflows the ~104-char AF_UNIX limit → moved to `/tmp`, keyed by host id.
3. **ControlMaster buffers a multiplexed channel's spontaneous server→client output** (the
   tmux repaint never arrives until the client types). Fix: ControlMaster for cheap
   polling/commands, but a **direct connection for the interactive attach stream**
   (`sshArgs(interactive:)`).

Known limitations (documented, not blockers): a **headless** server has no
`unifiedWindow.gridStore`, so it can't accept/serve grid-layout edits (works when the
server has a GUI window); `SessionSidebar` was made `internal` (was `private`) to reuse it;
prompt-driven worktree ops (new/merge/resolve) aren't remoted (the mirror still displays
all worktrees). Two-instance isolation uses `CFFIXED_USER_HOME` (relocates support dir +
`UserDefaults`); a pure fat client skips the base-image setup + the CLI-symlink modal.

## Why this is mostly already there

Three properties of the current codebase make a fat client far cheaper than it
looks. Each phase below leans on them.

1. **The VM control plane is already IP-free and headless.** VMs outlive their
   windows (persistent-agent model; `runningSessions: [Profile.ID: RunningSession]`,
   `BromureAC.swift:1173`). Everything — lifecycle, tabs, worktrees, exec,
   interactive PTY — is already reachable through an always-on owner-only
   HTTP/1.1-over-AF_UNIX control socket (`control.sock`, served at
   `BromureAC.swift:2037`; path `Profile.swift:2354`). `bromure-ac` already runs
   headless at login via `BootLaunchAgent` (`BootLaunchAgent.swift:15`). **Host A
   needs no new server process — it already is one.**

2. **The UI renders from mirrorable data, not from live VM objects.**
   - The grid is `GridLayoutStore` — `GridCell` is `Codable {profileID, windowIndex, label}`,
     persisted, and its own doc comment calls it *"the StageLayout contract that
     phase 4 mirrors over the SSH bridge"* (`Terminal/GridLayoutStore.swift:28`).
   - A terminal surface's only coupling to a VM is a **child-command string**
     (`Terminal/TerminalSurfaceView.swift:39`, command at `:55`).
   - `FileExplorerModel` already runs off an injected `GuestExecProvider` closure
     *"so the pane keeps working when the VM is remote and no share is mounted"*
     (`FileExplorer.swift:7`).
   - `Profile`, `GridCell`, `GuestTab` rosters, `ScheduledAutomation`,
     `SessionDisk.TabsState` are all `Codable`/`Sendable`.

3. **We own the L2 switch.** `VMNetSwitch` is a userspace MAC-learning bridge
   that sees every raw Ethernet frame; a port is *"just an fd pair"*
   (`VMNetSwitch.swift:151`) and the uplink is already a pseudo-port. The live
   subnet is self-reported (`VMNetSwitch.subnet`, `:137`). This is the hook for
   network encapsulation.

What is genuinely missing: (a) an SSH **client** role (none exists — no NIOSSH
`.client` anywhere); (b) a **push/event** channel (state is poll-only; `@Observable`
is in-process; `refreshSidebar()` is imperative, `BromureAC.swift:1046`); (c) a
**machine-verb** path on the SSH server (it force-commands every session into the
`__remote-menu` TUI, `RemoteSSHHandlers.swift:259`, and rejects all non-`.session`
channels, `RemoteAccessServer.swift:130`); (d) a **remote API for automations**
(GUI-only today, no routes); (e) **network encapsulation** for local→remote
guest subnets (zero support today).

---

## Topology — what runs where

```
┌──────────── HOST B (fat client, your Mac) ─────────────┐        ┌──────────── HOST A (remote, VMs live here) ────────────┐
│ bromure-ac GUI — UNCHANGED SwiftUI                     │        │ bromure-ac (headless or GUI) — SOURCE OF TRUTH         │
│   grid / sidebar / tabs / automations / terminals     │        │   ProfileStore · GridLayoutStore · AutomationStore     │
│                                                       │        │   runningSessions → UbuntuSandboxVM (real VZ VMs)      │
│ RemoteHostStore  (new)                                │        │   MITM engine · secrets · ssh-agent · tokens (STAY)   │
│   per-host ReadModel (mirror stores, @Observable) ◄───┼── events ┼── StateHub (new: emits deltas at mutation funnels)   │
│   CommandClient ──────────────────────────────────────┼── verbs ─┼─► control.sock API + delegate methods (exec + echo)  │
│                                                       │        │                                                        │
│ local browser VMs (Chromium renders here)             │        │ VMNetSwitch 192.168.64.0/24 ── workspace VMs (dev srv) │
│   VMNetSwitch forced to disjoint octet (127)          │        │ host→guest dial works today (cloudflared origins)     │
│ utun0  (192.168.64.0/24 → forwarder)   ◄──────────────┼─ forward ┼─► A dials guest, splices bytes                       │
│ BrowserMCPServer (drives LOCAL browser) ◄─────────────┼─ mcp ────┼── remote agent's vsock 5830                          │
└───────────────────────────────────────────────────────┘        └────────────────────────────────────────────────────────┘
                            └──────────────── ONE SSH connection per host, N+K multiplexed channels ─────────────┘
                            swift-nio-ssh · A's existing ed25519 host key + authorized_keys + per-IP throttle
```

**Authority model.** A is authoritative for all VM-side state. B holds a
read-model and **never mutates its own copy independently** — it sends a verb, A
executes it through the *same* delegate method the local GUI uses, and the
resulting change flows back through the event stream to **every** connected
client (A's own GUI included). That echo-to-all loop is what makes "any change
reflected everywhere" fall out without conflict resolution.

---

## Transport layer

Extend `RemoteAccessServer` / `RemoteSSHHandlers`. Humans keep getting
force-commanded into `__remote-menu` (`RemoteSSHHandlers.swift:259`) — unchanged.
Add a **machine-client path**: `exec`-channel requests with a whitelisted verb
set, parsed host-side, mapped to in-process handlers, **never** a shell.

New on B: a NIOSSH **`.client`** role (greenfield — biggest new component).

| Channel (exec verb) | Carries | Reuse |
|---|---|---|
| `bromure control` | Bridges to `control.sock`'s HTTP-JSON API (profiles, VMs, tabs, worktrees, exec, lifecycle) | `ControlClient` ports ~verbatim — it's HTTP over a byte stream (`CLICommands.swift:10`) |
| `bromure state` | One-shot snapshot: protocol version, hosts, profiles (scrubbed), running VMs, rosters, StageLayout, automations | `automationVMList()` (`BromureAC.swift:2452`) is ~90% of this already |
| `bromure events` | Long-lived JSON-lines push: roster / agent-status / layout / ip / ports / vitals / automation deltas | **NEW** — the core new work |
| `bromure attach <vm> <win>` | Framed PTY (`DATA/RESIZE/EXIT/EOF`) end-to-end | `InteractiveExec` unchanged — swap only the dial target |
| `bromure forward <ip> <port>` | L4 per-connection tunnel to a remote guest TCP service | **NEW** (small) |
| `bromure browser-mcp <vm>` | Relays remote agent's browser JSON-RPC to B's `BrowserMCPServer` | `handle(line:)` is transport-agnostic (`BrowserMCPServer.swift:34`) |

**Why exec-channel byte pipes and not SSH port-forwarding:** carrying
*everything* as our own framed protocol over multiplexed exec channels means we
never enable NIOSSH `direct-tcpip`/`forwarded-tcpip` (rejected today at
`RemoteAccessServer.swift:130`). Less new SSH attack surface; the subnet tunnel
is just another verb. One SSH connection per host, N terminals + K service
channels multiplexed over it (SSH channel windowing gives backpressure).

**Auth.** Reuse A's ed25519 host key + `authorized_keys` + per-IP throttle
(`RemoteSSHHandlers.swift:41`, host key `RemoteAccessServer.swift:190`). B pins
A's host key TOFU on first connect; A already surfaces the fingerprint and a
ready-made connect string via `remoteAccessStatus` (`BromureAC.swift:1996`) for
pairing UX. Keep the bridge bound to a VPN/Tailscale interface (existing
guidance). The verb whitelist is parsed before anything runs and maps to
in-process handlers — the bridge already grants attach capability to authorized
keys via the menu, so the *capability set* is unchanged.

---

## State synchronization

### The event stream (the one genuinely missing primitive)

Add a **`StateHub`** on A that fans deltas to every subscribed `bromure events`
channel. Populate it at the choke points that already exist:

- **Tee the single guest→host wiring point.** `wireSandboxCallbacks`
  (`BromureAC.swift:6883`) sets ~15 typed closures (`onTabList`, `onIPUpdate`,
  `onVMStats`, `onPortsList`, `onDockerList`, `onAgentStatus`, `onGuestReboot`,
  `onStopped`, …), each already mirroring into `RunningSession` + the pane's
  `TabsModel`. Tee each into `hub.emit(...)`.
- **Emit at mutation funnels.** Wherever `refreshSidebar()` / `store.save()` /
  `gridStore.*` are called (~2 dozen sites), emit the matching delta.
- Snapshot (`bromure state`) is the cold-start; events are the deltas.
  Sequence-numbered so B can detect a gap and re-snapshot.

### Commands (B → A)

Ride `bromure control` as the **same verbs A already runs locally**:

- Tab open/select/close and worktree create/merge/pr/remove/terminal are already
  a text-verb outbox protocol shared by the GUI and the CLI/SSH surface
  (`automationWorktreeCommand` `BromureAC.swift:6094`, `sendCommand` `:6135`,
  `requestSelectTab` `:6026`, `requestCreateWorktree` `:6046`).
- VM lifecycle (start/stop/suspend/reboot), `layout set`, automation upsert/run.
- **Whole-object last-writer-wins** on `StageLayout` / `Profile` /
  `ScheduledAutomation` — no partial-merge state. Optimistic local echo with
  roster reconciliation for latency-sensitive verbs, exactly as
  `SessionPane.switchTo`'s `pendingActiveIndex` guard already does.

### Secrets never travel

A sends the **scrubbed** profile form `ProfileStore` already produces (secrets
split to `secrets.enc` at save, `Profile.swift`). Secrets, MITM token maps,
ssh-agent keys, and the keychain master key stay on A. On write, blank secret
fields mean "keep stored" — the `PUT /profiles` path already implements this.

### Fleet namespacing

Every mirrored object keys by **`(hostID, profileID)`**, not `profileID`. The
sidebar gains a **"Remote hosts"** section; expanding a host lists its
VMs/tabs from that host's snapshot. Fleet-view grid cells spawn
`__attach-window --remote <host> <vm> <idx>`. Cheap, because state is already
per-object Codable.

### Automations (new remote API)

Automations have **zero** remote surface today (GUI-only, `@Observable`
consumed directly by SwiftUI; no routes — confirmed against the route list at
`AutomationServer.swift:317`). Add `/automations` CRUD + run-now + toggle + run
history, and include automation state in snapshot/events. The **engine stays on
A** — it must: it polls GitHub/Linear with the workspace's real tokens and runs
the mandatory local ONNX prompt-injection screen (`ScheduledAutomations.swift:1297`,
engine tick `:1044`, fire `:1325`), and boots/clones VMs. B only mirrors + edits.
Note `upsert` intentionally resets `nextFire`/`pollState` — remote edits must
preserve those (send explicitly, or have A merge).

---

## Terminal path

Reused almost entirely. A surface's child process is
`bromure-ac __attach-window <vm> <idx>` (`TerminalSessionController.swift:152`),
which today dials `control.sock` and becomes a byte pump for the framed PTY
protocol (`InteractiveExec.run`, `CLICommands.swift:1271`; frames
`[type u8][len u32be]`, DATA/RESIZE/EXIT/EOF, `:1260`). The app-side pump is
byte-transparent (`handleInteractiveExec`, `AutomationServer.swift:1089`),
bridging to a guest-initiated vsock-5800 pool (`ShellBridge.swift:21`).

**The only local dependency to abstract** is `ControlClient`'s unix-socket
transport. Add a `--remote <host>` mode to `VMAttachWindow`/`InteractiveExec`
whose "dial" returns an SSH exec-channel fd instead of a unix-socket fd; the rest
of `InteractiveExec.run` operates on a raw fd unchanged. On A, `bromure attach`
maps onto the same code path `handleInteractiveExec` uses (dequeue vsock, write
the JSON handshake, pump). RESIZE frames stand in for SSH window-change.

Everything latency-sensitive — rendering, selection, scrollback gestures, focus,
clipboard, IME — stays local to B (libghostty). Per keystroke: one framed DATA
frame up, echo back — one network RTT, same as any `ssh`. Reconnect-on-drop
reuses `TerminalSessionController`'s backoff loop; tmux on A holds all state, so
reconnect is a repaint, not a loss.

Care items: `attachCommand` assumes `Bundle.main.executablePath` and a local
running agent (`ensureAgentRunning` autostarts `run --headless` — must **not**
fire for remote VMs); image paste bypasses the PTY and calls
`delegate.guestFileOp`/`guestExec` on the local delegate — remote image paste
needs the `{"file":…}` op channel forwarded too (Phase 2/3 follow-on).

---

## Browser pane

The pane displays **real Chromium in a per-workspace sidecar Alpine VM**
rendered via `VZVirtualMachineView` (`WorkspaceBrowserController.swift:251`) —
not WKWebView, and it can't be remoted (the view binds to an in-process
`VZVirtualMachine`; DevTools even synthesizes NSEvents into it). So in fat-client
mode the **browser VM runs on B**, and two things must cross the link:

1. **Agent → browser control.** The coding agent runs in the **remote** workspace
   VM and dials vsock 5830 (`SessionDisk.swift:904`), hitting A's
   `BrowserMCPVsockBridge` → `BrowserMCPServer`. That server must drive **B's**
   `WorkspaceBrowserController`. Relay it: A forwards the line-delimited JSON-RPC
   over the `browser-mcp` channel to B's `BrowserMCPServer.handle(line:)`
   (transport-agnostic, `:34`) → B's controller → B's browser VM. The guest shim
   already reconnects forever on drops, tolerating SSH hiccups. Watch the ~90 s
   cold-boot wait (`readyBrowser`, `:224`) and base64-PNG screenshots inflating
   the stream.

2. **Page data plane.** Chromium on B navigating to the workspace's dev server at
   the **literal** `http://192.168.64.x:port` — the agent advertises that via
   `hostname -I` and the MCP instructions hard-code it (`BrowserMCPServer.swift:238`).
   This is what the subnet tunnel (below) delivers.

Requirement: **B must be an Apple Silicon Mac with the browser image installed**
(`BrowserImageInstaller` downloads from `dl.bromure.io` locally). Persistent
browser profiles are keyed by workspace UUID and live on B's disk keyed by the
remote workspace ID — a decision to note (ownership), not a blocker.

---

## Networking — the hard part

Today the whole path is in-process: local Chromium → `VMNetSwitch` peer-bridge →
workspace VM's dev server, all L2 frame copies (`isolatePeers:false`,
`WorkspaceBrowserController.swift:162`). We must replace the middle hop with a
tunnel to A's subnet, **system-wide** (any local process, not just the browser).

### `utun` + userspace forwarder

```
any local process (curl, scripts, host) ─┐
local browser VM ─ B VMNetSwitch(octet 127) ─ vmnet NAT ─┤
                                                         ▼
                              host route: 192.168.64.0/24 → utun0
                                                         ▼
              BromureNet forwarder (userspace) ── per-flow ──► bromure forward <ip> <port> (SSH channel)
                                                                              ▼
                                                    HOST A dials guest over its switch, splices bytes
```

Mechanics:

1. On connect, B reads A's real subnet from `bromure state` (A exposes
   `VMNetSwitch.shared.subnet`; the octet is **not** guaranteed 64 — it walks
   down avoiding host LANs, `VMNetSwitch.swift:426`).
2. **Force B's own switch to a disjoint octet** (e.g. 127). New knob:
   `configure()` today only exposes ascending/descending, not an explicit octet,
   and is a no-op once the interface has started (`:116`) — so B's browser-only
   switch must be pinned before its first `attachPort`. With B's switch on
   `192.168.127.0/24`, the remote `192.168.64.0/24` is off-subnet for **both**
   the browser VM and vmnet — so the browser VM's dev-server traffic egresses
   vmnet-NAT into B's host routing table and is caught by the same `utun` route
   as everything else. **No DHCP option-121 routes, no per-port switch policy** —
   the browser VM uses its default route unchanged.
3. B installs a host route `192.168.64.0/24 → utun0`. The forwarder terminates
   each TCP flow and opens `bromure forward <ip> <port>`; A dials the guest over
   its own switch and splices. A dialing a guest IP directly is already proven —
   that is exactly how cloudflared origins work today
   (`http://<guestIP>:<port>`, `VMDashboard.swift:317`). MTU 1280 is already
   clamped guest-side (`VMNetSwitch.swift:568`), tunnel-friendly.

### The one new privileged component

A `utun` with a route is privileged on macOS (creating/connecting the utun
control socket requires root). The app today ships only
`com.apple.developer.networking.vmnet`. System-wide reachability needs **one new
privileged component**:

- **Recommended:** a small **launchd privileged helper** (SMJobBless) that opens
  the `utun` fd and hands it back to the app. Lighter than a full
  `NEPacketTunnelProvider` system extension (which would need a separate target,
  the network-extension entitlement, and its own notarization).
- The helper is Phase-4-only, installed on first use with user consent.
- **Fallback:** the browser-VM-only switch-shim path (route `192.168.64.0/24`
  off the browser VM via DHCP option-121 to a gateway B's switch owns, forward at
  L4 from the switch) needs **no** new privilege — keep it as the degraded mode
  so the browser pane works before/without the helper. System-wide is the
  primary per the locked decision.

### Fleet: alias-on-collision

Two remotes are near-guaranteed both on `192.168.64.0/24`, and you cannot route
two identical `/24`s to two tunnels literally (nor renumber a remote's live
switch — `configure()` is frozen after start and its VMs are already leased).

- **Route literally when the octet is free locally.** First remote on `.64`
  routes `192.168.64.0/24 → utun` verbatim; a second remote on `.63` also routes
  literally. Most of the time, literal.
- **Alias-NAT only on collision.** A second remote *also* on `.64` gets a local
  alias `/24` (e.g. `100.64.<hostIdx>.0/24`); the `browser-mcp` relay rewrites
  its advertised `hostname -I` address `192.168.64.x → 100.64.<idx>.x` (a pure
  1:1 octet remap, not brittle URL rewriting; the far side translates back).
- **Known caveat:** a dev page emitting *absolute* literal `http://192.168.64.x`
  links inside an **aliased** remote can misroute — rare (agents use the address
  we hand them, dev servers usually emit relative/localhost URLs), but real.
  Literal (non-aliased) remotes have no such caveat.

### Not a usable interception point

The MITM proxy only sees env-respecting HTTP(S) from *agents* via `proxy.env`;
the browser VM uses `--no-proxy-server` and on-subnet destinations never reach it
(`VMPool.swift:654`). So the tunnel must be L3/L4, not "route through the MITM."

---

## Security

- **Transport auth** reuses A's ed25519 host key + `authorized_keys` + per-IP
  throttle; B pins A's host key TOFU with the fingerprint A already surfaces.
- **Verb whitelist** parsed host-side before execution; verbs map to in-process
  handlers, never a shell. Non-`.session` channels stay rejected.
- **Secrets stay on A** — scrubbed profiles only cross the link; blank-on-write
  keeps stored secrets.
- **MITM consent prompts** render into the PTY stream as type-0 frames
  (`PumpConsentGate`, `AutomationServer.swift:952`; `RemoteConsent.swift`) — they
  ride the tunneled byte stream to B's terminal correctly, and a compromised
  guest can neither see nor forge them. The "most recent attach wins" keying
  needs a multi-client rule (see risks).
- **utun helper** is a privileged component: minimize its surface (open utun,
  hand back fd, nothing else), gate on user consent, and never let it take a
  destination from the guest without host-side policy (restrict routed targets to
  the connected remotes' advertised subnets).

---

## Phases

Each phase is independently shippable and demoable.

### Phase 1 — Read-only fleet mirror

Client role + `state` + `events`; render live, no editing, no terminals.

- NIOSSH `.client` connection manager on B; "Remote hosts" sidebar section (add
  host = address + port + client key, stored under the existing `remote/` dir).
- Server-side: machine-verb exec parser; `bromure state` (extend
  `automationVMList` `BromureAC.swift:2452` to include StageLayout + automations);
  `StateHub` + `bromure events` (tee `wireSandboxCallbacks` `BromureAC.swift:6883`
  and mutation funnels).
- B-side per-host `ReadModel` mirror stores feeding the existing sidebar/grid
  views (read-only). Namespacing by `(hostID, profileID)`.
- Move vitals into `RunningSession` so detached/headless sessions report real
  cpu/mem/load (today only the pane gets them, `BromureAC.swift:7017`).

**Acceptance:** add a host on B → sidebar shows its workspaces, tabs, worktrees,
and automations, matching A live; start/close a workspace or worktree on A → B
reflects it within the event latency; no editing yet.

### Phase 2 — Interactive terminals

- `bromure attach` verb → A's `handleInteractiveExec` path.
- `--remote <host>` mode for `VMAttachWindow`/`InteractiveExec`: dial an SSH exec
  channel instead of `control.sock` (`CLICommands.swift:72`, `:1271`); suppress
  `ensureAgentRunning` for remote VMs.
- Remote grid cells spawn `__attach-window --remote`; reuse
  `TerminalSessionController` reconnect/backoff and the "reconnecting" veil.

**Acceptance:** 8-cell grid on A → from B, the identical 8-cell layout with live
status borders; typing in any cell round-trips at ssh latency; pull A's network
cable → cells veil and recover on reconnect.

### Phase 3 — Bidirectional edits

- Commands over `bromure control`: tab/worktree/lifecycle verbs (reuse the outbox
  verbs, `BromureAC.swift:6094`), `layout set`, profile edits (LWW, secrets
  blank-kept).
- `/automations` remote API (CRUD + run-now + toggle + history); preserve
  `nextFire`/`pollState` on edit.
- Make `launch()`'s `NSAlert` decision points (drift reset, home migration,
  compromise wipe, `BromureAC.swift:5362`) RPC-able instead of modal, so
  remote-initiated launches surface the choice on B.
- Decouple pane creation from the local sandbox path so B builds a pane fed by
  remote `TabsModel`-shaped data (the main refactor).
- Abstract automation-completion detection out of the UI pane objects
  (`setTabAgentStatus` → `agentFinished`, `BromureAC.swift:1122`) so headless
  A delivers it reliably.

**Acceptance:** rearrange the grid on B → A's stage matches and other clients
converge; edit a workspace's settings or an automation on B → persists on A and
echoes to all clients; close a worktree on A → the cell disappears on B via the
event stream.

### Phase 4 — Networking (browser pane + system-wide tunnel)

- `bromure forward <ip> <port>` verb (A dials guest, splices).
- `BromureNet` userspace forwarder on B; explicit-octet knob on `VMNetSwitch`;
  pin B's switch to a disjoint octet.
- Privileged `utun` helper (SMJobBless): open utun, hand back fd; B installs host
  routes for each connected remote's subnet.
- Fleet alias-NAT translator (route literally when free, alias on collision) +
  `browser-mcp` relay address remap.
- `browser-mcp` channel: relay remote agent JSON-RPC to B's `BrowserMCPServer`.

**Acceptance:** open the browser pane for a remote workspace on B → Chromium
renders locally, the remote agent drives it via MCP, and navigating to the
workspace's `192.168.64.x:port` dev server loads; `curl 192.168.64.x:port` from
B's terminal reaches the same remote guest; connect a second remote also on `.64`
→ its dev servers reach via the alias with no collision.

---

## Risks & mitigations

- **`utun` requires privilege.** New launchd helper (or NE system extension);
  gate on consent; keep the switch-shim browser-only path as a no-privilege
  fallback. *(Verify empirically first — see below.)*
- **vmnet NAT → host route → utun path unproven.** Whether vmnet-NAT'd off-subnet
  traffic from B's browser VM is actually caught by a host `utun` route needs an
  empirical check before committing Phase 4's shape. If it isn't, fall back to the
  switch-port L4 shim (route the browser VM explicitly via option-121).
- **Subnet collision across fleet.** Alias-NAT on collision; document the
  absolute-literal-link caveat; literal routing whenever the octet is free.
- **Multi-client consent keying.** `PumpConsentGate` is "most recent attach wins"
  — define a deterministic rule for a local GUI surface + remote fat-client
  surface on the same profile (e.g. the acting client owns consent, else deny on
  timeout — the existing fail-safe).
- **Layout divergence** (two clients editing the stage): last-writer-wins on A,
  event stream echoes the result; writes are whole-`StageLayout` replacements —
  no partial-merge state.
- **Version skew.** `bromure state` leads with a protocol version; refuse major
  mismatches with a clear error.
- **fd budget.** One long-lived vsock/SSH channel per terminal × workspaces ×
  hosts — respect the known fd-leak sensitivity under `ulimit -n 256`
  (retired VMs live forever); soak-test channel teardown.
- **SSH client is greenfield.** No NIOSSH `.client` exists — prototype it in
  isolation (connect, auth, one exec channel, host-key pin) before Phase 1 wiring.

---

## Verify empirically before building (spikes)

1. **Networking spike:** does a host `utun` route catch vmnet-NAT'd off-subnet
   traffic from a guest? Stand up a utun, route `192.168.64.0/24` to a trivial
   userspace echo, and confirm a guest on B's switch (disjoint octet) reaches it.
   Determines Phase 4's shape.
2. **SSH spike:** NIOSSH `.client` → A's `RemoteAccessServer` with an
   authorized key, open an exec channel, run one whitelisted verb, pin the host
   key. De-risks the biggest greenfield piece.

---

## Explicitly out of scope (v1)

- Streaming a **remote** browser framebuffer (browser stays a local VM).
- A separate headless **daemon** — A is the running bromure-ac app (GUI closed is
  fine; a rack Mac mini works).
- True **before-login** boot on A (would need a root LaunchDaemon; deferred).
- tmux control-mode integration; replacing the `__remote-menu` TUI (it benefits
  from the transport unchanged).
- Repurposing the bromure.io **enrollment/mTLS** stack (`Enrollment.swift:256`)
  as client↔host auth — it's fleet telemetry today; the SSH host key +
  `authorized_keys` is the v1 trust root.
