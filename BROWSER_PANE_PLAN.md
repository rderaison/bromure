# Agentic Web Browser — design & plan

Branch: `agentic-web-browser` (cut from `agentic-coding-v4.2.0`).

## Goal

Embed a fully instrumentable web browser in Bromure Agentic Coding, exposed to
the in-VM coding agents (Claude / Codex / Grok) as an MCP server. The browser
appears on demand as a **right-hand split pane in the workspace window** — the
agent/terminal on the left, a live Chromium framebuffer with its own chrome
(tab strip + URL bar) on the right — so the user watches the agent browse, and
the agent can drive it and take screenshots.

Reference layout: `browser.png` (agent conversation left, browser pane right,
one window).

### Locked decisions (v1)

- **Always ephemeral.** No persistent browser profile; the browser VM's disk is
  an APFS CoW clone destroyed when the pane/workspace closes. (Persistent
  LUKS profiles via `ProfileDisk` are a later opt-in.)
- **One browser per workspace.** A single browser VM is bound to a workspace
  (`Profile.id`), lazily created, shared across that workspace's agent tabs.
- **Sidecar VM, not Chromium-in-the-workspace-VM.** The browser runs in a
  separate Alpine+Chromium guest (Bromure Web's base image), not inside the
  Ubuntu workspace VM. Rationale below.

## Why a sidecar browser VM (not Chromium in the workspace VM)

- VZ device sets are frozen at boot. The Ubuntu workspace VM has **no graphics
  device** (removed in `ad9cb793`). Adding a scanout + USB input to it would
  have to be unconditional, which **invalidates every existing suspended-
  workspace snapshot** (restore requires a matching config) and adds GUI memory
  cost to every workspace whether or not the browser is used.
- It would mean porting Bromure Web's entire Alpine launch stack (xinitrc,
  config-agent, resize-watcher, scale math) onto Ubuntu and maintaining it
  twice.
- A browser inside the workspace VM shares the agent's filesystem — strictly
  worse isolation than a separate VM.

The sidecar reuses Bromure Web nearly untouched: boot/claim an Alpine Chromium
VM (`VMPool` pre-warm + `EphemeralDisk` clonefile) and mount its
`VZVirtualMachineView` into the AC stage.

## What we reuse (already in the repo)

`bromure-ac` already links `SandboxEngine`; adding `BrowserBridges` gives us the
CDP/tab/file bridges. Reuse map:

| Need | Source (existing) | Target |
|---|---|---|
| Browser VM config + boot | `SandboxEngine/LinuxImageManager.swift` `buildLinuxVMConfig` (virtio-GPU scanout, USB input, vsock) | SandboxEngine (linked) |
| VM pre-warm + claim | `SandboxEngine/VMPool.swift` (`warmUp`, `claim`) | SandboxEngine (linked) |
| Ephemeral CoW disk | `SandboxEngine/EphemeralDisk.swift` (`clonefile(2)`) | SandboxEngine (linked) |
| Display params / scale | `SandboxEngine/VMConfig.swift` | SandboxEngine (linked) |
| Alpine+Chromium base image, xinitrc, config-agent.py, cdp-agent.py, resize-watcher.sh | `SandboxEngine/Resources/vm-setup/` | SandboxEngine (linked) |
| CDP tunnel pool | `BrowserBridges/CDPBridge.swift` (vsock 5200) | add dep |
| Native tab stream | `BrowserBridges/TabBridge.swift` (vsock 5810) | add dep |
| File transfer (downloads) | `BrowserBridges/FileTransferBridge.swift` (vsock 5100) | add dep |
| CDP tools incl. `Page.captureScreenshot` | `Browser/MCPServer.swift` (`bromure_screenshot`, evaluate, click/type) | **extract** to shared lib |
| Framebuffer view niceties | `Browser/SafariSandbox.swift` `PrecisionScrollVMView`, `NativeChromeCropper` | **extract** (phase 2/4) |

`Browser/MCPServer.swift` and the display subclasses live in the `bromure`
**executable** target, so AC can't link them directly — they must be lifted
into a library (`BrowserBridges` or a new `BrowserCore`). Phase 1 uses the
plain `VZVirtualMachineView` base class and needs no extraction.

## Architecture

