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
