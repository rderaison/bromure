import Foundation

/// What the shared agent-session engine asks of its host (macOS: the app
/// delegate), done the daemon's way: a workspace is a VM record, its shell
/// is GuestShell. Shaped after ACAppDelegate's members; the AgentSessionHost
/// conformance wraps these once that protocol lands.
extension Daemon {
    /// A command in a workspace's guest failed to run, or ran and failed.
    enum GuestCommandError: Error, CustomStringConvertible {
        case unavailable(String)
        case failed(exitCode: Int, stderr: String)
        // @port-skip linux-only: guest exec errors
        var description: String {
            switch self {
            case .unavailable(let why): return why
            case .failed(let code, let err): return "exit \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// `command` in the workspace's guest (bash, as the workspace user); its
    /// stdout. A non-zero exit throws with stderr, as on macOS.
    // partial: no attached-machine (Sidecar) branch
    // @port-skip linux-only: ACAppDelegate.guestExec over VZ vsock; this one is GuestShell's
    func guestExec(profileID: UUID, command: String, timeout: Int = 30) async throws -> String {
        guard let l = live.first(where: { $0.key.caseInsensitiveCompare(profileID.uuidString) == .orderedSame })?.value else {
            throw GuestCommandError.unavailable("workspace \(profileID.uuidString.prefix(8)) isn't running")
        }
        let r = try await l.shell.exec(command, timeout: timeout, wait: .seconds(10))
        guard r.exitCode == 0 else { throw GuestCommandError.failed(exitCode: r.exitCode, stderr: r.stderr) }
        return r.stdout
    }

    /// One native file op (`{"file": {...}}`, the file browser's data plane)
    /// in the workspace's guest: agentd's reply as it came. The op failing
    /// in the guest throws with its error, as on macOS.
    // @port-skip linux-only: ACAppDelegate.guestFileOp over VZ vsock; this one is GuestShell's
    func guestFileOp(profileID: UUID, op: [String: Any], timeout: Int = 30) async throws -> [String: Any] {
        guard let l = live.first(where: { $0.key.caseInsensitiveCompare(profileID.uuidString) == .orderedSame })?.value else {
            throw GuestCommandError.unavailable("workspace \(profileID.uuidString.prefix(8)) isn't running")
        }
        let o = try await l.shell.request(["file": op, "timeout": timeout], wait: .seconds(10))
        if let err = o["error"] as? String {
            throw GuestCommandError.failed(exitCode: o["exit_code"] as? Int ?? 1, stderr: err)
        }
        return o
    }

    /// Boots the workspace's VM if it isn't running (macOS: startProfile,
    /// startProfileQuietly, startProfileRemotely, which differ only in where
    /// a boot's questions are asked; a server has no screen to ask on).
    /// Nil when it's up (or was already), else why not.
    // @port ACAppDelegate.startProfileRemotely(_: Profile.ID) h=b41392c8b01a656d @7dd92fdf
    func startWorkspace(_ id: UUID) async -> String? {
        guard let rec = registry.find(id.uuidString.lowercased()) else { return "no workspace \(id.uuidString)" }
        if rec.state == .running || live[rec.id] != nil { return nil }
        let r = await start(rec)
        return r.status < 300 ? nil : (r.body["error"]?.stringValue ?? "couldn't start (\(r.status))")
    }

    /// The Codex and Claude sign-in stand-ins (macOS writes the bogus tokens
    /// its MITM proxy swaps for the real ones). bromure-ac has no MITM proxy
    /// yet: nothing to write, as on macOS without a stored login; the agent
    /// uses its own sign-in inside the VM.
    // partial: no MITM credential swap on Linux yet
    // @port-skip linux-only: no MITM stand-in credentials to push (ACAppDelegate.pushCodexAuth)
    func pushCodexAuth(profileID: UUID) async -> Bool { false }

    // partial: no MITM credential swap on Linux yet
    // @port-skip linux-only: no MITM stand-in credentials to push (ACAppDelegate.pushClaudeStandIn)
    func pushClaudeStandIn(profileID: UUID) async -> Bool { false }
}
