import Foundation

/// Spawns an `ssh-agent -D -a <socket>` subprocess that lives as long
/// as bromure-ac. We use this as the home for per-profile bromure
/// keys: regardless of whether the user has a macOS launchd agent
/// configured, we always have a writable, queryable agent of our own.
///
/// The socket lives in NSTemporaryDirectory keyed by our PID so two
/// concurrent bromure-ac launches don't collide. On clean shutdown we
/// SIGTERM the child. On a hard crash macOS doesn't auto-reap our
/// children, so the orphaned ssh-agent stays alive — `init()` runs a
/// best-effort sweep at startup to kill any stale `ssh-agent` whose
/// `-a` argument points into our socket-naming scheme.
public final class PrivateSSHAgent: @unchecked Sendable {
    public let socketPath: String
    private let process: Process

    public init() throws {
        // Belt-and-braces: kill any orphaned ssh-agents from prior
        // bromure-ac runs that crashed before their `terminate()` could
        // fire. Each one holds a socket under NSTemporaryDirectory
        // matching `bromure-ac-agent-<pid>.sock`, and consumes a few
        // hundred KB resident — multiplied across many crashes that
        // adds up. Quiet on failures: the user shouldn't care.
        Self.reapOrphans()

        let path = NSTemporaryDirectory() + "bromure-ac-agent-\(getpid()).sock"
        try? FileManager.default.removeItem(atPath: path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        // -D foregrounds (so we own the lifetime); -a fixes the socket
        // path so we don't have to parse stdout for SSH_AUTH_SOCK.
        p.arguments = ["-D", "-a", path]
        // Discard agent's noise — protocol is on the socket, not stdio.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        // Wait briefly for the socket file to materialize. ssh-agent
        // creates it after binding, usually within a few ms; cap at
        // 2 s so a busted ssh-agent install fails loudly.
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            p.terminate()
            throw NSError(domain: "BromureAC", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ssh-agent failed to bind \(path)"
            ])
        }

        self.socketPath = path
        self.process = p
        FileHandle.standardError.write(Data(
            "[mitm] private ssh-agent up at \(path) (pid \(p.processIdentifier))\n".utf8))
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Find and SIGTERM any orphaned `ssh-agent` processes whose `-a`
    /// argument points at one of our socket files. Drops the matching
    /// `.sock` files from NSTemporaryDirectory afterwards.
    ///
    /// Implementation: shell out to `pgrep -af 'ssh-agent.*bromure-ac-agent'`
    /// to find candidate PIDs, then SIGTERM each. We deliberately do
    /// NOT touch ssh-agents the *current* process spawned (we haven't
    /// spawned ours yet — `init()` calls this first) and we
    /// deliberately scope the pattern to our socket-naming convention
    /// so we never touch the user's launchd ssh-agent.
    private static func reapOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-af", "ssh-agent .*bromure-ac-agent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return }

        var killed = 0
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            // pgrep -af lines look like: "<pid> /usr/bin/ssh-agent -D -a <path>"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            // Don't kill ourselves or our future child (ours doesn't
            // exist yet, but be defensive).
            if pid == getpid() { continue }
            kill(pid, SIGTERM)
            killed += 1
        }

        // Sweep the orphaned socket files. ssh-agent removes its own
        // socket on clean exit, but a crashed parent leaves them too.
        if let entries = try? FileManager.default.contentsOfDirectory(
            atPath: NSTemporaryDirectory()) {
            for entry in entries
                where entry.hasPrefix("bromure-ac-agent-") && entry.hasSuffix(".sock") {
                try? FileManager.default.removeItem(
                    atPath: NSTemporaryDirectory() + entry)
            }
        }

        if killed > 0 {
            FileHandle.standardError.write(Data(
                "[mitm] reaped \(killed) orphaned ssh-agent(s) from prior bromure-ac runs\n".utf8))
        }
    }
}
