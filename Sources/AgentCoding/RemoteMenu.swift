import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `bromure-ac __remote-menu` — the curses-style minishell that every remote
/// SSH login is forced into (`ForceCommand` in the generated sshd_config).
/// Hidden from `--help`: it's an internal entry point, not a user command.
///
/// It exposes, as menus, the same operations as the `bromure-ac` CLI, and lets
/// you attach to a running session's tmux. It talks to the running app over the
/// owner-only control socket (the same transport the CLI uses).
struct RemoteMenu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__remote-menu",
        abstract: "Interactive remote menu (internal; used as the SSH ForceCommand).",
        shouldDisplay: false)

    func run() throws {
        guard isatty(STDIN_FILENO) != 0 else {
            print("The bromure-ac remote menu needs a terminal. Reconnect with: ssh -t …")
            return
        }
        RemoteMenuApp().run()
    }
}

final class RemoteMenuApp {
    private let tui = TUI()
    private let client = ControlClient()

    func run() {
        // Make sure the app/agent is up so the control socket answers.
        try? client.ensureAgentRunning()
        tui.begin()
        defer { tui.end() }
        topMenu()
    }

    // MARK: - Top level

    private func topMenu() {
        let items = ["Workspaces", "Models", "Trace", "Status", "Exit (disconnect)"]
        while true {
            guard let sel = tui.menu(title: "bromure-ac · remote",
                                     items: items,
                                     footer: "↑/↓ move · Enter select · Exit to disconnect") else {
                return                         // Esc/q at top level = disconnect
            }
            switch sel {
            case 0: workspacesMenu()
            case 1: modelsMenu()
            case 2: traceMenu()
            case 3: showOutput("Status", ["status"])
            default: return                    // Exit
            }
        }
    }

    // MARK: - Workspaces (unified — live + off, mirroring the app's window)

    /// One list of every workspace with its live state; selecting one offers the
    /// state-appropriate actions (start an off one, attach/kill a running one).
    private func workspacesMenu() {
        while true {
            let ws = fetchProfiles()
            var labels = ws.map { workspaceLabel($0) }
            labels.append("List (raw table)")
            let rawIndex = labels.count - 1
            guard let sel = tui.menu(title: "Workspaces", items: labels,
                                     footer: "Enter: open · q: back") else { return }
            if sel == rawIndex { showOutput("workspaces ls", ["workspaces", "ls"]); continue }
            if sel >= 0, sel < ws.count { workspaceActions(ws[sel]) }
        }
    }

    private func workspaceActions(_ ws: [String: Any]) {
        let id = (ws["id"] as? String) ?? (ws["shortId"] as? String) ?? ""
        let name = ws["name"] as? String ?? id
        let state = ws["state"] as? String ?? "off"
        let live = (state == "running" || state == "booting")
        while true {
            let items = live ? ["Attach", "Describe", "Kill", "Back"]
                             : ["Start", "Describe", "Back"]
            guard let sel = tui.menu(title: "Workspace: \(name)  ·  \(state)",
                                     items: items, footer: "Enter select · q back") else { return }
            if live {
                switch sel {
                case 0: attachMenu(vmID: id, name: name)  // pick a tab or container
                case 1: showOutput("describe \(name)", ["workspaces", "describe", id])
                case 2:
                    if tui.confirm("Kill \(name)?") {
                        showOutput("kill \(name)", ["vm", "kill", id]); return
                    }
                default: return
                }
            } else {
                switch sel {
                case 0: startWorkspace(id: id, name: name); return
                case 1: showOutput("describe \(name)", ["workspaces", "describe", id])
                default: return
                }
            }
        }
    }

