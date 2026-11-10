import Foundation

/// A guest's one-shot error reports in its outbox (macOS: OutboxScanner's
/// worktree-error / docker-error files and the app's onWorktreeError /
/// onDockerError): read, removed, acted on.
extension LinuxSessionHost {
    /// A one-shot report's name: `<stem>.txt` or `<stem>-<anything>.txt`.
    // @port UbuntuSandboxVM.static isOneShot(_: String, stem: String) h=9943ec09a7aecd52 @132bb730
    nonisolated static func isOneShot(_ name: String, stem: String) -> Bool {
        name == stem + ".txt" || (name.hasPrefix(stem + "-") && name.hasSuffix(".txt"))
    }

    /// `worktree-error.txt`: the run it belongs to (`run-slug: <slug>` on
    /// the first line, from an automation run), and the message.
    // @port ACAppDelegate.static splitWorktreeError(_: String) h=8400edee2a279755 @5f46a841
    nonisolated static func splitWorktreeError(_ raw: String) -> (slug: String?, message: String) {
        let prefix = "run-slug: "
        guard raw.hasPrefix(prefix) else { return (nil, raw) }
        let rest = raw.dropFirst(prefix.count)
        let line = rest.prefix { $0 != "\n" }
        let slug = line.trimmingCharacters(in: .whitespaces)
        let message = rest.dropFirst(line.count).drop { $0 == "\n" }
        return (slug.isEmpty ? nil : slug, String(message))
    }

    /// One-shot reports handled per poll (macOS's per tick); the rest wait.
    static let maxOneShotsPerTick = 32

    /// A refused automation or task run (its slug on the report's first
    /// line) fails that run, not left "launched", unless its tab is up;
    /// every report goes to the log, as on macOS. A docker action's error
    /// is said in the log: macOS shows it only in the server's own pane (a
    /// fat client gets it from neither).
    // partial: no sheet (no screen); the log has the failure
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onWorktreeError h=18304aa58f2237ae @d3ebbda2
    // partial: macOS shows it in the server's own pane; here the log has it
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onDockerError h=5c356319b3ddb936 @d3ebbda2
    func readGuestErrors() {
        let fm = FileManager.default
        for id in Self.running.withLockedValue({ $0 }) {
            let outbox = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/"
            let names = ((try? fm.contentsOfDirectory(atPath: outbox)) ?? []).sorted()
            var handled = 0
            for name in names where Self.isOneShot(name, stem: "worktree-error") || Self.isOneShot(name, stem: "docker-error") {
                guard handled < Self.maxOneShotsPerTick else { break }
                handled += 1
                let raw = GuestOutbox.read(outbox + name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(atPath: outbox + name)
                guard !raw.isEmpty else { continue }
                if Self.isOneShot(name, stem: "docker-error") {
                    SupplyChainLog.shared.record("[docker] \(id.uuidString.prefix(8)): \(ScheduledAutomationEngine.guestReported(raw))")
                    continue
                }
                let (slug, message) = Self.splitWorktreeError(raw)
                SupplyChainLog.shared.record("[worktree] \(ScheduledAutomationEngine.guestReported(message))")
                guard let slug else { continue }
                let live = openWorktreeBranches(profileID: id)
                SessionStores.shared?.automationEngine?.runRefused(profileID: id, slug: slug, reason: message, liveBranches: live)
                SessionStores.shared?.codingTaskEngine?.runRefused(profileID: id, slug: slug, reason: message, liveBranches: live)
            }
        }
    }
}

extension Daemon {
    /// The guest daemon into the meta share, only when it changed: the
    /// running agentd re-hashes on an mtime change and exits to upgrade, so
    /// an identical rewrite would restart it on every resume.
    // @port-skip linux-only: the bromure-agentd.py step of SessionDisk.prepareMetadataShare (see its claim on launchVM)
    static func stageAgentd(_ source: String, into meta: String) throws {
        let dest = meta + "/bromure-agentd.py"
        let new = try Data(contentsOf: URL(fileURLWithPath: source))
        guard FileManager.default.contents(atPath: dest) != new else { return }
        try new.write(to: URL(fileURLWithPath: dest), options: .atomic)
        guard chmod(dest, 0o755) == 0 else { throw MachineError.io("chmod \(dest)", errno) }
    }

    /// The operator's opt-in to guest terminal graphics (`terminal.allowGraphics`,
    /// default off): agentd lets tmux pass kitty-graphics escapes through.
    // partial: this user's defaults on the server (the client's own ghostty config decides what it renders)
    // @port TerminalAppDefaults.static terminalGraphicsAllowed() h=b7ea44d683838717 @212f497c
    static func terminalGraphicsAllowed() -> Bool {
        UserDefaults.standard.bool(forKey: "terminal.allowGraphics")
    }

    /// The `terminal-graphics-enabled` marker, written or removed each launch.
    // @port-skip linux-only: the terminal-graphics-enabled step of SessionDisk.prepareMetadataShare
    static func writeTerminalGraphicsMarker(in meta: String, allowed: Bool) throws {
        let marker = meta + "/terminal-graphics-enabled"
        if allowed {
            try "".write(toFile: marker, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: marker)
        }
    }
}
