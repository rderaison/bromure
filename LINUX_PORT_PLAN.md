# Bromure Agentic Coding on Linux — port plan

Goal: a headless `bromure-ac` server on Linux. It runs workspaces in KVM VMs with the same guest image and agents, the MITM proxy, guardrails, P2P/TURN remote access, and the control plane. The macOS app manages it as a fat client, the way it manages a remote Mac today. There is no Linux UI for now.

Decisions (2026-10-30):
- **Swift on Linux with a shared core.** The same Swift source compiles into both builds wherever it can. Only platform code is rewritten, and every rewritten function is tracked against its macOS original (see the ledger below).
- **QEMU/KVM** as the hypervisor.
- **One long-lived branch, `linux-port`**, which the macOS and Linux sessions both commit to. The shared-core carve-out lands on `main` in small, macOS-green steps, so the branch never carries a giant move that conflicts with daily work.
- **Swift 6.4** on both sides. The reference Linux box is `lnx-ntv`: Ubuntu 26.04, x86_64, bare-metal KVM.

## The function ledger (`tools/portmap`)

Every function-like declaration in `Sources/AgentCoding`, `Sources/SandboxEngine` and `Sources/BrowserBridges` gets an id and a hash:
- **Declarations covered:** funcs, inits, deinits, subscripts, and computed or observed properties.
- **id:** `Type.name(label: Type, …)`. The file isn't part of the id, so moving code into the shared core keeps it.
- **hash:** SHA-256 of the body's tokens. Whitespace and comments don't change it; code does.
- **Long functions** (over 120 lines) are split further. Each `x.onFoo = { … }` hook closure and each case of a top-level `switch` becomes its own entry, `<parent id> / <label>`. A change to one hook in `wireAutomationCallbacks` flags that hook, not all 1,900 lines.

Each macOS function is in one of five states:

| status | meaning |
|---|---|
| `shared` | Compiled into both builds from the same source. It can't drift. |
| `ported` | A Linux declaration carries `// @port <id> h=<hash> @<commit>` and the hash is current. |
| `stale` | Ported, but the macOS body has changed since. `portmap diff <id>` shows what changed. |
| `skipped` | Not needed on Linux: `// @port-skip <reason>` on the declaration, or a rule in `port/config.json` (UI views, for example). |
| `todo` | Nothing on Linux yet. |

Linux-only code (`Sources/ACLinux`, or `#if os(Linux)` branches in shared files) must carry either `// @port …` or `// @port-skip linux-only: <why>`. `portmap check` fails on stale ports, on `@port` lines that point at a macOS function that no longer exists (orphans), and on unannotated Linux functions.

Workflow:
- **macOS change:** CI runs `portmap check`. Anything it reports stale is ported on Linux and re-stamped with `portmap stamp <id>`, which prints the line to paste.
- **New Linux implementation:** `portmap stamp <id>` the macOS function it implements. It goes on the line above the Linux declaration.
- **Progress:** `portmap status [--by-file]` and `portmap list todo --file Mitm/`.

```bash
cd tools/portmap && swift build -c release
tools/portmap/.build/release/portmap status --root .
```

On 2026-10-30 the baseline is 12,262 entries (195K body lines). The `skipInheriting` rule skips everything in types that inherit from SwiftUI/AppKit/UIKit view bases, along with their subclasses and extensions. The `skip` path rules cover the fat client's client side, MLX, GPU and display bridges, AppleScript, and UI-only files. After both, **4,107 entries are skipped and 8,155 (124K lines) are the port**.

A wrong skip is harmless: as soon as a file joins the Linux build, its functions count as `shared` whatever the rule says.

## The shape of the code

