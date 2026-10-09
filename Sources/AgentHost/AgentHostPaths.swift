import Foundation

/// Everything Bromure Sidecar keeps on disk, under
/// ~/Library/Application Support/BromureSidecar/.
enum AgentHostPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BromureSidecar", isDirectory: true)
    }()
    /// The control API (owner-only); fat clients reach it over SSH.
    static var controlSocket: URL { support.appendingPathComponent("control.sock") }
    static var sessionsFile: URL { support.appendingPathComponent("sessions.json") }
    static var hostIDFile: URL { support.appendingPathComponent("host-id") }
    static var tmuxConf: URL { support.appendingPathComponent("tmux.conf") }
    static var claudeSettings: URL { support.appendingPathComponent("claude-settings.json") }
    static var claudeMCPConfig: URL { support.appendingPathComponent("claude-mcp.json") }
    /// Put first on the PATH of every command a client runs here: a `tmux`
    /// that talks to our server and a `ps` that knows GNU's `etimes`.
    static var binDir: URL { support.appendingPathComponent("bin", isDirectory: true) }
    /// Files dropped on a client's composer land here (the client names
    /// /home/ubuntu/.bromure/drops; `HostExec` maps that home to this one).
    static var dropsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bromure/drops", isDirectory: true)
    }
    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BromureSidecar/bromure-sidecar.log")
    }

    /// The executable itself (where the app bundle is).
    static var executable: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    /// What agents call back into (their hooks, the delegation MCP, the
    /// `find` shim, `bromure-claude`): a link in bin/, repointed at every
    /// launch — an agent outlives the app, and a renamed or moved app must
    /// not leave its hooks calling a path that's gone.
    static var stableExecutable: String { binDir.appendingPathComponent("bromure-sidecar").path }

    /// Point `stableExecutable` at this binary.
    static func linkStableExecutable() {
        let link = stableExecutable
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == executable { return }
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: executable)
        // A `bromure-claude` installed before (the menu's Install command)
        // named the binary itself: point it at the stable link instead.
        let launcher = NSHomeDirectory() + "/.local/bin/bromure-claude"
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher), dest != link {
            try? FileManager.default.removeItem(atPath: launcher)
            try? FileManager.default.createSymbolicLink(atPath: launcher, withDestinationPath: link)
        }
    }

    /// Bromure Native → Bromure Sidecar: its folder (enrollment, keys,
    /// sessions) and preferences move over once. The old folder is left as a
    /// symlink — agents started before the rename name files in it.
    static func migrateFromNative() {
        let fm = FileManager.default
        let old = support.deletingLastPathComponent().appendingPathComponent("BromureNative")
        if !fm.fileExists(atPath: support.path),
           (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
           fm.fileExists(atPath: old.path),
           (try? fm.moveItem(at: old, to: support)) != nil {
            try? fm.createSymbolicLink(at: old, withDestinationURL: support)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromNative"),
              let legacy = UserDefaults(suiteName: "io.bromure.native") else { return }
        for key in ["sshPort", "attach.target", "machineName", "p2p.published",
                    "migratedFromAgentHost", "debugExec"] {
            if defaults.object(forKey: key) == nil, let v = legacy.object(forKey: key) { defaults.set(v, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromNative")
    }

    /// Bromure Agent Host → Bromure Native (pre-release builds): its folder
    /// and preferences move over once. The old folder is left as a symlink —
    /// agents started before the move still name files in it.
    static func migrateFromAgentHost() {
        let fm = FileManager.default
        let old = support.deletingLastPathComponent().appendingPathComponent("BromureAgentHost")
        if !fm.fileExists(atPath: support.path),
           (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
           fm.fileExists(atPath: old.path),
           (try? fm.moveItem(at: old, to: support)) != nil {
            try? fm.createSymbolicLink(at: old, withDestinationURL: support)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromAgentHost"),
              let legacy = UserDefaults(suiteName: "io.bromure.agent-host") else { return }
        for key in ["sshPort", "attach.target", "machineName", "p2p.published"] {
            if defaults.object(forKey: key) == nil, let v = legacy.object(forKey: key) { defaults.set(v, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromAgentHost")
    }

    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

/// Stderr + a log file (a menu-bar app's stderr goes nowhere).
enum AgentHostLog {
    private static let queue = DispatchQueue(label: "agent-host.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let url = AgentHostPaths.logFile
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
        }
    }
}