```
 ┌─ Workspace window (UnifiedSessionWindow) ───────────────────────────┐
 │ sidebar │  agent/terminal (paneSlot)      │  BrowserPane (split)    │
 │         │  SessionPane / Ghostty surfaces  │  ┌───────────────────┐ │
 │         │                                  │  │ tab strip + URL bar│ │
 │         │                                  │  ├───────────────────┤ │
 │         │                                  │  │ VZVirtualMachineView│ ← Alpine Chromium VM
 │         │                                  │  └───────────────────┘ │
 └─────────┴──────────────────────────────────┴─────────────────────────┘
      host                                          sidecar browser VM
                                                    (SandboxEngine VMPool)

 MCP path (workspace agent → browser):
   claude/codex/grok ──http──▶ 127.0.0.1:<guestPort>  (workspace Ubuntu guest)
        │ agentd bridge service  (mirror bridge_llm_engine_service, vsock)
        ▼
   host loopback MCP HTTP server  ──▶ CDPBridge tunnel ──▶ Chromium :9222 (browser VM)
```

The workspace-agent → host-MCP hop copies the **inference-engine bridge**
pattern (the proven guest→host loopback shape): guest binds a fixed
`127.0.0.1:<port>`, `bromure-agentd.py` splices it over a dedicated vsock port,
a host `VZVirtioSocketListener` accepts and pumps to a host-loopback listener.
MCP config reaches the agents through the existing
`SessionDisk.claudeCodeMCPConfig` → meta-share → `~/.claude.json` merge (http
transport, loopback URL, no auth needed).

## Phasing

- **Phase 1 — UI shell (this branch, first).** `BrowserPane`: browser chrome
  (tab strip, URL bar, window buttons) matching `browser.png`, plus a
  framebuffer container that hosts a `VZVirtualMachineView` when a VM is
  attached and a globe placeholder otherwise. Wire into the stage as a
  right-hand split (copy the file-explorer wiring: trailing host + width
  constraint + resize handle, `paneSlot.trailing → browserPane.leading`).
  Toolbar/menu toggle, width persistence. **Builds and shows the shell with a
  placeholder; no VM yet.**
- **Phase 2 — ephemeral VM lifecycle.** `WorkspaceBrowserController`: lazily
  boot/claim an Alpine Chromium VM (VMPool + EphemeralDisk), one per workspace,
  mount its framebuffer, tear down on pane-close / workspace-close / suspend.
  Resize/scale plumbing (resize-watcher already handles the guest side).
- **Phase 3 — native chrome, instrumentation, polish.** Broken into:
  - **3a native chrome:** switch `browserConfig` to `nativeChrome` + inset;
    reimplement the `NativeChromeCropper` in AC (host-side AppKit) so the
    host-drawn chrome (tab strip + URL bar from `browser.png`) replaces
    Chromium's, which is cropped into the inset. Wire the host chrome to drive
    the browser (nav/back/reload/tabs) via CDP.
  - **3b copy/paste:** enable clipboard sharing for the browser VM (SPICE, as
    Web does) and make ⌘C/⌘V reach Chromium in native-chrome mode.
  - **3c CDP foundation:** add `BrowserBridges` dep; extract `CDPConnection` +
    screenshot/eval/nav/input from `Browser/MCPServer.swift` into a shared lib
    so AC drives Chromium's `:9222` over `CDPBridge` (vsock 5200).
  - **3d MCP:** host loopback MCP HTTP server (navigate/screenshot/eval/tabs/
    click/type/console/network); agentd vsock bridge so workspace agents reach
    it at `127.0.0.1:<port>`; auto-inject MCP config via `claudeCodeMCPConfig`.
  - **3e devtools:** a devtools toggle button in the host chrome (Claude users
    want DevTools) — open via CDP/keybinding.
- **Phase 4 — polish.** VMPool pre-warm for sub-second open, SPICE clipboard,
  download handoff into the workspace home (FileTransferBridge → existing
  upload path), MITM network inspection, per-automation browser instances.

## Browser image provisioning (shared + prebuilt download)

The browser VM boots Bromure Web's Alpine+Chromium disk. AC **shares** it with
Bromure Web and **downloads a prebuilt copy** when absent (mirroring how AC
already fetches its Ubuntu base) — no ~10-minute local Alpine build on end-user
machines.