| target | builds | what |
|---|---|---|
| `ACCore` (new library) | macOS + Linux | Everything without an Apple-only dependency: profiles, the MITM engine's logic, guardrails, token swaps, automations, the kanban, delegation, repo watch, sessions engine, the control-plane routes, P2P/TURN, enrollment, the image bake logic. |
| `AgentCoding` (today's app) | macOS | The UI plus the macOS implementations of the core's platform protocols. |
| `ACLinux` (new library) | Linux | The Linux implementations: QEMU, tap/nftables, AF_VSOCK, virtiofsd, NIOSSL, the secret store, systemd. |
| `bromure-ac` on Linux (new executable) | Linux | The headless daemon and the CLI. It speaks the macOS server's protocol: control.sock, the automation API and `/state`, the SSH front door, P2P. |

The core reaches the platform only through protocols, which are introduced one at a time as files move: `VMBackend`, `VsockDevice`, `SharedFolder`, `NetworkUplink`, `TLSStreamFactory`, `SecretStore`, `ServiceManager`, `Clock`/`FileSystem` where Foundation differs.

Today's measure:
- **Already portable:** 238 files and about 85K lines import nothing Apple-only. They're the first to move.
- **Biggest mixed file:** `BromureAC.swift` (`ACAppDelegate`), where wiring, launch and the server hooks sit next to AppKit. It's split into a headless `ACEngine` (core) and the AppKit delegate.

## Subsystem map

| subsystem | macOS today | Linux | phase |
|---|---|---|---|
| VM lifecycle | Virtualization.framework (`UbuntuSandboxVM`, `VMPool`, `SandboxVM`) | QEMU q35 + KVM driven over QMP, `-cpu host`, memfd RAM. Direct kernel boot from the bake's kernel/initrd (the spike's 5 s BIOS + GRUB boot should drop to 1–2 s). | 2 |
| Suspend / resume | `saveMachineStateTo` / restore, with the `vm.state.json` drift fingerprint | `stop` + `migrate` to `file:` with **mapped-ram** and a raised `max-bandwidth` (0.57 s save, 0.23 s restore in the spike). A saved state is valid only with the exact overlay it was saved with, which matches the drift fingerprint's intent. | 2 |
| Disks | APFS clonefile of `base.img`; ext4 `home.img`; Rewind checkpoints | qcow2 overlay on a read-only base (ext4 hosts have no reflinks). The home is a raw ext4 image, as today, so the Swift `Ext4` code is shared. Checkpoints become qcow2 snapshots or overlay chains. | 2 |
| vsock | `VZVirtioSocketDevice` (5800 shell, token agents, MCP 5830–5835, inference) | `vhost-vsock-pci` with a guest CID per VM, and AF_VSOCK on the host behind the same `VsockDevice` protocol. Every bridge above it is shared. | 2 |
| Shared folders | `VZVirtioFileSystemDevice` | virtiofsd (`--sandbox namespace`) behind `vhost-user-fs-pci`. It survives migration with `--migration-mode find-paths`. | 2 |
| L2 switch | `VMNetSwitch`: MAC-learning switch, own DHCP, DNS snoop, the MITM interceptor hook. VM ports are socketpairs; the uplink is one vmnet NAT interface. | **The same switch code.** VM ports become QEMU `-netdev stream` Unix sockets (4-byte big-endian length per frame, verified). The uplink becomes one tap (`bromure0`) with nftables masquerade, behind a `NetworkUplink` protocol. | 3 |
| Egress firewall, DNS, LAN | `EgressPolicy`, `DNSSnoop`, `NetworkFilter`, `LANTap` (vmnet bridged) | Shared policy code. `LANTap` becomes a macvtap or bridge on the host NIC. | 3 / 8 |
| VPN bridges | IKEv2 / WireGuard / OpenVPN bridges | They run in the guest as today; the host side is shared. | 8 |
| MITM proxy | `HTTPProxy`, `TLSServerStream`, `CertCache`, `BromureCA` on SecureTransport and Security.framework keys | The same engine on a `TLSStreamFactory` backed by swift-nio-ssl (BoringSSL). The CA and leaf certificates come from swift-certificates and swift-crypto, already dependencies. | 4 |
| Credential swaps, guardrails, minting, squelch, supply chain, PII and prompt injection | `Mitm/*`, mostly pure logic | Shared. The ONNX detectors need onnxruntime's Linux build (later); until then the policy's "model unavailable" path applies. | 4 / 8 |
| Secrets | Keychain (`SecretsVault`, `PassphraseKeychain`, `VPNKeychain`, the install token, the fat-client key) | A `SecretStore`: libsecret when there's a session bus, otherwise an encrypted file under `~/.local/share/bromure-ac` (0600) with a machine key. | 4 |
| Control plane | `control.sock`, `ACAutomationServer` routes and `/state`, the CLI, AppleScript (`.sdef`) | Shared server and CLI. AppleScript is skipped. | 5 |
| Remote access | SSH front door (`RemoteAccessServer`, NIOSSH), fat-client protocol | Shared. **Milestone: the Mac's fat client connects to the Linux server, lists workspaces, boots one and opens a terminal.** | 5 |
| P2P / TURN / enrollment / cloud | `P2P/*` (a few files on Network.framework), `Enrollment`, `CloudMTLSIdentity` (Security identities) | NWConnection is replaced with NIO/POSIX sockets. The mTLS identity moves to PEM/PKCS#12 with NIOSSL. | 6 |
| Agent features | sessions engine, automations, kanban, delegation, repo watch, rooms, switchboard, launch restore | Shared (server-side logic); only the UI half is skipped. | 7 |
| Terminals | Ghostty surfaces; `__attach-window` PTY relay over vsock 5800 | No local terminal. `__attach-window` (the fat client's path) is shared. | 5 |
| Guest image | `UbuntuImageManager` bakes noble **arm64** with `setup.sh` and the vm-setup agents | The same scripts bake an **amd64** image (and arm64 for arm64 Linux hosts), versioned like `imageVersion` and published per architecture. Guest agents are unchanged. | 2 |
| Kernel sentry (OpenShell) | `sentry-dist/src/bromure_sentry.c`, arm64 only: `#error` unless `CONFIG_ARM64`, it reads `regs->regs[0..2]`, and its build and `Jenkinsfile.sentry` use aarch64 gcc | An x86_64 build: `regs->di/si/dx`, an amd64 cross-compiler, and a module per architecture. | 8 |
| Kubernetes, registries, LAN load balancer | `KubeClusterEngine`, `KubeRegistryEngine`, `KubeLANAnnouncer` | Shared engines on the Linux VM backend. | 8 |
| Local models | MLX in-process engine | Skipped: Apple GPU only. The external engine (vLLM/Ollama) path is shared. | — |
| Lifecycle, updates | LaunchAgents, `SMAppService`, Sparkle | systemd user units; updates from the package repo, like the Linux Sidecar. | 5 |
| UI | AppKit/SwiftUI | Skipped. | — |

## Phases

0. **Done (2026-10-30).**
   - Linux toolchain: Swift 6.4.0. QEMU 10.2.1 and virtiofsd 1.13.2 are installed.
   - Dependency smoke test passes: NIO, NIOSSH, NIOSSL, swift-crypto, swift-certificates.
   - QEMU spike passes (`linux/spike/`): qcow2 overlay, vsock both ways, virtiofs, stream frames, and mapped-ram suspend/resume.
   - The ledger tool is written.
1. **Sort and carve.**
   - Skip rules for the UI. Create `ACCore` and move the portable files.
   - A Linux CI job runs `swift build --target ACCore` plus `portmap check` on `lnx-ntv`.
   - On `main`, in steps that keep the macOS app green.
2. **VMs.**
   - Extract the `VMBackend` and `VsockDevice` protocols from `UbuntuSandboxVM`, and write the QEMU backend.
   - Bake the amd64 image.
   - Linux `bromure-ac vm run / ls / exec / kill` at parity, with suspend/resume.
3. **Network:** the switch on stream sockets, DHCP, DNS, and the egress firewall.
   - Uplink: rootless `passt` by default (one per host, on a socketpair; no host loopback; MTU 65520 written to `meta/mtu`, except VPN profiles, which keep the macOS clamp). Tap + nftables (`setup-network.sh`) is the opt-in alternative.
   - The shared switch must deliver uplink→VM frames by destination IP (passt tracks a single guest MAC).
4. **Proxy:** MITM on NIOSSL, the secret store, token swaps, guardrails.
5. **Control plane and fat client:** control.sock, the API, `/state`, the SSH front door, systemd. The milestone is the Mac managing the Linux host.
6. **P2P, TURN, enrollment.**
7. **The agent features**, server side.
8. **The rest:** Kubernetes, registries, VPNs, detectors, OpenShell sentry, the LAN tap, the browser image.

## Working agreement

- **The macOS session** does the refactors that touch macOS code: protocol extraction, moves into `ACCore`, keeping the app and its tests green. It keeps the ledger's config.
- **The Linux session (`@bromure-linux-native` on `lnx-ntv`)** writes `ACLinux` and the Linux daemon, runs the Linux CI, and stamps every Linux declaration.
- **Code review:** both review each other's changes, and `@stickler` reviews milestones.
- **Gates:** nothing merges with `portmap check` failing. Every phase ends with a working CLI demo on `lnx-ntv`.
