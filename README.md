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
- **Bromure Agentic Coding** — a sandboxed environment for AI coding agents (Claude Code, Codex). A host-side MITM proxy swaps fake credentials for real ones on the wire so secrets never enter the VM, then adds supply-chain scanning, prompt-injection detection, a multi-model panel, local/hybrid inference, and remote access — all enforced at that one boundary.

<details>
<summary><strong>How Bromure Agentic Coding compares</strong></summary>

Isolation, keeping secrets out of the agent, scoping their use, scanning the supply chain, catching prompt injection: most tools pick one. Bromure does all five at a single boundary, then adds what a secret-broker never could: a model panel, local inference, and a way in from anywhere. Here is the same threat model run across the tools people reach for, and where each one stops.

A more detailed feature matrix is available at [bromure.io/en/feature-matrix](https://bromure.io/en/feature-matrix).

| Protection | Dev Container<br><sub>VS Code</sub> | nono<br><sub>kernel sandbox</sub> | agent-vault<br><sub>octokraft</sub> | Agent Vault<br><sub>Infisical</sub> | Docker Sandboxes<br><sub>microVM</sub> | Capsem<br><sub>air-gapped VM</sub> | **Bromure**<br><sub>Agentic Coding</sub> |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Security** | | | | | | | |
| **Isolation boundary**<br><sub>Where the blast radius stops</sub> | 🟡 Same container, shared kernel | 🟡 Kernel allow-lists, no own kernel | ❌ Agent runs in place | ❌ Proxy only; agent unboxed | ✅ microVM, its own kernel | ✅ Hardware VM, its own kernel | ✅ Hardware VM, its own kernel |
| **Keep secrets out of the agent**<br><sub>Can it ever read the real credential?</sub> | ❌ Forwards SSH agent + git creds | 🟡 Blocks key files; proxies some | ✅ Piped in; no read path | ✅ Proxy attaches on the wire | ✅ Host proxy injects headers | ❌ Real API keys live in the VM | ✅ Stub swapped at the wire |
| **Credential scope & approval**<br><sub>Per-use limits, read-only, expiry, consent</sub> | ❌ No per-use scoping | 🟡 Approval flow + egress filter | 🟡 Per-secret TTL; blocks shells | 🟡 Egress filter per endpoint | 🟡 Domain allow-list; in-VM code can still use it | 🟡 Domain + method/path egress rules | ✅ Per-destination consent + TTL |
| **Supply-chain scanning**<br><sub>Catching malicious / vulnerable packages</sub> | ❌ No registry scanning | ❌ Signing only, no pkg scan | ❌ Out of scope | ❌ Out of scope | ❌ No package scanning | ❌ No package scanning | ✅ Age-gate, OSV, socket.dev |
| **Prompt-injection detection**<br><sub>Scanning untrusted content & rules files</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ PromptGuard + ModernBERT |
| **Audit trail**<br><sub>Recording what the agent did</sub> | ❌ Container logs only | 🟡 Immutable local audit | ❌ | 🟡 Request logging | 🟡 Request logging | 🟡 Full HTTP bodies in SQLite | ✅ Full session trace, encrypted |
| **Supply-chain inventory** <sub>(Enterprise)</sub><br><sub>A record of every package fetched</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Every dependency + verdict, searchable |
| **Productivity** | | | | | | | |
| **Token usage** <sub>(Enterprise)</sub><br><sub>Which files burn the most tokens</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Per file, repo, and model |
| **Multi-model fusion**<br><sub>A panel of models, judged & synthesized</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Panel + judge, on the wire |
| **Local & hybrid models**<br><sub>Inference on your own silicon or in the cloud, local fallback when cloud is down</sub> | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Local or hybrid, on the wire |
| **Reach it from anywhere**<br><sub>Attach to the sandbox remotely</sub> | 🟡 VS Code remote | ❌ | ❌ | ❌ | 🟡 docker exec, local | ❌ | ✅ App, CLI, or SSH |

✅ Full — built in, enforced &nbsp;·&nbsp; 🟡 Partial — limited or optional &nbsp;·&nbsp; ❌ None — not addressed

> Hiding a token isn't the same as governing its use. Docker Sandboxes keeps the raw value out of the VM — but its proxy still attaches that credential to any outbound request the sandbox makes, so a compromised package installed on the side can spend it against an allow-listed domain without ever seeing it. Only Bromure scans the package before it runs and gates each use — consent, read-only, a TTL — enforcing all five controls at one boundary the agent can't reach around. The same boundary is where Fusion, local inference, and remote access plug in.

<sub>Compiled from each project's public documentation, June 2026. Here, agent-vault refers to [octokraft/agent-vault](https://octokraft.github.io/agent-vault/) (pipe-based secret injection), distinct from Infisical's Agent Vault (HTTP credential proxy). Docker Sandboxes is an experimental preview whose brokered credentials stay usable by anything inside the VM. Bromure's fleet-wide package inventory and token-usage rollups are surfaced in Bromure Enterprise Manager. These tools move fast — see something out of date? Open an issue.</sub>

</details>

<details>
<summary><strong>How Bromure Web compares</strong></summary>

Every secure browser polices the web. Bromure isolates it. Talon and Island harden Chromium on your machine. Menlo isolates the web — in its cloud. Bromure runs every session in a disposable VM on your own Mac: real isolation, locally.

A more detailed feature matrix is available at [bromure.io/en/feature-matrix](https://bromure.io/en/feature-matrix).

| Capability | Talon<br><sub>Prisma Access Browser</sub> | Island<br><sub>Enterprise Browser</sub> | Menlo<br><sub>Remote isolation</sub> | **Bromure**<br><sub>Web</sub> |
| --- | --- | --- | --- | --- |
| **Isolation & containment** | | | | |
| Isolates untrusted web code from your real OS | ❌ | ❌ | ✅ | ✅ |
| Host stays safe if the browser is exploited | 🟡 | ❌ | ✅ | ✅ |
| Disposable sessions that leave no trace | 🟡 | ❌ | ✅ | ✅ |
| Isolation that runs locally, not in a vendor cloud | ❌ | ❌ | ❌ | ✅ |
| **Device & data controls** | | | | |
| Real webcam and mic inside a secure session | ✅ | 🟡 | 🟡 | ✅ |
| Download and upload controls | ✅ | ✅ | ✅ | ✅ |
| Malware scanning of downloads | ✅ | 🟡 | ✅ | ✅ |
| Copy-paste and screenshot controls | 🟡 | ✅ | 🟡 | ✅ |
| Blocks data leaving to local printers, NAS and USB | 🟡 | 🟡 | 🟡 | ✅ |
| **Web protection** | | | | |
| Phishing detection | ✅ | ✅ | ✅ | 🟡 |
| URL and category web filtering | ✅ | ✅ | ✅ | 🟡 |
| Built-in per-session VPN and IP masking | 🟡 | ❌ | 🟡 | ✅ |
| Browser extension governance | ✅ | ✅ | 🟡 | 🟡 |
| **Enterprise management** | | | | |
| Central console and managed profiles | ✅ | ✅ | ✅ | ✅ |
| Session logging and full audit trail | ✅ | ✅ | ✅ | ✅ |
| SIEM and OpenTelemetry export | ✅ | ✅ | ✅ | ✅ |
| Enforce use via Okta, Workspace or Entra | ✅ | ✅ | ✅ | ✅ |
| Access auto-revoked when a user is offboarded | 🟡 | ✅ | 🟡 | ✅ |
| Content-aware DLP and file sanitization | ✅ | ✅ | ✅ | 🟡 |
| BYOD and unmanaged devices | ✅ | ✅ | ✅ | ✅ |
| **Platform & model** | | | | |
| Runs on every major platform | ✅ | ✅ | ✅ | 🟡 |
| Open source and free to use | ❌ | ❌ | ❌ | ✅ |
| Runs on-device with no per-seat cloud | 🟡 | 🟡 | ❌ | ✅ |

✅ Built in &nbsp;·&nbsp; 🟡 Partial or limited &nbsp;·&nbsp; ❌ Not offered

> Talon and Island make the browser a better-policed front door — but it still runs on your real OS. Menlo adds true isolation, then routes every page through its cloud. Bromure is the only one that seals each session in a disposable VM on your own machine: nothing reaches your Mac, nothing leaves your device, and closing the window erases all of it.

<sub>Compiled from public product documentation (Palo Alto Networks, Island, Menlo Security) in June 2026. Partial marks capabilities that are limited, optional, licensing-gated, or — for Bromure phishing detection — still in beta.</sub>

</details>

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
