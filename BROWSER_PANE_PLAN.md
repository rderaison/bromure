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
- **Phase 3 — MCP.** Extract CDP tool core to a shared lib; host loopback MCP
  HTTP server; agentd vsock bridge; auto-inject MCP config; tool set v1
  (open/navigate/back/reload, tab list/activate/close, screenshot, evaluate JS,
  click/type, console + network readout, `browser_open` lifecycle).
- **Phase 4 — polish.** VMPool pre-warm for sub-second open, SPICE clipboard,
  download handoff into the workspace home (FileTransferBridge → existing
  upload path), MITM network inspection, per-automation browser instances.

## Open questions / risks

- **Two `VZVirtualMachine`s in one process** (Ubuntu workspace + Alpine
  browser). Expected fine (separate configs/sockets) but unverified at runtime —
  first thing to prove in phase 2.
- **Base image availability.** AC ships the Ubuntu base; the browser needs the
  Alpine+Chromium base built/downloaded. Decide: bundle both, or fetch the
  browser image on first use (like `img-catalog` postinstall).
- **Name collisions.** `MCPServer`, `AutomationServer` exist in both `Browser`
  and `AgentCoding`. The extracted browser MCP core must be namespaced to avoid
  clashing when AC links it.
- **Clipboard is SPICE**, not vsock — needs the extra console port +
  `spice-vdagent` if we want browser↔host clipboard.
