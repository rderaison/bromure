import Foundation

/// Tiny synchronous client for an ssh-agent unix socket. Used by
/// `SSHAgentServer` to forward SIGN_REQUESTs and REQUEST_IDENTITIES
/// from the VM into bromure's private ssh-agent — the only host-side
/// agent the VM ever sees.
///
/// The user's launchd `SSH_AUTH_SOCK` is intentionally NOT plumbed
/// through here. Earlier revisions multiplexed it in alongside the
/// private agent; that exposed every key in the user's daily-driver
/// agent (GitHub, work, prod) to the disposable VM with no consent
/// gate. Keys the user wants reachable from the VM now go through
/// the explicit-import flow in the profile UI, which lands the key
/// in that workspace's agent and registers an `ImportedApproval` for
/// per-key consent.
///
/// The one exception is a key the user picked out of a host agent
/// (`ImportedSSHKey.hostAgentSocket` — a YubiKey can't be imported as a
/// file). `SSHAgentServer` opens a client on that socket too, but only
/// ever advertises and signs with the picked keys' blobs.
final class HostAgentClient: @unchecked Sendable {
    let socketPath: String
    /// Deadline for one RPC, from `connect` through the last byte. nil =
    /// block. A host-agent sign can wait on a touch or a pinentry; the
    /// same budget caps a connect that never finishes and a peer that
    /// dribbles one byte at a time.
    let timeout: TimeInterval?

    /// One client PER WORKSPACE, registered by MitmEngine when it spawns
    /// that workspace's ssh-agent. There is deliberately no process-wide
    /// "the agent" any more: a single shared agent signs for any key it
    /// holds regardless of caller, so one workspace could sign with
    /// another's key. Callers must look up by profileID, and a profile
    /// with no agent gets nil (never a fallback to someone else's).
    private static let registryLock = NSLock()
    private static var byProfile: [UUID: HostAgentClient] = [:]

    static func register(socketPath: String, for profileID: UUID) {
        registryLock.lock(); defer { registryLock.unlock() }
        byProfile[profileID] = HostAgentClient(socketPath: socketPath)
    }

    static func client(for profileID: UUID) -> HostAgentClient? {
        registryLock.lock(); defer { registryLock.unlock() }
        return byProfile[profileID]
    }

    static func unregister(profileID: UUID) {
        registryLock.lock(); defer { registryLock.unlock() }
        byProfile.removeValue(forKey: profileID)
    }

    init(socketPath: String, timeout: TimeInterval? = nil) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// The socket an `ImportedSSHKey.hostAgentSocket` names: "" means this
    /// process's `SSH_AUTH_SOCK`, a leading "~" is the home folder. nil
    /// when "" and there's no `SSH_AUTH_SOCK`.
    static func resolveHostSocket(_ setting: String) -> String? {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let env = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
            return env.isEmpty ? nil : env
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// Agent sockets worth offering in the "Add from host agent" sheet, as
    /// `hostAgentSocket` values: "" (bromure's `SSH_AUTH_SOCK` — usually
    /// launchd's Apple agent, since an app started from the Finder doesn't
    /// see a shell's export) then the well-known third-party agents that
    /// exist on this Mac.
    static func candidateHostSockets() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out = [""]
        var known = [
            "~/.gnupg/S.gpg-agent.ssh",
            "~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh",
            "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
            "~/.ssh/agent.sock",
        ]
        // gpg-agent's socket moves when GNUPGHOME or a run dir is in play;
        // gpgconf knows where this one actually is.
        if let gpg = gpgconfSSHSocket() {
            let tilde = gpg.hasPrefix(home + "/") ? "~" + gpg.dropFirst(home.count) : gpg
            if !known.contains(tilde) { known.insert(tilde, at: 0) }
        }
        for path in known {
            var st = stat()
            let full = (path as NSString).expandingTildeInPath
            if stat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { out.append(path) }
        }
        return out
    }

