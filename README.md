<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Bromure icon">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="Resources/BromureACIcon.png" width="128" height="128" alt="Bromure Agentic Coding icon">
</p>

<h1 align="center">Bromure</h1>

<p align="center">
  Secure, ephemeral computing in disposable Linux VMs on macOS.
</p>

<h2 align="center">
  → Full details, screenshots, and downloads at <a href="https://bromure.io">bromure.io</a>
</h2>

---

This repo ships two sibling apps, both built on Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization):

- **Bromure** — every browser session runs in a throwaway Linux VM. Close the window, the VM is destroyed.
- **Bromure Agentic Coding** — a sandboxed environment for AI coding agents (Claude Code, Codex), with a host-side MITM proxy that swaps fake credentials for real ones on the wire so secrets never enter the VM.

## How Bromure Agentic Coding compares

The same agent threat model — isolation, keeping secrets out of the agent, scoping how those secrets get used, scanning the supply chain, catching prompt injection — run across the tools people reach for, and where each one ends.

A more detailed feature matrix is available at [bromure.io/en/feature-matrix](https://bromure.io/en/feature-matrix).

| Protection | Dev Container<br><sub>VS Code</sub> | nono<br><sub>kernel sandbox</sub> | agent-vault<br><sub>octokraft</sub> | Agent Vault<br><sub>Infisical</sub> | Docker Sandboxes<br><sub>microVM</sub> | **Bromure**<br><sub>Agentic Coding</sub> |
| --- | --- | --- | --- | --- | --- | --- |
| **Isolation boundary**<br><sub>Where the blast radius stops</sub> | 🟡 Same container, shared kernel | 🟡 Kernel allow-lists, no own kernel | ❌ Agent runs in place | ❌ Proxy only; agent unboxed | ✅ microVM, its own kernel | ✅ Hardware VM, its own kernel |
| **Keep secrets out of the agent**<br><sub>Can it ever read the real credential?</sub> | ❌ Forwards SSH agent + git creds | 🟡 Blocks key files; proxies some | ✅ Piped in; no read path | ✅ Proxy attaches on the wire | ✅ Host proxy injects headers | ✅ Stub swapped at the wire |
| **Credential scope & approval**<br><sub>Per-use limits, read-only, expiry, consent</sub> | ❌ No per-use scoping | 🟡 Approval flow + egress filter | 🟡 Per-secret TTL; blocks shells | 🟡 Egress filter per endpoint | 🟡 Domain allow-list; in-VM code can still use it | ✅ Per-destination consent + TTL |
| **Supply-chain scanning**<br><sub>Catching malicious / vulnerable packages</sub> | ❌ No registry scanning | ❌ Signing only, no pkg scan | ❌ Out of scope | ❌ Out of scope | ❌ No package scanning | ✅ Age-gate, OSV, socket.dev |
| **Prompt-injection detection**<br><sub>Scanning untrusted content & rules files</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ PromptGuard + ModernBERT |
| **Audit trail**<br><sub>Recording what the agent did</sub> | ❌ Container logs only | 🟡 Immutable local audit | ❌ | 🟡 Request logging | 🟡 Request logging | ✅ Full session trace, encrypted |
| **Supply-chain inventory** <sub>(Enterprise)</sub><br><sub>A record of every package fetched</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Every dependency + verdict, searchable |
| **Token usage** <sub>(Enterprise)</sub><br><sub>Which files burn the most tokens</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Per file, repo, and model |

✅ Full — built in, enforced &nbsp;·&nbsp; 🟡 Partial — limited or optional &nbsp;·&nbsp; ❌ None — not addressed

<sub>Compiled from each project's public documentation, June 2026. Here, agent-vault refers to [octokraft/agent-vault](https://octokraft.github.io/agent-vault/) (pipe-based secret injection), distinct from Infisical's Agent Vault (HTTP credential proxy). Docker Sandboxes is an experimental preview whose brokered credentials stay usable by anything inside the VM. Bromure's fleet-wide package inventory and token-usage rollups are surfaced in Bromure Enterprise Manager. These tools move fast — see something out of date? Open an issue.</sub>

## Build

```bash
./build.sh                 # browser app
./build.sh bromure-ac      # agentic-coding app
swift test                 # tests
```

Outputs land in `.build/arm64-apple-macosx/release/`.

## Architecture

Three SPM targets:

| Target          | Path                      | Notes                                                           |
| --------------- | ------------------------- | --------------------------------------------------------------- |
| `bromure`       | `Sources/Browser/`        | Browser app + SwiftUI + AppKit window management                |
| `bromure-ac`    | `Sources/AgentCoding/`    | Agentic-coding app + MITM proxy + cloud-credential plumbing     |
| `SandboxEngine` | `Sources/SandboxEngine/`  | Shared VM lifecycle, image management, virtio bridges           |

Both apps pre-warm a pool of VMs in the background so new sessions open in under a second. Guest ↔ host communication runs over vsock (clipboard, file transfer, MITM proxy).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or newer) — `Virtualization.framework` only supports ARM64 guest VMs on Apple Silicon hosts.

## Author

- [Renaud Deraison](https://www.linkedin.com/in/rderaison/) (prompting)
- [Claude + Opus 4.7](https://www.anthropic.com) (implementation)
