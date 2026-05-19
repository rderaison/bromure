# Bromure Agentic Coding — Profile Settings Reference

Each profile in Bromure Agentic Coding has its own independent configuration across nine panels, accessed by clicking the gear icon next to a profile in the picker.

---

## General

<p align="center">
  <img src="Resources/ac/editor_general_en.jpg" width="600" alt="General settings panel">
</p>

Basic identity and behavior for the profile.

| Setting | Description |
|---|---|
| **Name** | The display name shown in the profile list. |
| **Color** | A colored dot drawn next to the profile in the picker to visually distinguish profiles. Options: Blue, Red, Green, Orange, Purple, Pink, Teal, Gray. |
| **Keyboard layout** | The keyboard layout used inside the VM. "Auto (match macOS)" dynamically mirrors whichever input source is active on the host, with live updates when you switch. Select any other layout to pin the VM to a specific XKB layout regardless of macOS state. |
| **Key repeat delay** | Time in milliseconds before a held key starts repeating inside the VM. Defaults to your macOS value; change it to override the X11 key-repeat cadence independently of the host. |
| **Key repeat rate** | Repeat frequency in Hz once the delay has elapsed. Defaults to your macOS value. Useful when the X-server pipeline makes typing feel laggier than in a Cocoa app — bumping the rate 2× the macOS value is a common fix. |
| **When closing the window** | What happens to the VM when you close a session window: **Suspend** (saves RAM to disk for instant resume — default), **Shut down** (clean ACPI poweroff), or **Ask** (prompt each time). |
| **Notes (optional)** | A short note about the profile. Shown as a tooltip when you hover over the profile in the list. |

---

## Agent

<p align="center">
  <img src="Resources/ac/editor_agent_en.jpg" width="600" alt="Agent settings panel">
</p>

Choose which coding agents are available in this profile and how they authenticate. The agent marked **Primary** is auto-launched in the first kitty tab when a session opens; other enabled agents are installed and authenticated but started on demand from a new tab.

| Setting | Description |
|---|---|
| **Claude Code** | Enable or disable the Claude Code agent for this profile. Toggle on to configure. |
| **Claude Code — Primary** | Mark Claude Code as the primary agent (auto-launched on session start). Click "Primary" on any enabled agent to promote it. |
| **Claude Code — Auth** | Authentication method for Claude Code: **API token** (paste an `ANTHROPIC_API_KEY` — injected as an env var, never written into the VM directly), **Subscription (interactive login)** (run `claude login` once inside the VM), or **Bedrock (AWS)** (use your AWS credentials via the Bedrock runtime — requires AWS credentials configured in the Credentials tab). |
| **Codex** | Enable or disable the OpenAI Codex agent for this profile. Toggle on to configure authentication. |
| **Codex — Auth** | Authentication method for Codex: **API token** (paste an `OPENAI_API_KEY`) or **Subscription (interactive login)** (run `codex login` once inside the VM). |

---

## Folders

<p align="center">
  <img src="Resources/ac/editor_folders_en.jpg" width="600" alt="Folders settings panel">
</p>

Mac folders to share into the VM. Each folder is mounted at `/home/ubuntu/<basename>` (e.g., `~/Documents` → `~ubuntu/Documents`). Capped at 8 folders per profile.

| Setting | Description |
|---|---|
| **Folder list** | The host paths currently shared into the VM. Each row shows the folder name and its full path on your Mac. Click the minus button to remove a share. |
| **Add folder…** | Opens a file picker to select one or more directories to share. Greyed out when 8 folders are already configured. |

---

## Credentials

<p align="center">
  <img src="Resources/ac/editor_credentials_en.jpg" width="600" alt="Credentials settings panel">
</p>

Secrets and identities injected into the VM at session start. All real values stay on the host; the MITM proxy substitutes them for fake placeholders on the wire so secrets never enter the VM's address space.

