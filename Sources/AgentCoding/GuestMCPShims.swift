import Foundation

// The MCP servers' guest halves: the stdio shims agents launch (each pipes
// to its host server over vsock), their entries in the agents' configs, and
// where they're staged in the meta share. macOS (SessionDisk) and the Linux
// daemon stage the same files.

extension SessionDisk {

    /// Guest path of the stdio shim, staged into the (read-only) meta share.
    static let browserMCPShimGuestPath = "/mnt/bromure-meta/bromure-browser-mcp.py"
    /// Meta-share file holding Kimi's approval-mode flag (see KimiApprovals).
    public static let kimiApprovalsMetaFile = "kimi-approvals"
    static let automationMCPShimGuestPath = "/mnt/bromure-meta/bromure-automations-mcp.py"
    static let kubeMCPShimGuestPath = "/mnt/bromure-meta/bromure-infra-mcp.py"
    static var kubeMCPClaudeEntry: [String: Any] {
        ["command": "python3", "args": [kubeMCPShimGuestPath]]
    }
    static var kubeMCPShimScript: String {
        taskMCPShimScript
            .replacingOccurrences(of: "PORT = \(taskBoardMCPVsockPort)", with: "PORT = \(kubeMCPVsockPort)")
            .replacingOccurrences(of: "bromure-task-mcp", with: "bromure-infra-mcp")
            .replacingOccurrences(of: "task-board MCP", with: "infrastructure MCP")
    }
    /// The display MCP: show_media / show_chart, rendered by the chat from
    /// the transcript. `alwaysLoad` like delegation — two small tools.
    static let displayMCPGuestPath = "/mnt/bromure-meta/bromure-display-mcp.py"
    static var displayMCPClaudeEntry: [String: Any] {
        ["command": "python3", "args": [displayMCPGuestPath], "alwaysLoad": true]
    }
    static let delegationMCPShimGuestPath = "/mnt/bromure-meta/bromure-delegation-mcp.py"
    /// `alwaysLoad`: Claude Code otherwise defers MCP tools behind its
    /// ToolSearch tool, and every agent spent a whole model turn loading
    /// these before its first request / deliver. They're few and small.
    static var delegationMCPClaudeEntry: [String: Any] {
        ["command": "python3", "args": [delegationMCPShimGuestPath], "alwaysLoad": true]
    }
    /// The task shim on the delegation port, announcing not a branch but
    /// the tmux window it runs in — read from its own $TMUX_PANE, so the
    /// host binds the connection to the session shown in that window and
    /// the agent can't claim to be another.
    static var delegationMCPShimScript: String {
        taskMCPShimScript
            .replacingOccurrences(of: "PORT = \(taskBoardMCPVsockPort)", with: "PORT = \(delegationMCPVsockPort)")
            .replacingOccurrences(of: "bromure-task-mcp", with: "bromure-delegation-mcp")
            .replacingOccurrences(of: "task-board MCP", with: "delegation MCP")
            .replacingOccurrences(of: "import socket, sys, threading, time",
                                  with: "import os, socket, subprocess, sys, threading, time")
            .replacingOccurrences(of: "HELLO = sys.argv[1] if len(sys.argv) > 1 else \"\"",
                                  with: delegationMCPHelloBlock)
    }
    static var switchboardMCPShimScript: String {
        delegationMCPShimScript
            .replacingOccurrences(of: "PORT = \(delegationMCPVsockPort)", with: "PORT = \(switchboardMCPVsockPort)")
            .replacingOccurrences(of: "bromure-delegation-mcp", with: "bromure-switchboard-mcp")
            .replacingOccurrences(of: "delegation MCP", with: "switchboard MCP")
            .replacingOccurrences(of: "HELLO = _hello()\n", with: "HELLO = _hello()\n" + switchboardTokenBlock)
    }
    /// The Switchboard's token (SwitchboardToken), from its folder: the
    /// pane's directory, else the agent's (the shim inherits its cwd). Never
    /// from the command line or the environment.
    static let switchboardTokenBlock = """
    def _token():
        dirs = []
        pane = os.environ.get("TMUX_PANE", "")
        if pane:
            try:
                d = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{pane_current_path}"],
                                   capture_output=True, text=True, timeout=5).stdout.strip()
                if d: dirs.append(d)
            except Exception:
                pass
        dirs.append(os.getcwd())
        for d in dirs:
            try:
                with open(os.path.join(d, ".bromure-switchboard-token")) as f:
                    t = f.read().strip()
                if t and all(c in "0123456789abcdef" for c in t):
                    return t
            except Exception:
                pass
        return ""
    _TOKEN = _token()
    if HELLO and _TOKEN:
        HELLO = HELLO + " t" + _TOKEN

    """
    static var switchboardMCPConfigJSON: String {
        let cfg: [String: Any] = ["mcpServers": ["switchboard": [
            "command": "python3", "args": [switchboardMCPShimGuestPath],
            // Loaded up front, not behind ToolSearch (a turn saved).
            "alwaysLoad": true]]]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    static let delegationMCPHelloBlock = """
    def _hello():
        # Who am I: the tmux window this agent runs in (its pane is in the
        # environment), so the host binds the connection to the session
        # shown there. An explicit argv[1] wins (tests).
        if len(sys.argv) > 1 and sys.argv[1]:
            return sys.argv[1]
        pane = os.environ.get("TMUX_PANE", "")
        if not pane:
            return ""
        try:
            out = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "w#{window_index}"],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            return ""
        return out if out.startswith("w") and out[1:].isdigit() else ""
    HELLO = _hello()
    """
    static var automationMCPClaudeEntry: [String: Any] {
        ["command": "python3", "args": [automationMCPShimGuestPath]]
    }
    /// The task shim, pointed at the automations port (same reconnecting
    /// stdio↔vsock pump). It announces the git branch of the directory the
    /// agent runs in when that's a worktree branch — a repository-watch
    /// scan's findings are tied to their run through it.
    static var automationMCPShimScript: String {
        taskMCPShimScript
            .replacingOccurrences(of: "PORT = \(taskBoardMCPVsockPort)", with: "PORT = \(automationMCPVsockPort)")
            .replacingOccurrences(of: "bromure-task-mcp", with: "bromure-automations-mcp")
            .replacingOccurrences(of: "task-board MCP", with: "automations MCP")
            .replacingOccurrences(of: "import socket, sys, threading, time",
                                  with: "import socket, subprocess, sys, threading, time")
            .replacingOccurrences(of: "HELLO = sys.argv[1] if len(sys.argv) > 1 else \"\"",
                                  with: automationMCPHelloBlock)
    }
    static let automationMCPHelloBlock = """
    def _hello():
        # Which run am I: the worktree branch of the agent's directory (the
        # shim inherits its cwd). Only wt/ branches mean anything to the host.
        if len(sys.argv) > 1 and sys.argv[1]:
            return sys.argv[1]
        try:
            out = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            return ""
        return out if out.startswith("wt/") else ""
    HELLO = _hello()
    """
    static let taskMCPShimGuestPath = "/mnt/bromure-meta/bromure-task-mcp.py"
    /// `vsock_connect`, as the shims use it: direct, or through agentd's relay
    /// when an OpenShell sandbox refuses AF_VSOCK (bromure-agentd.py §4b).
    static let shimVsockConnect = """
    VSOCK_RELAY = os.environ.get("BROMURE_VSOCK_RELAY") or "/tmp/bromure-vsock.sock"
    def vsock_connect(port):
        # The host's `port` over vsock. Under an OpenShell sandbox the seccomp
        # filter refuses AF_VSOCK (EPERM): then through agentd's relay, which
        # runs outside it (bromure-agentd.py §4b). The bytes are the same.
        try:
            s = socket.socket(getattr(socket, "AF_VSOCK", 40), socket.SOCK_STREAM)
        except OSError as e:
            if e.errno not in (errno.EPERM, errno.EACCES, errno.EAFNOSUPPORT):
                raise
            return vsock_relay_connect(port)
        try:
            s.connect((HOST_CID, port))
        except BaseException:
            s.close()
            raise
        return s
    def vsock_relay_connect(port):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(60)
            s.connect(VSOCK_RELAY)
            s.sendall(("bromure-vsock %d\\n" % port).encode())
            line = b""
            while not line.endswith(b"\\n") and len(line) < 256:
                b = s.recv(1)
                if not b:
                    break
                line += b
            if line != b"ok\\n":
                raise ConnectionRefusedError(errno.ECONNREFUSED, "vsock relay: %s"
                                             % (line.decode("utf-8", "replace").strip() or "closed"))
            s.settimeout(None)
            return s
        except BaseException:
            s.close()
            raise
    """

    /// The built-in `browser` MCP server entry (Claude JSON shape): a stdio
    /// shim the agent launches, which pipes JSON-RPC over vsock to the host.
    static var browserMCPClaudeEntry: [String: Any] {
        ["command": "python3", "args": [browserMCPShimGuestPath]]
    }

    /// Guest stdio ⇄ host-vsock shim. The MCP client (claude/codex/grok)
    /// launches this; it connects to the host over vsock and pipes the
    /// agent's stdin/stdout to the host BrowserMCPServer. Kept tiny and
    /// dependency-free (stdlib only).
    ///
    /// RECONNECTS on any vsock drop instead of exiting: MCP clients
    /// (Claude Code) permanently withdraw a stdio server's tools when
    /// its process dies, so this process must survive host-side hiccups
    /// and browser-VM restarts. The host handler is stateless per
    /// request line (no session to re-handshake); at worst one in-flight
    /// request errors per drop and the agent just retries the tool call.
    /// It also retries the INITIAL connect (the host listener can come
    /// up moments after the agent), and only exits once its own stdin
    /// closes (the MCP client shutting the server down on purpose).
    static let browserMCPShimScript = """
    #!/usr/bin/env python3
    # Bromure AC — browser MCP stdio↔vsock shim. Generated; do not edit.
    # Bridges an MCP client's stdio to the host's BrowserMCPServer over
    # vsock, reconnecting on drops so the MCP server never dies with the
    # transport (see SessionDisk.browserMCPShimScript).
    import socket, sys, threading, time
    HOST_CID = socket.VMADDR_CID_HOST if hasattr(socket, "VMADDR_CID_HOST") else 2
    PORT = \(browserMCPVsockPort)
    import errno, os
    \(shimVsockConnect)
    state_lock = threading.Lock()
    conn_lock = threading.Lock()
    sock = None
    stdin_open = True
    reported = False
    def current():
        with state_lock:
            return sock
    def drop(s):
        global sock
        with state_lock:
            if sock is s:
                sock = None
        try:
            s.close()
        except OSError:
            pass
    def ensure_conn():
        # Serialize dials; whoever loses the race reuses the winner's
        # socket. Backoff 0.2s -> 5s, forever while stdin is open.
        global sock, reported
        with conn_lock:
            existing = current()
            if existing is not None:
                return existing
            delay = 0.2
            while stdin_open:
                try:
                    s = vsock_connect(PORT)
                    with state_lock:
                        sock = s
                    return s
                except OSError as e:
                    if not reported:
                        reported = True
                        sys.stderr.write("bromure-browser-mcp: host not reachable yet (%s) — retrying\\n" % e)
                    time.sleep(delay)
                    delay = min(delay * 2, 5.0)
            return None
    def stdin_to_sock():
        global stdin_open
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                break
            while True:
                s = current() or ensure_conn()
                if s is None:
                    return
                try:
                    s.sendall(line)
                    break
                except OSError:
                    drop(s)
        stdin_open = False
        s = current()
        if s is not None:
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
    threading.Thread(target=stdin_to_sock, daemon=True).start()
    while True:
        s = current() or ensure_conn()
        if s is None:
            break
        try:
            chunk = s.recv(65536)
        except OSError:
            chunk = b""
        if not chunk:
            drop(s)
            if not stdin_open:
                break
            time.sleep(0.2)
            continue
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

    """

    /// The task-board twin of `browserMCPShimScript`: same reconnecting
    /// stdio↔vsock bridge, two differences — the port, and a
    /// "bromure-hello <branch>" line sent after every (re)connect so the
    /// host can bind the connection to its coding task. The branch arrives
    /// as argv[1], baked into the per-run --mcp-config by agentd.
    static let taskMCPShimScript = """
    #!/usr/bin/env python3
    # Bromure AC — task-board MCP stdio↔vsock shim. Generated; do not edit.
    # Sibling of bromure-browser-mcp.py (see SessionDisk.taskMCPShimScript).
    import socket, sys, threading, time
    HOST_CID = socket.VMADDR_CID_HOST if hasattr(socket, "VMADDR_CID_HOST") else 2
    PORT = \(taskBoardMCPVsockPort)
    import errno, os
    \(shimVsockConnect)
    HELLO = sys.argv[1] if len(sys.argv) > 1 else ""
    state_lock = threading.Lock()
    conn_lock = threading.Lock()
    sock = None
    stdin_open = True
    reported = False
    def current():
        with state_lock:
            return sock
    def drop(s):
        global sock
        with state_lock:
            if sock is s:
                sock = None
        try:
            s.close()
        except OSError:
            pass
    def ensure_conn():
        # Serialize dials; whoever loses the race reuses the winner's
        # socket. Backoff 0.2s -> 5s, forever while stdin is open.
        global sock, reported
        with conn_lock:
            existing = current()
            if existing is not None:
                return existing
            delay = 0.2
            while stdin_open:
                try:
                    s = vsock_connect(PORT)
                    if HELLO:
                        s.sendall(("bromure-hello %s\\n" % HELLO).encode())
                    with state_lock:
                        sock = s
                    return s
                except OSError as e:
                    if not reported:
                        reported = True
                        sys.stderr.write("bromure-task-mcp: host not reachable yet (%s) — retrying\\n" % e)
                    time.sleep(delay)
                    delay = min(delay * 2, 5.0)
            return None
    def stdin_to_sock():
        global stdin_open
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                break
            while True:
                s = current() or ensure_conn()
                if s is None:
                    return
                try:
                    s.sendall(line)
                    break
                except OSError:
                    drop(s)
        stdin_open = False
        s = current()
        if s is not None:
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
    threading.Thread(target=stdin_to_sock, daemon=True).start()
    while True:
        s = current() or ensure_conn()
        if s is None:
            break
        try:
            chunk = s.recv(65536)
        except OSError:
            chunk = b""
        if not chunk:
            drop(s)
            if not stdin_open:
                break
            time.sleep(0.2)
            continue
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

    """

    /// The agents' MCP configs (mcp/claude.json, mcp/codex.toml: the built-in
    /// servers and the workspace's own, with stand-in tokens) and the
    /// built-in browser and display servers, staged into the meta share `tmp`.
    static func writeMCPConfigs(into tmp: URL, profile: Profile, tokenPlan: SessionTokenPlan?) throws {
        let fm = FileManager.default
        // MCP servers — write agent-specific config files so Claude Code
        // or Codex discovers them on launch. Claude Code uses JSON
        // (~/.claude.json mcpServers key), Codex uses TOML
        // (~/.codex/config.toml [mcp_servers.*] tables).
        // Always write the MCP configs (and the browser shim): the built-in
        // `browser` server is included even when the user configured none, so
        // every agent can drive the embedded browser.
        let enabledMCP = profile.mcpServers.filter(\.enabled)
        let mcpDir = tmp.appendingPathComponent("mcp", isDirectory: true)
        try fm.createDirectory(at: mcpDir, withIntermediateDirectories: true)

        // Build a lookup of fake tokens by server name so the
        // config files carry fakes, not real secrets.
        var mcpFakes: [String: (envVar: String, fake: String)] = [:]
        if let plan = tokenPlan {
            for entry in plan.mcpBearerFakes {
                mcpFakes[entry.serverName] = (entry.envVarName, entry.fake)
            }
        }

        // Claude Code format (browser + user servers).
        try Self.claudeCodeMCPConfig(servers: enabledMCP, fakes: mcpFakes).writeIfChanged(to: mcpDir.appendingPathComponent("claude.json"))

        // Codex format.
        try Self.codexMCPConfig(servers: enabledMCP, fakes: mcpFakes).writeIfChanged(to: mcpDir.appendingPathComponent("codex.toml"))

        // The browser and display MCP servers.
        try Self.writeBuiltInMCPServers(into: tmp)
    }

    /// Serialize MCP servers into Claude Code's ~/.claude.json format.
    /// `fakes` maps server name → (envVarName, fake token). When present
    /// the fake is set as an env var value so the real token never
    /// reaches the VM; the MITM proxy swaps it on the wire. The built-in
    /// `browser` server is always included.
    static func claudeCodeMCPConfig(
        servers: [MCPServer],
        fakes: [String: (envVar: String, fake: String)] = [:]
    ) -> String {
        var mcpServers: [String: Any] = [
            "browser": browserMCPClaudeEntry,
            "automations": automationMCPClaudeEntry,
            "infrastructure": kubeMCPClaudeEntry,
            "delegation": delegationMCPClaudeEntry,
            "display": displayMCPClaudeEntry,
        ]
        for server in servers {
            // Raw JSON mode: parse and use as-is (allows OAuth blocks,
            // custom fields, or any config shape the form can't express).
            // Skip raw JSON if a fake token is available — the structured
            // path handles token injection; raw JSON can't.
            if !server.rawJSON.isEmpty, fakes[server.name] == nil,
               let data = server.rawJSON.data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                mcpServers[server.name] = raw
                continue
            }
            var entry: [String: Any] = [:]
            var env = server.environment.filter(\.isUsable)
                .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            switch server.transport {
            case .stdio:
                entry["command"] = server.command
                if !server.arguments.isEmpty {
                    entry["args"] = server.arguments
                }
            case .http:
                entry["type"] = "http"
                entry["url"] = server.url
                // OAuth-brokered servers: proxy injects the real
                // Authorization header transparently — no auth fields
                // in the config. Static bearer tokens still use the
                // env var path.
                if server.oauthState == nil {
                    if let swap = fakes[server.name] {
                        if !swap.envVar.isEmpty {
                            entry["bearerTokenEnvVar"] = swap.envVar
                            env[swap.envVar] = swap.fake
                        }
                    } else if !server.bearerTokenEnvVar.isEmpty {
                        entry["bearerTokenEnvVar"] = server.bearerTokenEnvVar
                    }
                }
            }
            if !env.isEmpty {
                entry["env"] = env
            }
            mcpServers[server.name] = entry
        }
        let root: [String: Any] = ["mcpServers": mcpServers]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Serialize MCP servers into Codex's ~/.codex/config.toml format.
    static func codexMCPConfig(
        servers: [MCPServer],
        fakes: [String: (envVar: String, fake: String)] = [:]
    ) -> String {
        var lines: [String] = [
            "# Generated by Bromure AC; do not edit.",
            "",
            "[mcp_servers.browser]",
            "command = \"python3\"",
            "args = [\(tomlQuote(browserMCPShimGuestPath))]",
            "",
            "[mcp_servers.automations]",
            "command = \"python3\"",
            "args = [\(tomlQuote(automationMCPShimGuestPath))]",
            "",
            "[mcp_servers.infrastructure]",
            "command = \"python3\"",
            "args = [\(tomlQuote(kubeMCPShimGuestPath))]",
            "",
            "[mcp_servers.delegation]",
            "command = \"python3\"",
            "args = [\(tomlQuote(delegationMCPShimGuestPath))]",
            // Codex starts MCP servers with a filtered environment: without
            // these the shim can't name its tmux window, the host can't tell
            // which session is calling, and every call is refused ("no
            // Bromure session identity"). TMUX too: `tmux display-message`
            // finds its server through it.
            "env_vars = [\"TMUX\", \"TMUX_PANE\"]",
            // Agent-to-agent traffic never waits on an approval prompt.
            "default_tools_approval_mode = \"approve\"",
            "",
            "[mcp_servers.display]",
            "command = \"python3\"",
            "args = [\(tomlQuote(displayMCPGuestPath))]",
            "default_tools_approval_mode = \"approve\"",
        ]
        for server in servers {
            // Raw JSON servers are written to Claude Code config only;
            // TOML can't represent arbitrary JSON shapes.
            if !server.rawJSON.isEmpty { continue }
            lines.append("")
            lines.append("[mcp_servers.\(tomlKey(server.name))]")
            switch server.transport {
            case .stdio:
                lines.append("command = \(tomlQuote(server.command))")
                if !server.arguments.isEmpty {
                    let args = server.arguments.map { tomlQuote($0) }.joined(separator: ", ")
                    lines.append("args = [\(args)]")
                }
            case .http:
                lines.append("url = \(tomlQuote(server.url))")
                if server.oauthState == nil {
                    if let swap = fakes[server.name], !swap.envVar.isEmpty {
                        lines.append("bearer_token_env_var = \(tomlQuote(swap.envVar))")
                    } else if !server.bearerTokenEnvVar.isEmpty {
                        lines.append("bearer_token_env_var = \(tomlQuote(server.bearerTokenEnvVar))")
                    }
                }
            }
            var env = server.environment.filter(\.isUsable)
                .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            if let swap = fakes[server.name], !swap.envVar.isEmpty {
                env[swap.envVar] = swap.fake
            }
            if !env.isEmpty {
                lines.append("")
                lines.append("[mcp_servers.\(tomlKey(server.name)).env]")
                for (k, v) in env.sorted(by: { $0.key < $1.key }) {
                    lines.append("\(k) = \(tomlQuote(v))")
                }
            }
            if let t = server.startupTimeoutSec {
                lines.append("startup_timeout_sec = \(t)")
            }
            if let t = server.toolTimeoutSec {
                lines.append("tool_timeout_sec = \(t)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func tomlQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func tomlKey(_ s: String) -> String {
        let safe = s.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "server" : safe
    }

    /// The browser and display MCP servers, staged into the meta share
    /// `tmp` when the workspace's MCP is on.
    static func writeBuiltInMCPServers(into tmp: URL) throws {
        let fm = FileManager.default
        // Browser MCP server (runs in this workspace VM). Drives CDP-heavy
        // tools directly over VM↔VM TCP (host out of the CDP path — see the
        // file header) and forwards navigate/tabs/etc. to the host over
        // vsock 5830. Shipped from the AC resource bundle (no image bake);
        // falls back to the reconnecting stdio↔vsock shim if the resource
        // is somehow missing.
        // The display MCP (show the user a picture/video/chart in the
        // chat): a plain stdio server run in the guest, no host bridge —
        // the chat renders its calls straight from the transcript.
        let displayMCPDest = tmp.appendingPathComponent("bromure-display-mcp.py")
        try? fm.removeItem(at: displayMCPDest)
        if let src = acResourceBundle.url(forResource: "vm-setup/bromure-display-mcp",
                                          withExtension: "py") {
            try fm.copyItem(at: src, to: displayMCPDest)
        }
        let browserMCPDest = tmp.appendingPathComponent("bromure-browser-mcp.py")
        try? fm.removeItem(at: browserMCPDest)
        if let src = acResourceBundle.url(forResource: "vm-setup/bromure-browser-mcp",
                                          withExtension: "py") {
            try fm.copyItem(at: src, to: browserMCPDest)
        } else {
            try Self.browserMCPShimScript.writeIfChanged(to: browserMCPDest)
        }
    }

    /// The MCP shims every workspace gets and the plan-stream driver, staged
    /// into the meta share `tmp`.
    static func writeGuestMCPShims(into tmp: URL) throws {
        let fm = FileManager.default
        // Task-board MCP shim — staged unconditionally (coding tasks can run
        // in any workspace); agentd only wires it into a run's --mcp-config
        // for board tasks.
        try Self.taskMCPShimScript.write(
            to: tmp.appendingPathComponent("bromure-task-mcp.py"),
            atomically: true, encoding: .utf8)
        // Automations MCP shim — always on, for every agent (it's declared in
        // the user-scope MCP configs next to the browser server).
        try Self.automationMCPShimScript.write(
            to: tmp.appendingPathComponent("bromure-automations-mcp.py"),
            atomically: true, encoding: .utf8)
        // Infrastructure MCP shim — the clusters and registries this
        // workspace may use, with the documentation to use them.
        try Self.kubeMCPShimScript.write(
            to: tmp.appendingPathComponent("bromure-infra-mcp.py"),
            atomically: true, encoding: .utf8)
        // Delegation MCP shim — every agent tab: hand work to another
        // agent's session, hear back from it.
        try Self.delegationMCPShimScript.write(
            to: tmp.appendingPathComponent("bromure-delegation-mcp.py"),
            atomically: true, encoding: .utf8)
        // Switchboard MCP shim + the config its session's command line names
        // (--mcp-config). No agent config lists it: only the Switchboard is
        // launched with it, and the host refuses every other caller.
        try Self.switchboardMCPShimScript.write(
            to: tmp.appendingPathComponent("bromure-switchboard-mcp.py"),
            atomically: true, encoding: .utf8)
        try Self.switchboardMCPConfigJSON.write(
            to: tmp.appendingPathComponent("bromure-switchboard-mcp.json"),
            atomically: true, encoding: .utf8)

        // Plan-stream driver assets — staged unconditionally, like the task
        // MCP shim. bromure-plan-driver.py adapts codex/grok (and bridges
        // the node claude driver) to the plan-stream v1 NDJSON protocol on
        // vsock 5832; plan-driver-package.json pins the claude-agent-sdk
        // agentd npm-installs into ~/.bromure/plan-driver on first use.
        for name in ["bromure-plan-driver.py", "claude-plan-driver.mjs",
                     "plan-driver-package.json"] {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            if let src = acResourceBundle.url(forResource: "vm-setup/\(base)",
                                              withExtension: ext) {
                let dest = tmp.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: src, to: dest)
            }
        }
        // Feature marker: agentd routes plan runs through the stream driver
        // only when this file exists (the tmux transcript path stays the
        // fallback for old guests/tools). Ships on unconditionally.
        try "".write(to: tmp.appendingPathComponent("plan-stream-enabled"),
                     atomically: true, encoding: .utf8)
    }
}

extension String {
    /// Write a meta-share file only when its content changed. The guest reads
    /// these over virtiofs while they're re-staged on every profile save; an
    /// unconditional atomic replace (temp file + rename) opens a window where
    /// a guest lookup of the name fails with ENOENT (seen as a command
    /// failing to source proxy.env right after a live policy update).
    func writeIfChanged(to url: URL) throws {
        let data = Data(utf8)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
