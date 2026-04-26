import Foundation

/// Spawns an `ssh-agent -D -a <socket>` subprocess that lives as long
/// as bromure-ac. We use this as the home for per-profile bromure
/// keys: regardless of whether the user has a macOS launchd agent
/// configured, we always have a writable, queryable agent of our own.
///
/// The socket lives in NSTemporaryDirectory keyed by our PID so two
/// concurrent bromure-ac launches don't collide. On clean shutdown we
/// SIGTERM the child; on a hard crash the orphaned agent eventually
/// gets cleaned up by macOS tmpcleaner (it's idle and tiny).
public final class PrivateSSHAgent: @unchecked Sendable {
    public let socketPath: String
    private let process: Process

    public init() throws {
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
}
