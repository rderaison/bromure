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
    }
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
                    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                    s.connect((HOST_CID, PORT))
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
                    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                    s.connect((HOST_CID, PORT))
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