| Setting | Description |
|---|---|
| **Git Identity — Name** | Written to `user.name` in `~/.gitconfig` inside the VM. Leave blank to keep git's defaults. |
| **Git Identity — Email** | Written to `user.email` in `~/.gitconfig` inside the VM. Leave blank to keep git's defaults. |
| **SSH Keys** | Expandable section. Manages the auto-generated ed25519 keypair (one per profile) and any imported private keys. The generated public key is shown here for pasting into github.com/settings/keys. Imported keys (RSA, ed25519, ecdsa, including passphrase-protected ones) are loaded into the per-profile bromure ssh-agent at every session launch; passphrases are stored in the macOS Keychain. |
| **SSH Keys — Require approval to use** | When enabled, every SSH sign request using this key shows a host-side consent dialog. The user picks a time-bounded grant (5 min / 1 hr / rest of session) or denies. Off by default. |
| **GitHub Tokens** | Expandable section. Personal access tokens for git over HTTPS to github.com. Written to `~/.git-credentials` and picked up by the `gh` CLI automatically. The real token stays on the host; the proxy swaps a fake on outbound requests. |
| **GitLab Tokens** | Expandable section. Personal access tokens for git over HTTPS to gitlab.com and self-hosted GitLab instances. Picked up by the `glab` CLI automatically. |
| **Bitbucket Tokens** | Expandable section. App passwords for git over HTTPS to bitbucket.org. |
| **Kubernetes** | Expandable section. One entry per cluster context. Bromure generates a synthetic `~/.kube/config` in the VM with throwaway client certs; real credentials stay on the host and are substituted by the proxy on API-server requests. Exec-plugin contexts are polled on the host so `kubectl` always sees a fresh token. Contexts can be added manually or imported from an existing kubeconfig file. |
| **DigitalOcean** | Expandable section. Personal access token from cloud.digitalocean.com. Injected as `DIGITALOCEAN_ACCESS_TOKEN` env and `~/.config/doctl/config.yaml` — `doctl auth init` is unnecessary. |
| **AWS** | Expandable section. AWS credentials for the `aws` CLI and SDKs. Supports **Static keys** (Access Key ID + Secret Access Key + optional Session Token + default region) and **SSO / Identity Center** (select a named profile from `~/.aws/config`). The real secret never reaches the VM — the host's MITM proxy intercepts and re-signs SigV4 requests with the real material; if the proxy is bypassed, AWS rejects with `InvalidSignatureException`. |
| **AWS — Require approval to use** | When enabled, every host-side SigV4 signing call (one per AWS API request) shows a consent prompt until a time-bounded grant covers it. |
| **Container Registries** | Expandable section. Per-registry HTTP Basic auth for `docker pull` / `docker push`. Supports Docker Hub, GHCR, GitLab Container Registry, Quay, and arbitrary private registries. A fake `base64("<user>:<derived>")` is written to `~/.docker/config.json` in the VM; the proxy substitutes the real value on the wire. Can be populated by importing an existing `~/.docker/config.json`. |
| **Other API keys** | Expandable section. Manual token-swap rules for any API beyond the auto-handled ones (Anthropic, OpenAI, GitHub, GitLab, DigitalOcean, Kubernetes). Each entry mints a fresh fake (`brm_…`) exported as a named env var inside the VM; the proxy swaps it back to the real value on outbound requests to the optionally-specified host. |

---

## Environment

<p align="center">
  <img src="Resources/ac/editor_environment_en.jpg" width="600" alt="Environment settings panel">
</p>

Plain `KEY=VALUE` pairs exported into every shell in the VM via `proxy.env` (sourced from `.bashrc`). Values are written verbatim — no proxy substitution — so do not put secrets here. Intended for non-secret toggles such as log levels, feature flags, and build options.

| Setting | Description |
|---|---|
| **Variable list** | The environment variables currently configured. Each row has a name field and a value field. Click the minus button to remove a variable. |
| **Add variable** | Appends a new empty `KEY=VALUE` row. |

---

## MCP

<p align="center">
  <img src="Resources/ac/editor_mcp_en.jpg" width="600" alt="MCP settings panel">
</p>

Model Context Protocol servers that give the agent access to external tools and context. Configurations are translated into the appropriate format for the active agent (Claude Code JSON or Codex TOML) and injected into the VM at boot.

| Setting | Description |
|---|---|
| **Server list** | MCP servers currently configured for this profile. Each server can be toggled on or off independently. Supports **HTTP** transport (a URL-based remote server, with optional bearer token) and **stdio** transport (a local command launched inside the VM). |
| **Add server** | Appends a new MCP server entry. |

---

## Tracing

<p align="center">
  <img src="Resources/ac/editor_tracing_en.jpg" width="600" alt="Tracing settings panel">
</p>

Controls how the MITM proxy records traffic for this profile. Higher levels write encrypted body files to disk; all are opt-in. Recorded data can be viewed in App → Trace Inspector (⇧⌘I).