    /// Boot an off/suspended workspace window-less, then hand the remote terminal
    /// straight to its tmux — no need to bounce back through the list.
    private func startWorkspace(id: String, name: String) {
        let out = runSelf(["vm", "run", id, "--detach"])
        // The VM id equals the workspace id once booted. Confirm it actually came
        // up before attaching — boot can be refused (e.g. a model still
        // downloading), in which case `out` carries the reason.
        let up = fetchProfiles().contains {
            ($0["id"] as? String) == id &&
            (($0["state"] as? String) == "running" || ($0["state"] as? String) == "booting")
        }
        guard up else { tui.pager(title: "Start \(name)", body: out); return }
        // Fresh boot: wait for the guest's `bromure` tmux session before handing
        // the terminal over, otherwise `tmux attach` races the agent's setup.
        waitForTmux(vmID: id)
        attach(vmID: id)
    }

    /// Poll the guest until its `bromure` tmux session exists (or we give up).
    private func waitForTmux(vmID: String) {
        for _ in 0..<100 {   // up to ~20s
            let resp = try? client.request(
                "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
                body: ["command": "tmux has-session -t bromure", "timeout": 5])
            if resp?.status == 200, (resp?.json["exitCode"] as? Int ?? 1) == 0 { return }
            usleep(200_000)
        }
    }

    /// Pick what to attach to in a running workspace: a tmux tab (session) or a
    /// running docker container. Loops so detaching returns here, not the top.
    private func attachMenu(vmID: String, name: String) {
        while true {
            let tabs = (fetchVM(vmID)?["tabs"] as? [[String: Any]]) ?? []
            let containers = runningContainers(vmID: vmID)
            // Nothing to choose from yet → just hand over the current tmux tab.
            if tabs.isEmpty && containers.isEmpty { attach(vmID: vmID); return }

            var labels: [String] = []
            var actions: [() -> Void] = []
            for t in tabs {
                let idx = t["index"] as? Int ?? 0
                let title = t["title"] as? String ?? "shell"
                let active = (t["active"] as? Bool ?? false) ? " *" : ""
                labels.append("Tab \(idx): \(title)\(active)")
                actions.append { self.attach(vmID: vmID, tab: idx) }
            }
            for c in containers {
                labels.append("🐳 \(c.name)  (\(c.image))")
                actions.append { self.attachContainer(vmID: vmID, container: c.name) }
            }
            labels.append("Back")

            guard let sel = tui.menu(title: "Attach · \(name)", items: labels,
                                     footer: "Enter attach · q back") else { return }
            if sel >= 0, sel < actions.count { actions[sel]() } else { return }
        }
    }

    /// docker exec -it into a running container, à la `vm attach … containers:…`.
    private func attachContainer(vmID: String, container: String) {
        // Ask which shell to run rather than hardcoding one — bash often isn't
        // in the image (alpine/distroless), so the default is sh. Escape cancels;
        // a blank entry uses sh. The value is interpolated into the guest
        // `docker exec` line, so restrict it to a safe charset (fall back to sh).
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        guard let raw = tui.prompt("Shell to run in \(container)  (Enter for sh)") else { return }
        let entered = raw.trimmingCharacters(in: .whitespaces)
        let shell = (!entered.isEmpty && entered.allSatisfy(allowed.contains)) ? entered : "sh"

        tui.end()
        defer { tui.begin() }
        let banner = "\u{1B}[2J\u{1B}[H" +
            "\u{1B}[1m  Type `exit` (or Ctrl-d) to leave the container\u{1B}[0m\r\n\r\n" +
            "  Attaching to \(container) (\(shell))…\r\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        Thread.sleep(forTimeInterval: 1.0)
        do {
            try InteractiveExec.run(client: client, vm: vmID,
                                    command: "docker exec -it \(container) \(shell)")
        } catch {
            let msg = "\r\nCouldn't attach: \(error.localizedDescription)\r\nPress Enter…"
            FileHandle.standardOutput.write(Data(msg.utf8))
            _ = readLine()
        }
    }

