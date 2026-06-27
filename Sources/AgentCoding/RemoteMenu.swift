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
        let items = ["Sessions", "Profiles", "Models", "Trace", "Status",
                     "Exit (disconnect)"]
        while true {
            guard let sel = tui.menu(title: "bromure-ac · remote",
                                     items: items,
                                     footer: "↑/↓ move · Enter select · Exit to disconnect") else {
                return                         // Esc/q at top level = disconnect
            }
            switch sel {
            case 0: sessionsMenu()
            case 1: profilesMenu()
            case 2: modelsMenu()
            case 3: traceMenu()
            case 4: showOutput("Status", ["status"])
            default: return                    // Exit
            }
        }
    }

    // MARK: - Sessions

    private func sessionsMenu() {
        while true {
            let vms = fetchVMs()
            var labels = ["＋ New session…"]
            for v in vms { labels.append(vmLabel(v)) }
            if vms.isEmpty { labels.append("(no running sessions)") }

            guard let sel = tui.menu(title: "Sessions", items: labels,
                                     footer: "Enter: open · q: back") else { return }
            if sel == 0 { newSession(); continue }
            let idx = sel - 1
            guard idx >= 0, idx < vms.count else { continue }   // the "(no running)" row
            vmActions(vms[idx])
        }
    }

    private func vmActions(_ vm: [String: Any]) {
        let id = vmID(vm)
        let name = vm["name"] as? String ?? id
        while true {
            guard let sel = tui.menu(title: "Session: \(name)",
                                     items: ["Attach", "Describe", "Kill", "Back"],
                                     footer: "Enter select · q back") else { return }
            switch sel {
            case 0: attach(vmID: id); return         // back to list after detach
            case 1: showOutput("describe \(name)", ["vm", "describe", id])
            case 2:
                if tui.confirm("Kill session \(name)?") {
                    showOutput("kill \(name)", ["vm", "kill", id]); return
                }
            default: return
            }
        }
    }

    private func newSession() {
        let profiles = fetchProfiles()
        guard !profiles.isEmpty else {
            tui.pager(title: "New session",
                      body: "No profiles found. Create one in the bromure-ac app first.")
            return
        }
        let labels = profiles.map { ($0["name"] as? String ?? "?") +
            "  (" + ($0["tool"] as? String ?? "") + ")" }
        guard let pick = tui.menu(title: "New session — pick a profile",
                                  items: labels, footer: "Enter: boot · q: cancel") else { return }
        let name = profiles[pick]["name"] as? String ?? ""
        let out = runSelf(["vm", "run", "--profile", name, "--detach"])
        tui.pager(title: "New session", body: out + "\n\nPick the session from the list to attach.")
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

    // MARK: - Profiles / Models / Trace

    private func profilesMenu() {
        let profiles = fetchProfiles()
        var labels = profiles.map { ($0["name"] as? String ?? "?") }
        labels.append("List (raw)")
        guard let sel = tui.menu(title: "Profiles", items: labels,
                                 footer: "Enter: describe · q: back") else { return }
        if sel == profiles.count {
            showOutput("profiles ls", ["profiles", "ls"]); return
        }
        let name = profiles[sel]["name"] as? String ?? ""
        showOutput("profile \(name)", ["profiles", "describe", name])
    }

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

    private func fetchVMs() -> [[String: Any]] {
        guard client.isAgentRunning(),
              let vms = try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]
        else { return [] }
        return vms.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func fetchProfiles() -> [[String: Any]] {
        guard client.isAgentRunning(),
              let ps = try? client.request("GET", "/profiles").json["profiles"] as? [[String: Any]]
        else { return [] }
        return ps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func vmID(_ vm: [String: Any]) -> String {
        (vm["id"] as? String) ?? (vm["shortId"] as? String) ?? ""
    }

    private func vmLabel(_ vm: [String: Any]) -> String {
        let name = vm["name"] as? String ?? "?"
        let id = vm["shortId"] as? String ?? String(vmID(vm).prefix(12))
        let state = vm["state"] as? String ?? ""
        let attached = (vm["attached"] as? Bool ?? false) ? " ⦿" : ""
        return "\(name)  (\(id))  \(state)\(attached)"
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