| Setting | Description |
|---|---|
| **Session trace** | How aggressively the proxy records traffic. **Off** — nothing recorded (default). **Activity** — metadata only: host, status, latency, swap report, leak warnings; no request or response bodies. **AI request details** — same as Activity, plus full bodies for known LLM hosts (Anthropic, OpenAI, Google, Cohere, Mistral, Perplexity, x.ai, Groq, Replicate, HuggingFace). **Everything** — bodies for every host; uses disk space fastest (capped at 100 MB per session / 5 GB total). Bodies are AES-GCM encrypted with the same keychain key as profile secrets. |
| **Private mode** | (Only shown on Macs enrolled with a bromure.io workspace.) When enabled, sessions for this profile do not stream metadata (tools, files, commands, token usage) to the workspace. The local trace inspector is unaffected. Useful when working with a personal API key you do not want your admin to see. |
| **Claude subscription token swap** | (Shown only after the proxy has prompted about this profile.) Displays whether the real Claude OAuth tokens are currently being swapped by the proxy (**Active**) or whether the user declined the swap (**Declined**). A reset button lets the user be asked again on the next session. |
| **Codex subscription token swap** | Same three-state swap consent as above, scoped to the Codex / ChatGPT OAuth tokens (`~/.codex/auth.json`). Shown independently so a profile that uses both agents can manage each provider separately. |

---

## Appearance

<p align="center">
  <img src="Resources/ac/editor_appearance_en.jpg" width="600" alt="Appearance settings panel">
</p>

Visual appearance of the kitty terminal window. Defaults are seeded from your macOS Terminal.app default profile.

| Setting | Description |
|---|---|
| **Font** | The font family used in the terminal. Choose from any font installed on your Mac. Size is set in points via a stepper. Only font families without a leading `.` are offered — macOS-internal names that Linux fontconfig cannot resolve are excluded. |
| **Cursor** | Cursor shape inside the terminal: **Block**, **Beam (I-cursor)**, or **Underline**. |
| **Colors — Background** | Terminal background color, as a color picker swatch. |
| **Colors — Text** | Terminal foreground (text) color, as a color picker swatch. |
| **Opacity** | Combined window and terminal opacity, from 30% to 100%. Applied as both kitty's `background_opacity` (requires a compositor in the VM) and the macOS window's `alphaValue` (always effective — produces a see-through-to-the-desktop effect). Default is 97%. |
| **Reset to Terminal.app** | Restores all appearance fields to the values read from your macOS Terminal.app default profile at app startup. |

---

## Resources

<p align="center">
  <img src="Resources/ac/editor_resources_en.jpg" width="600" alt="Resources settings panel">
</p>

Storage layers, memory, and network configuration for the profile's VM.

### Storage

Three layers stack to make the profile's environment. The bottom layer is shared and immutable; the top two are per-profile and can be erased independently.

| Setting | Description |
|---|---|
| **Your home folder** | The per-profile `/home/ubuntu` directory — dotfiles, `.ssh` keys, `npm-global`, `.cargo`, shell history, and anything else the agent writes to home. Shows last-active time and current size. **Erase home…** wipes this layer and resets the home directory to its post-clone state. |
| **Profile system disk** | A read-write copy of the base OS cloned specifically for this profile. Holds anything installed via `sudo apt install`, edits to `/etc`, `/var`, and system-level config. **Reset to base…** discards all system-level changes and re-clones from the current base image. |
| **Base OS image** | The shared, immutable base image: Ubuntu Noble + Claude Code + Codex + kitty + gh + glab + fonts. Shared by every profile; read-only at runtime. Shows the current version stamp and build date. Rebuilt via the app menu (takes ~5–10 minutes). |

### Memory

| Setting | Description |
|---|---|
| **VM RAM** | RAM allocated to this profile's VM, in GB (2–32 GB, step 2). Defaults to a host-scaled value (4 GB on hosts with less than 18 GB RAM, 6 GB up to 36 GB, 8 GB on larger machines). Increase this if Claude / Codex feels sluggish or Rust builds run out of memory. |

### Network

| Setting | Description |
|---|---|
| **Network mode** | **NAT** (default) — the VM shares your Mac's network connection via VZ's built-in NAT; egress works, nothing on your LAN can reach the VM. **Bridged** — the VM gets its own LAN-routable IP address via DHCP on the chosen physical interface. |
| **Interface** | (Bridged mode only.) The physical network interface the VM bridges to. Defaults to the first available bridged interface if left unset. |