    /// Hand the terminal over to the guest's tmux. Prints the required banner,
    /// then `InteractiveExec` takes over STDIN/STDOUT (its own raw mode) until
    /// the user detaches with Ctrl-b d, at which point we redraw the menu.
    private func attach(vmID: String, tab: Int? = nil) {
        tui.end()                       // leave alt-screen/raw before handing off
        defer { tui.begin() }
        // Banner — shown during the attach handshake, before tmux repaints.
        let banner = "\u{1B}[2J\u{1B}[H" +
            "\u{1B}[1m  Hit Ctrl-b d to disconnect from the session\u{1B}[0m\r\n\r\n" +
            "  Attaching…\r\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        Thread.sleep(forTimeInterval: 1.5)
        var cmd = "tmux attach -t bromure"
        if let tab { cmd += " \\; select-window -t bromure:\(tab)" }
        do {
            try InteractiveExec.run(client: client, vm: vmID, command: cmd)
        } catch {
            let msg = "\r\nCouldn't attach: \(error.localizedDescription)\r\nPress Enter…"
            FileHandle.standardOutput.write(Data(msg.utf8))
            _ = readLine()
        }
    }

    // MARK: - Models / Trace

    private func modelsMenu() {
        guard let sel = tui.menu(title: "Models",
                                 items: ["Installed (ls)", "Catalog", "Back"],
                                 footer: "Enter select · q back") else { return }
        switch sel {
        case 0: showOutput("model ls", ["model", "ls"])
        case 1: showOutput("model catalog", ["model", "catalog"])
        default: return
        }
    }

    private func traceMenu() {
        guard let sel = tui.menu(title: "Trace",
                                 items: ["Summary", "Hostnames", "Leaks", "Recent (ls)", "Back"],
                                 footer: "Enter select · q back") else { return }
        switch sel {
        case 0: showOutput("trace summary", ["trace", "summary"])
        case 1: showOutput("trace hostnames", ["trace", "hostnames"])
        case 2: showOutput("trace leaks", ["trace", "leaks"])
        case 3: showOutput("trace ls", ["trace", "ls"])
        default: return
        }
    }

    // MARK: - Data helpers

    private func fetchProfiles() -> [[String: Any]] {
        guard client.isAgentRunning(),
              let ps = try? client.request("GET", "/profiles").json["profiles"] as? [[String: Any]]
        else { return [] }
        return ps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// The running-VM record (carries `tabs`) for a workspace id.
    private func fetchVM(_ id: String) -> [String: Any]? {
        guard let vms = try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]
        else { return nil }
        return vms.first { ($0["id"] as? String) == id }
    }

    /// Running docker containers in a VM, via `docker ps` over the exec bridge.
    private func runningContainers(vmID: String) -> [(name: String, image: String, status: String)] {
        guard let r = try? client.request(
            "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
            body: ["command": "docker ps --format '{{.Names}}\\t{{.Image}}\\t{{.Status}}' 2>/dev/null",
                   "timeout": 5]),
            r.status == 200, let out = r.json["stdout"] as? String else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 2 else { return nil }
            return (name: String(c[0]), image: String(c[1]),
                    status: c.count >= 3 ? String(c[2]) : "")
        }
    }

    /// A list row: name, tool, and a glyph for the live state — the same
    /// off/suspended/booting/running vocabulary as the app's unified window.
    private func workspaceLabel(_ ws: [String: Any]) -> String {
        let name = ws["name"] as? String ?? "?"
        let tool = ws["tool"] as? String ?? ""
        let mark: String
        switch ws["state"] as? String ?? "off" {
        case "running":   mark = "● running"
        case "booting":   mark = "◌ booting"
        case "suspended": mark = "⏸ suspended"
        default:          mark = "○ off"
        }
        return "\(pad(name, 22)) \(pad(tool, 7))  \(mark)"
    }

    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    /// Run a non-interactive `bromure-ac` subcommand and show its output in the
    /// pager — guaranteeing the menu mirrors the CLI exactly.
    private func showOutput(_ title: String, _ args: [String]) {
        tui.pager(title: title, body: runSelf(args))
    }

    private func runSelf(_ args: [String]) -> String {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "Error: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
