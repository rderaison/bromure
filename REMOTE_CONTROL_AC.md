# Bromure Agentic Coding — Remote Control

Bromure Agentic Coding exposes the same three-layer remote-control stack as the browser, scoped to AC's profile + session model (no CDP — AC sessions run kitty + Claude Code / Codex, not Chromium).

| Browser default port | AC default port |
|---|---|
| `9222` | `9223` |

---

## Layer 1: HTTP API

JSON REST on `http://127.0.0.1:9223`. Bound to loopback only.

> **Off by default.** The automation server is opt-in. Enable it via
> **Bromure → Preferences → Automation → Enable automation server**, or
> from the shell:
> ```bash
> defaults write io.bromure.agentic-coding automation.enabled -bool true
> ```
> Disable the same way (or just flip the toggle off). Tests/ac-e2e.mjs
> expects it on; `Jenkinsfile.e2e.ac` sets the default before launch.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/profiles` | List profiles (id, name, color, tool, authMode, mcpServerCount) |
| `POST` | `/sessions` | Open a session (`{"profile":"name-or-uuid"}`). Waits up to 30s for the window to appear. |
| `GET` | `/sessions` | List currently-open session windows |
| `GET` | `/sessions/:id` | Get session info |
| `DELETE` | `/sessions/:id` | Close the session window |

**Debug endpoints** (requires `BROMURE_DEBUG_CLAUDE`):

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sessions/:id/exec` | Run a shell command inside the guest. Same wire protocol as the browser's: `[u32be len][JSON]` over a `ShellBridge`-dequeued vsock. |
| `GET` | `/app/state` | locale, mainWindowOpen, editorOpen, profileCount, sessionCount, hasBaseImage |

### Example

```bash
# List profiles
curl -s http://127.0.0.1:9223/profiles | jq '.profiles[].name'

# Open a session against the "Claude Dev" profile
curl -s -X POST http://127.0.0.1:9223/sessions \
  -H 'Content-Type: application/json' \
  -d '{"profile":"Claude Dev"}'

# Shell into the VM (debug only)
curl -s -X POST http://127.0.0.1:9223/sessions/<UUID>/exec \
  -H 'Content-Type: application/json' \
  -d '{"command":"uname -a", "timeout":5}'
```

---

## Layer 2: MCP Server

`bromure-ac mcp` is a stdio MCP server that wraps Layer 1 + the AppleScript bridge into high-level tools for AI agents.

```bash
bromure-ac mcp          # 8 base tools
bromure-ac mcp --debug  # base + 4 debug tools (vm_exec, vm_read_file, vm_write_file, app_state)
```

### Configuration

Add to `.mcp.json` (Claude Code) or your MCP client's config:

```json
{
  "mcpServers": {
    "bromure-ac": {
      "command": "/Applications/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac",
      "args": ["mcp"]
    }
  }
}
```

For debug tools (requires `BROMURE_DEBUG_CLAUDE=1` on the running app):

```json
{
  "mcpServers": {
    "bromure-ac": {
      "command": "/Applications/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac",
      "args": ["mcp", "--debug"]
    }
  }
}
```

### Tools

**Profile + session management:**

| Tool | Description |
|------|-------------|
| `bromure_ac_list_profiles` | List all AC profiles |
| `bromure_ac_list_sessions` | List currently-open session windows |
| `bromure_ac_open_session` | Launch a session for a profile |
| `bromure_ac_close_session` | Close any open session for a profile |
| `bromure_ac_get_profile` | Full Profile blob as JSON (incl. nested credentials, MCP servers) |
| `bromure_ac_set_profile` | Replace a profile from a JSON blob (id preserved) |
| `bromure_ac_get_profile_setting` | Read one simple field (name, color, tool, authMode, apiKey, …) |
| `bromure_ac_set_profile_setting` | Write one simple field |

**Debug tools** (`--debug`):

| Tool | Description |
|------|-------------|
| `bromure_ac_app_state` | App-state snapshot |
| `bromure_ac_vm_exec` | Run a shell command in the profile's VM |
| `bromure_ac_vm_read_file` | Read a text file from the VM |
| `bromure_ac_vm_write_file` | Write a text file inside the VM |

---

## Layer 3: AppleScript

The Cocoa scripting bridge in `Sources/AgentCoding/BromureAC.sdef`. Useful for host-side ops that the HTTP API doesn't expose, and for driving the app from shell scripts (the screenshot pipeline and the e2e test suite use it).

Selected commands:

| Command | Returns |
|---------|---------|
| `tell application "Bromure Agentic Coding" to get app state` | JSON: locale, mainWindowOpen, editorOpen, profileCount, … |
| `… to list profiles` | JSON array of `{id, name, color}` |
| `… to create ac profile "name" color "blue"` | UUID |
| `… to delete ac profile "name-or-uuid"` | — |
| `… to get profile json "name-or-uuid"` | Full Profile as JSON |
| `… to set profile json "name-or-uuid" to value "{…}"` | `"ok"` or `"error: …"` |
| `… to get profile setting "X" key "tool"` | `"claude"` / `"codex"` |
| `… to set profile setting "X" key "memoryGB" to value "8"` | `"ok"` / `"error: …"` |
| `… to open ac profile editor "X"` / `… to close ac profile editor` | — |
| `… to select editor category "mcp"` | — |
| `… to open ac session "X"` / `… to close ac session "X"` / `… to list ac sessions` | — |
| `… to get ac app setting "automation.port"` | `"9223"` |
| `… to set ac app setting "automation.enabled" to value "false"` | `"ok"`; toggles the HTTP server live |

