# Bromure Remote Control

Bromure exposes three layers of remote control, each building on the one below.

---

## Layer 1: HTTP API

A JSON REST API on a single port (default 9222) for session and profile management. This is Bromure's own protocol -- not part of CDP.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (`{"status":"ok"}`) |
| `GET` | `/profiles` | List profiles that allow automation |
| `POST` | `/sessions` | Create a new browser session (`{"profile":"name"}`) |
| `GET` | `/sessions` | List active sessions |
| `GET` | `/sessions/:id` | Get session info |
| `DELETE` | `/sessions/:id` | Destroy a session and its VM |

**Debug endpoints** (requires `BROMURE_DEBUG_CLAUDE` environment variable):

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sessions/:id/exec` | Execute a shell command in the VM |
| `GET` | `/app/state` | App phase, pool status, sessions, profiles |

### Example

```bash
# Create a session
curl -X POST http://127.0.0.1:9222/sessions \
  -d '{"profile":"Private Browsing","url":"https://example.com"}'

# Response includes a CDP WebSocket endpoint
{
  "id": "UUID",
  "webSocketDebuggerUrl": "ws://127.0.0.1:9222/cdp/UUID/devtools/browser/..."
}
```

---

## Layer 2: Chrome DevTools Protocol (CDP)

Bromure proxies the standard Chrome DevTools Protocol to Chromium running inside the VM. Any CDP client (Puppeteer, Playwright, raw WebSocket) can connect using the `webSocketDebuggerUrl` returned by the session creation API.

The CDP proxy is available at:

```
/cdp/:sessionId/*
```

This transparently forwards all HTTP and WebSocket traffic to Chromium's built-in CDP server (port 9222 inside the VM). The full CDP specification is supported -- Bromure does not modify, filter, or extend the protocol. Any command that Chromium's CDP accepts will work.

Standard CDP endpoints available through the proxy:

| Path | Description |
|------|-------------|
| `/cdp/:sessionId/json/version` | Browser version and WebSocket URL |
| `/cdp/:sessionId/json/list` | List open pages/targets |
| `/cdp/:sessionId/devtools/browser/:guid` | Browser-level WebSocket |
| `/cdp/:sessionId/devtools/page/:id` | Page-level WebSocket |

### CDP domains commonly used

- **Page** -- navigation, screenshots, lifecycle events
- **Runtime** -- JavaScript evaluation
- **DOM** -- document inspection, querySelector
- **Input** -- mouse clicks, keyboard events
- **Network** -- request interception, headers

---

## Layer 3: MCP Server

Bromure includes a built-in [Model Context Protocol](https://modelcontextprotocol.io) server that wraps Layers 1 and 2 into high-level tools for AI assistants (Claude Code, Openclaws, etc).

```bash
bromure mcp          # Standard tools (14 tools)
bromure mcp --debug  # Standard + debug tools (23 tools)
```

### Configuration

Add to `.mcp.json` or your MCP client configuration:

```json
{
  "mcpServers": {
    "bromure": {
      "command": "/Applications/Bromure.app/Contents/MacOS/bromure",
      "args": ["mcp"]
    }
  }
}
```

### Tools

**Session management:**

| Tool | Description |
|------|-------------|
| `bromure_list_profiles` | List profiles that allow automation |
| `bromure_list_sessions` | List active sessions |
| `bromure_open_session` | Create a session (waits for page load) |
| `bromure_close_session` | Destroy a session |

**Browser control** (uses CDP internally):

| Tool | Description |
|------|-------------|
| `bromure_navigate` | Navigate to a URL |
| `bromure_screenshot` | Capture page or element as PNG |
| `bromure_click` | Click an element by CSS selector |
| `bromure_type` | Type text into an input |
| `bromure_evaluate` | Execute JavaScript |
| `bromure_get_content` | Extract text or HTML |
| `bromure_get_links` | Extract all links |
| `bromure_wait_for` | Wait for a selector to appear |

**Compound workflows:**

| Tool | Description |
|------|-------------|
| `bromure_search` | Google search in one call |
| `bromure_get_page` | Fetch a URL and return text |

**Debug tools** (`--debug` flag required):

| Tool | Description |
|------|-------------|
| `vm_exec` | Run a shell command in the VM |
| `vm_read_file` | Read a file from the VM |
| `vm_write_file` | Write a file to the VM |
| `vm_processes` | List VM processes |
| `vm_network` | Network diagnostics |
| `app_health` | API health check |
| `app_state` | App state (phase, pool, sessions) |
| `app_sessions` | List sessions |
| `app_profiles` | List profiles |

---

## Layer 4: AppleScript

The macOS app itself is scriptable via AppleScript for app-level operations that don't go through the HTTP API.

```applescript
tell application "Bromure"
    create profile "Test" persistent true color "blue" home page "https://example.com"
    set profile setting "Test" key "allowAutomation" to value "true"
    set app setting "automation.enabled" to value "true"
    get app state
    delete profile "Test"
end tell
```

See the app's scripting dictionary (`bromure.sdef`) for the full command reference.

---

## Architecture

```
AI tool (Claude Code, Openclaws)
    |
    | MCP (stdio, JSON-RPC 2.0)
    v
bromure mcp (Swift binary, built into the app)
    |
    | HTTP + WebSocket (localhost:9222)
    v
Bromure.app (AutomationServer)
    |
    | vsock (host <-> guest VM)
    v
Chromium CDP (inside ephemeral Alpine Linux VM)
```

## Security

- **Per-profile opt-in**: Only profiles with "Allow Automation" enabled are visible to the API. Profiles without this flag cannot be used even if their UUID is known.
- **Bind address**: The default `127.0.0.1` restricts access to the local machine. Binding to `0.0.0.0` exposes the API to the network.
- **Ephemeral VMs**: Each session runs in a disposable VM. No data persists after the session is destroyed (unless the profile has "Retain Browsing Data" enabled).
- **No auth**: The API has no authentication. Rely on the bind address and firewall for access control.