### Storage layout (today)

| App | Storage dir | Base image |
|---|---|---|
| Bromure Web (`SandboxEngine.LinuxImageManager`) | `~/Library/Application Support/Bromure/` | `linux-base.img` (Alpine+Chromium) |
| Bromure AC (`UbuntuImageManager`) | `~/Library/Application Support/BromureAC/` | `base.img` (Ubuntu) |

`VMPool` clones `LinuxImageManager.linuxDiskURL` = `<storageDir>/linux-base.img`.

### Image resolution order (WorkspaceBrowserController)

1. **Shared, in place** — if `~/Library/Application Support/Bromure/linux-base.img`
   exists (Bromure Web installed), reuse it. On the test machine this is the
   path: instant, zero extra disk.
2. **AC-owned** — else use `~/Library/Application Support/BromureAC/browser/linux-base.img`.
3. **Download** — if neither exists, fetch the prebuilt browser image into the
   AC-owned location (never write into Bromure Web's dir).

**Sharing mechanism:** the browser `VMPool` runs with
`storageDir = BromureAC/browser` (all pool scratch + ephemeral CoW clones stay
AC-owned). When the shared Web image exists, symlink
`BromureAC/browser/linux-base.img → Bromure/linux-base.img`; `clonefile(2)`
(flag 0) follows the symlink to clone the shared file, and a Web rebuild
(atomic rename) is transparently picked up. When downloading, the real file
lands at that path instead. Either way AC never mutates the shared image — it's
only ever a read/clone source.

### Prebuilt distribution — LANDED (see PREBUILT_IMAGE.md)

The Web side now publishes a prebuilt browser image weekly
(`Jenkinsfile.browser-image` → `scripts/publish-browser-image.sh` →
`https://dl.bromure.io/browser-images/`). It diverged from the sketch above in
three ways worth knowing:

- **Three artifacts, not one** — the browser image direct-kernel-boots, so
  `vmlinuz.gz` + `initrd.gz` are published alongside `base.img.gz` and declared
  in the catalog's `image.boot` array.
- **The manifest is `browser-images/img-catalog.json`** (same `ImageCatalog`
  model as AC's, signed with the same Sparkle key but a distinct payload magic,
  `bromure-browser-img-catalog-v1`, so catalogs can't be replayed across
  channels).
- **It DOES have postinstall steps** — Cloudflare WARP turned out to be
  non-free and moved out of the baked image into a catalog step
  (`Sources/SandboxEngine/Resources/browser-img-catalog.json`); Apple fonts +
  keyboard/locale personalisation also happen client-side
  (`vm-setup/postinstall.sh`).

### AC-side refactor — LANDED

The generic helpers were hoisted into **SandboxEngine**
(`ImageCatalog.swift`, `ImageFetch.swift`,
`LinuxImageManager+Remote.swift`), parameterized by `ImageDistribution`.
AC's on-demand download (phase 2b) is `BrowserImageInstaller` (shared
`@Observable`, one in-flight install app-wide): the pane's
`WorkspaceBrowserController.start()` triggers it when `resolveStorageDir()`
comes up empty and renders its progress in the placeholder; Settings →
Browser has a (Re)download button driving the same installer. Artifacts
land in `BromureAC/browser/` (never Bromure Web's dir; no symlink needed —
`resolveStorageDir` probes both dirs directly).

## Open questions / risks

- **Two `VZVirtualMachine`s in one process** (Ubuntu workspace + Alpine
  browser). Expected fine (separate configs/sockets) but unverified at runtime —
  first thing to prove in phase 2.
- **Base image availability.** Resolved end-to-end: share Bromure Web's
  `linux-base.img` when present, else `BrowserImageInstaller` downloads a
  prebuilt copy into `BromureAC/browser/` from
  `dl.bromure.io/browser-images/` (published by Jenkinsfile.browser-image).
- **Name collisions.** `MCPServer`, `AutomationServer` exist in both `Browser`
  and `AgentCoding`. The extracted browser MCP core must be namespaced to avoid
  clashing when AC links it.
- **Clipboard is SPICE**, not vsock — needs the extra console port +
  `spice-vdagent` if we want browser↔host clipboard.