See `BromureAC.sdef` for the complete dictionary.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  External clients                                           │
│    • Tests/ac-e2e.mjs                                       │
│    • bromure-ac mcp (stdio subprocess)                      │
│    • osascript                                              │
│    • curl / your favorite HTTP client                       │
└──────────────────────┬──────────────────────────────────────┘
                       │
       ┌───────────────┼───────────────┐
       │               │               │
       ▼               ▼               ▼
   AppleScript     HTTP :9223      MCP (stdio)
       │               │               │
       └───────────────┼───────────────┘
                       ▼
         ACAppDelegate (BromureAC.swift)
                       │
       ┌───────────────┼───────────────┐
       │               │               │
       ▼               ▼               ▼
   ProfileStore   TabbedSession-   ShellBridge[]
                  Window                (debug only,
                                         vsock 5800)
                                              │
                                              ▼
                                   shell-agent.py (guest)
```

---

## Security

- Layer 1 + Layer 2 endpoints bind to loopback only (`127.0.0.1`).
- Debug endpoints (`/exec`, `/app/state`, all `bromure_ac_vm_*` MCP tools) require `BROMURE_DEBUG_CLAUDE=1` in the app's environment.
- Per-session `ShellBridge` instances are gated on the same env var, so the guest's `shell-agent.py` is only shipped + autostarted on debug builds. Production sessions have no shell-exec surface.
- Profile bearer tokens never traverse the HTTP API in plaintext — `bromure_ac_get_profile` returns the JSON-encoded Profile which can include secrets, so the API is intentionally loopback-only.

---

## Fat client (remote mirror over SSH)

A local bromure-ac can connect to a **remote** bromure-ac and mirror its full UI 1:1 —
the grid, workspaces with their tabs/worktrees, and automations — with bidirectional
edits and interactive terminals. See `REMOTE_FAT_CLIENT_PLAN.md` for the architecture;
Phases 1–3 are implemented.

**Transport.** The embedded SSH server (`remote enable`) gains one machine-client verb:
an `exec` request of exactly `bromure-fatclient/1 control` bridges the SSH channel to the
remote's owner-only `control.sock` (no PTY, no menu). The client speaks the **existing**
control-plane HTTP API over that tunnel, so nothing new is on the wire. Human `ssh` is
unchanged (still forced into `__remote-menu`). Auth is the bridge's ed25519 host key +
`authorized_keys`; the client's own key is under `…/BromureAC/remote-client/`.

**Setup.** On the remote: `bromure-ac remote enable` then
`bromure-ac remote key add '<fat-client-pubkey>'`. On the client: **Window → Connect to
Remote Host…** (⇧⌘K) — enter address/port/user, copy your client key to the remote, connect.

**New trusted control-socket routes** (used by the mirror; local socket only):

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/state` | One-shot snapshot: version, workspaces, running VMs (incl. ports + docker), grid layout, automations, pending prompts |
| `GET` | `/workspaces` | All workspaces (running or not) as sidebar rows (incl. memory/cpu/disk spec for the dashboard) |
| `GET`/`POST` | `/grid-layout` | Read / replace the grid (StageLayout), last-writer-wins |
| `GET`/`POST` | `/automations` | List / upsert scheduled automations |
| `DELETE`/`POST` | `/automations/{id}[/run\|/toggle]` | Delete, run-now, toggle |
| `POST` | `/vms/{id}/file` | One native `{"file": …}` op in the guest — the remote file browser's transfer plane |
| `POST` | `/vms/{id}/docker` | A docker dashboard action (`start`/`stop`/`remove`/`logs`/`attach`/`run`/`binfmt`/`binfmt-off`/`watch`), validated host-side, sent as the same outbox verb the local GUI uses |
| `POST` | `/prompts/{id}/answer` | Answer a pending decision prompt (`{"choice": n}`) surfaced in `/state`'s `pendingPrompts` |

Interactive terminals reuse the existing `POST /vms/{id}/exec` hijacked-stream path;
the client spawns `__attach-window --remote <hostID> <vm> <window>`.

**Decision prompts follow the initiator.** A workspace launch driven over the
control socket (`remoteInitiated`) routes its decision prompts — home-storage
upgrade, base-image drift reset, compromised-VM wipe — through
`PendingPromptBroker` instead of a server-side `NSAlert`: the fat client sees
them in `/state`, renders them as local alerts, and answers via
`POST /prompts/{id}/answer`. Timeouts resolve to the safe (non-destructive)
choice; if no client is polling `/state`, the safe default applies immediately.

**Secrets are write-only over every remote surface.** `GET /profiles/{id}?full=1`
runs `ProfileSecrets.extract` (now also covering MCP server `environment`
values, MCP `rawJSON` blobs, and profile-level environment-variable values);
writes blank-keep. The AppleScript `get profile json` bridge is scrubbed the
same way unless `BROMURE_DEBUG_CLAUDE` is set (the e2e suite's round-trip).