    /// Same scan as `candidateHostSockets`, off the main thread. `gpgconf`
    /// can stall on a lock; the editor must not wait for it.
    static func candidateHostSocketsDetached() async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: candidateHostSockets())
            }
        }
    }

    /// `gpgconf` with no deadline beachballs whoever called it. Two seconds,
    /// then SIGTERM and SIGKILL.
    private static let gpgconfTimeout: TimeInterval = 2

    private static func gpgconfSSHSocket() -> String? {
        for bin in ["/opt/homebrew/bin/gpgconf", "/usr/local/bin/gpgconf",
                    "/usr/local/MacGPG2/bin/gpgconf"]
            where FileManager.default.isExecutableFile(atPath: bin) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--list-dirs", "agent-ssh-socket"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            guard (try? p.run()) != nil else { continue }
            if done.wait(timeout: .now() + gpgconfTimeout) == .timedOut {
                p.terminate()
                if done.wait(timeout: .now() + 0.5) == .timedOut, p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                    done.wait()
                }
            }
            guard !p.isRunning, p.terminationStatus == 0 else { continue }
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// REQUEST_IDENTITIES: the agent's keys as (wire blob, comment). Empty
    /// on I/O failure or protocol mismatch.
    func identities() -> [(blob: Data, comment: String)] {
        parsedIdentities(request(Data([11])))
    }

    /// `identities()` off the Swift concurrency pool. Listing runs on every
    /// guest `ssh`, and a silent socket would otherwise pin a cooperative
    /// thread for the whole `timeout`.
    func identitiesDetached() async -> [(blob: Data, comment: String)] {
        parsedIdentities(await requestDetached(Data([11])))
    }

    private func parsedIdentities(_ resp: Data?) -> [(blob: Data, comment: String)] {
        guard let resp, !resp.isEmpty, resp[0] == 12 else { return [] }
        var cursor = 1
        func u32() -> Int? {
            guard cursor + 4 <= resp.count else { return nil }
            let v = resp.subdata(in: cursor..<(cursor + 4)).reduce(0) { $0 << 8 | Int($1) }
            cursor += 4
            return v
        }
        func str() -> Data? {
            guard let n = u32(), cursor + n <= resp.count else { return nil }
            defer { cursor += n }
            return resp.subdata(in: cursor..<(cursor + n))
        }
        guard let count = u32() else { return [] }
        var result: [(Data, String)] = []
        for _ in 0..<count {
            guard let blob = str(), let comment = str() else { break }
            result.append((blob, String(data: comment, encoding: .utf8) ?? ""))
        }
        return result
    }

    /// `request` off the Swift concurrency pool. A host agent can block
    /// for the whole `timeout` (a touch, or a socket that never answers).
    func requestDetached(_ payload: Data) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.request(payload))
            }
        }
    }

    /// Send a single ssh-agent-protocol request frame, return the
    /// response frame (without the 4-byte length prefix). nil on
    /// any I/O failure — caller falls back to its own behaviour.
    ///
    /// With a `timeout`, the socket is non-blocking and one deadline
    /// covers connect, both writes, and the body read.
    func request(_ payload: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        if deadline != nil {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        }

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
        if connectStatus < 0 {
            let waiting = errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK
            guard waiting, let deadline,
                  waitSocket(fd: fd, events: POLLOUT, deadline: deadline) else { return nil }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) != 0 || soErr != 0 { return nil }
        }

        // Frame: 4-byte big-endian length + payload.
        var lenBE = UInt32(payload.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        guard writeAll(fd: fd, data: lenData, deadline: deadline),
              writeAll(fd: fd, data: payload, deadline: deadline) else { return nil }

        // Read response length, then body.
        guard let lenBuf = readExact(fd: fd, count: 4, deadline: deadline) else { return nil }
        let respLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard respLen > 0, respLen <= 256 * 1024 else { return nil }
        return readExact(fd: fd, count: respLen, deadline: deadline)
    }
}

/// Poll until `events` or `deadline`. The remaining time shrinks, so a
/// peer that writes one byte at a time cannot extend the call.
private func waitSocket(fd: Int32, events: Int32, deadline: Date) -> Bool {
    while true {
        let remain = deadline.timeIntervalSinceNow
        if remain <= 0 { return false }
        var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
        let ms = Int32(min(remain * 1000, Double(Int32.max)))
        let n = poll(&pfd, 1, max(ms, 0))
        // A hangup can still leave bytes in the buffer; the read or write
        // that follows reports the real error.
        if n > 0 { return true }
        if n == 0 { return false }
        if errno == EINTR { continue }
        return false
    }
}

private func writeAll(fd: Int32, data: Data, deadline: Date?) -> Bool {
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        var sent = 0
        while sent < data.count {
            if let deadline, !waitSocket(fd: fd, events: POLLOUT, deadline: deadline) { return false }
            let n = write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                if deadline != nil, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return false
            }
            if n == 0 { return false }
            sent += n
        }
        return true
    }
}

private func readExact(fd: Int32, count: Int, deadline: Date?) -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        if let deadline, !waitSocket(fd: fd, events: POLLIN, deadline: deadline) { return nil }
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress!.advanced(by: got), count - got)
        }
        if n == 0 { return nil }
        if n < 0 {
            if errno == EINTR { continue }
            if deadline != nil, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            return nil
        }
        got += n
    }
    return Data(buf)
}
