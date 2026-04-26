import Foundation

/// Tiny synchronous client for the macOS ssh-agent unix socket. Lets
/// us multiplex the user's host-side keys (loaded into their macOS
/// agent / Keychain) into the in-VM agent: the VM's `ssh` calls our
/// agent, our agent merges the per-profile bromure key + every key the
/// host agent advertises, and signs with whichever one matches.
///
/// **Why not byte-forward the whole socket?** Because we want to ALSO
/// expose the per-profile bromure key (which only our process holds).
/// Multiplexing means both key sets work without the user having to
/// `ssh-add` anything on the host.
final class HostAgentClient: @unchecked Sendable {
    let socketPath: String

    /// The user's macOS launchd ssh-agent. Optional — present only if
    /// the user's macOS install actually has one running, which most
    /// do. Used to multiplex the user's personal keys into the VM
    /// alongside the per-profile bromure keys.
    static let macOSUser: HostAgentClient? = {
        if let p = resolveSocketPath() {
            FileHandle.standardError.write(Data(
                "[mitm] macOS user ssh-agent at \(p) will be multiplexed into VMs\n".utf8))
            return HostAgentClient(socketPath: p)
        }
        FileHandle.standardError.write(Data(
            "[mitm] no macOS user ssh-agent — only the bromure private agent will be exposed\n".utf8))
        return nil
    }()

    /// Backwards-compatibility shim for older call sites. Prefers our
    /// own bromure-managed agent (set by MitmEngine after spawn) and
    /// falls back to the macOS user's agent.
    static var shared: HostAgentClient? {
        return _bromurePrivate ?? macOSUser
    }

    /// Set by MitmEngine after it spawns the private ssh-agent. Used
    /// as the destination for ssh-add of per-profile keys.
    static var _bromurePrivate: HostAgentClient?

    fileprivate static func resolveSocketPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !env.isEmpty,
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        // Ask launchd directly. On macOS this is the source of truth
        // for the GUI session's SSH_AUTH_SOCK.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, FileManager.default.fileExists(atPath: s) {
                return s
            }
        } catch {
            // launchctl missing? Skip silently.
        }
        return nil
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Send a single ssh-agent-protocol request frame, return the
    /// response frame (without the 4-byte length prefix). nil on
    /// any I/O failure — caller falls back to its own behaviour.
    func request(_ payload: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sockaddr_un.sun_path is 104 bytes on macOS — stay under that.
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxPath else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            let typed = dest.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { typed[i] = CChar(bitPattern: b) }
            typed[pathBytes.count] = 0
        }
        let connectStatus = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectStatus < 0 { return nil }

        // Frame: 4-byte big-endian length + payload.
        var lenBE = UInt32(payload.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        guard writeAll(fd: fd, data: lenData),
              writeAll(fd: fd, data: payload) else { return nil }

        // Read response length, then body.
        guard let lenBuf = readExact(fd: fd, count: 4) else { return nil }
        let respLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard respLen > 0, respLen <= 256 * 1024 else { return nil }
        return readExact(fd: fd, count: respLen)
    }
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        var sent = 0
        while sent < data.count {
            let n = write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }
}

private func readExact(fd: Int32, count: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress!.advanced(by: got), count - got)
        }
        if n == 0 { return nil }
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        got += n
    }
    return Data(buf)
}
