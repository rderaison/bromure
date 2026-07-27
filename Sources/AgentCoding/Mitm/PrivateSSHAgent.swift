import Foundation

/// Spawns an `ssh-agent -D -a <socket>` subprocess. There is ONE OF
/// THESE PER WORKSPACE, not one per app: an agent is a signing oracle
/// for every key loaded into it, so a shared agent let any workspace
/// sign with any other workspace's key (the agent protocol has no
/// notion of "which caller"). `MitmEngine` owns the registry and hands
/// each profile's vsock bridge only its own agent's socket.
///
/// The socket lives in NSTemporaryDirectory keyed by our PID *and* a
/// per-profile label, so concurrent bromure-ac launches don't collide
/// and workspaces don't share a path. On clean shutdown (session end
/// or app quit) we SIGTERM the child — the keys die with it. On a hard
/// crash macOS doesn't auto-reap our children, so `reapOrphans()` runs
/// once at engine startup to kill stale agents from prior runs.
public final class PrivateSSHAgent: @unchecked Sendable {
    public let socketPath: String
    private let process: Process

    /// - Parameter label: short per-workspace discriminator (8 hex chars
    ///   of the profile UUID). Kept short on purpose: `sockaddr_un.sun_path`
    ///   is 104 bytes on Darwin and NSTemporaryDirectory already eats ~50.
    public init(label: String) throws {
        let path = NSTemporaryDirectory() + "bromure-ac-agent-\(getpid())-\(label).sock"
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
    /// to find candidate PIDs, then SIGTERM each. The pattern is scoped
    /// to our socket-naming convention so we never touch the user's
    /// launchd ssh-agent.
    ///
    /// MUST be called exactly once, at engine startup, BEFORE the first
    /// per-workspace agent is spawned — it can't tell one of our live
    /// agents from a stale one, so calling it later would kill the
    /// agents of already-running workspaces. (It skips sockets carrying
    /// our own pid as a second line of defense.)
    static func reapOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // `-l` (not Linux's `-a`): Darwin's pgrep silently IGNORES -a and
        // prints bare pids, so the "<pid> <command>" parse below matched
        // nothing and this sweep was a no-op on macOS for its whole life —
        // which is why orphaned agents piled up across crashes. `-fl` matches
        // the full command line AND prints it.
        p.arguments = ["-fl", "ssh-agent .*bromure-ac-agent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return }

        var killed = 0
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            // Lines look like: "<pid> /usr/bin/ssh-agent -D -a <path>"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            // Re-check the command itself. `-f` matches the whole command
            // line, so a shell whose arguments merely CONTAIN the pattern
            // (a debugging one-liner, say) would otherwise be a target.
            let command = trimmed[trimmed.index(after: space)...]
            guard command.contains("ssh-agent"),
                  command.contains("bromure-ac-agent") else { continue }
            // Don't kill ourselves or our future children (none exist yet —
            // this runs before the first workspace agent — but be defensive).
            if pid == getpid() { continue }
            kill(pid, SIGTERM)
            killed += 1
        }

        // Sweep the orphaned socket files. ssh-agent removes its own
        // socket on clean exit, but a crashed parent leaves them too.
        if let entries = try? FileManager.default.contentsOfDirectory(
            atPath: NSTemporaryDirectory()) {
            for entry in entries
                where entry.hasPrefix("bromure-ac-agent-") && entry.hasSuffix(".sock")
                    && !entry.hasPrefix("bromure-ac-agent-\(getpid())-") {
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
