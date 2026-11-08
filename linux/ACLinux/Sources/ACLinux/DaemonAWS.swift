import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// One VM's host end of a guest service on hybrid vsock: Firecracker
/// delivers the guest's connections to `port` on `<v.sock>_<port>`; each
/// accepted descriptor is handed to `serve`, which owns and closes it (the
/// AWS credential_process helper's 8445, the SSH agent's 8444 -- macOS:
/// AWSCredsListenerDelegate, SSHListenerDelegate).
// @port-skip linux-only: the VZVirtioSocketListener delegates over hybrid vsock
final class VsockFDListener: @unchecked Sendable {
    let path: String
    let fdStoreName: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    /// Connections being served, and the most at once: one past it is
    /// closed as it's accepted.
    private var active = 0
    let maxConnections: Int
    /// The most a connection may sit without sending, or without reading
    /// what it's sent (SO_RCVTIMEO, SO_SNDTIMEO): it ends rather than
    /// holding its thread for good.
    static let idleTimeout = 60
    /// The most one connection lasts, however it trickles (a sign that
    /// waits on the user's consent takes 120 s at most).
    let connectionDeadline: TimeInterval

    // @port-skip linux-only: the VZVirtioSocketListener delegates over hybrid vsock
    init(udsPath: String, port: UInt32, fdStoreName: String, stored: Int32?,
         maxConnections: Int = 16, connectionDeadline: TimeInterval = 600,
         accept: @escaping @Sendable (Int32) -> Int32 = { acl_accept_cloexec($0) },
         serve: @escaping @Sendable (Int32) async -> Void) throws {
        self.maxConnections = maxConnections
        self.connectionDeadline = connectionDeadline
        path = HybridVsockListener.path(uds: udsPath, port: port)
        self.fdStoreName = fdStoreName
        if let stored { fd = stored } else {
            fd = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [fd])
        }
        let t = Thread { [self] in acceptLoop(accept, serve) }
        t.name = "vsock-" + fdStoreName
        t.start()
    }

    /// Accepts until stop() has shut the socket down, and only then closes
    /// it, so neither an accept nor stop's shutdown runs on a reused
    /// descriptor number. A resource error (no descriptor, buffer or memory
    /// to spare) is waited out rather than ending the loop, which would
    /// leave the guest's helpers queued on a socket no one accepts on.
    // @port-skip linux-only: the per-VM vsock listeners
    private func acceptLoop(_ accept: (Int32) -> Int32, _ serve: @escaping @Sendable (Int32) async -> Void) {
        var backoff: UInt32 = 10_000
        while true {
            // CLOEXEC from the start: a Firecracker or virtiofsd spawned
            // meanwhile mustn't inherit the guest's connection.
            let c = accept(fd)  // the descriptor, or -errno
            if c >= 0 {
                backoff = 10_000
                admit(c, serve)
                continue
            }
            let err = -c
            if isStopped {
                close(fd)
                return
            }
            if err == EINTR || err == ECONNABORTED { continue }
            if err != EMFILE && err != ENFILE && err != ENOBUFS && err != ENOMEM && backoff == 10_000 {
                FileHandle.standardError.write(Data("bromure-ac daemon: \(fdStoreName): accept: errno \(err); retrying\n".utf8))
            }
            usleep(backoff)
            backoff = min(backoff * 2, 1_000_000)
        }
    }

    /// Serves `c` on a thread of its own: the shared servers read their
    /// connection with a blocking read(), which on Swift's cooperative pool
    /// would let a guest's idle connections take every thread of it (the
    /// daemon actor, the control API and every other VM with them).
    // @port-skip linux-only: the per-VM vsock listeners
    private func admit(_ c: Int32, _ serve: @escaping @Sendable (Int32) async -> Void) {
        lock.lock()
        let ok = active < maxConnections
        if ok { active += 1 }
        lock.unlock()
        // The server gets its own descriptor of the connection and closes
        // it; ours stays open until the server is done, so the deadline's
        // shutdown never lands on a reused number.
        guard ok else { close(c); return }
        let theirs = fcntl(c, F_DUPFD_CLOEXEC, 0)
        guard theirs >= 0 else {
            lock.lock(); active -= 1; lock.unlock()
            close(c); return
        }
        var tv = timeval(tv_sec: Self.idleTimeout, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // The deadline: one timer per connection, cancelled as the server
        // finishes (a guest looping connect/close must not leave one behind
        // each time).
        let done = NIOLockedValueBox(false), disarmed = NIOLockedValueBox(false)
        let deadline = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        // Once, whichever comes first: the deadline or the server's end.
        let disarmOnce: @Sendable () -> Void = { [weak self] in
            guard disarmed.withLockedValue({ let was = $0; $0 = true; return !was }) else { return }
            deadline.cancel()
            self?.disarm()
        }
        deadline.schedule(deadline: .now() + connectionDeadline)
        deadline.setEventHandler {
            done.withLockedValue { if !$0 { shutdown(c, Int32(SHUT_RDWR)) } }
            disarmOnce()
        }
        lock.lock(); armed += 1; lock.unlock()
        deadline.resume()
        let thread = ConnectionThread(name: "vsock-" + fdStoreName)
        Task(executorPreference: thread) { [self] in
            await serve(theirs)
            done.withLockedValue { $0 = true; close(c) }
            disarmOnce()
            lock.lock(); active -= 1; lock.unlock()
            thread.finish()
        }
    }

    /// Deadline timers armed and not yet fired or cancelled (tests).
    private var armed = 0
    // @port-skip linux-only: the per-VM vsock listeners
    private func disarm() { lock.lock(); armed -= 1; lock.unlock() }
    // @port-skip linux-only: the per-VM vsock listeners
    var armedDeadlines: Int { lock.lock(); defer { lock.unlock() }; return armed }

    /// Connections being served (tests).
    // @port-skip linux-only: the per-VM vsock listeners
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return active }

    // @port-skip linux-only: the per-VM vsock listeners
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// The AWS credential_process helper's end (vsock 8445): the server
    /// writes the workspace's key id and a fake secret, and closes.
    // @port AWSCredsListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=e8fd6c0c1f44aa28 @8e2543eb
    static func awsCreds(udsPath: String, fdStoreName: String, stored: Int32?, profileID: UUID,
                         server: AWSCredentialServer) throws -> VsockFDListener {
        try VsockFDListener(udsPath: udsPath, port: 8445, fdStoreName: fdStoreName, stored: stored) {
            if AWSSSORefusals.contains(profileID) {
                AWSSSORefusals.refuse(fd: $0, profileID: profileID)
                return
            }
            await server.serve(fd: $0, profileID: profileID)
        }
    }

    /// The SSH agent's end (vsock 8444, agentd's /tmp/bromure-agent.sock in
    /// the guest): the host's agent signs with the workspace's keys, which
    /// never enter the VM.
    // @port SSHListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=60c56848b362daa3 @8e2543eb
    static func sshAgent(udsPath: String, fdStoreName: String, stored: Int32?, profileID: UUID,
                         agent: SSHAgentServer) throws -> VsockFDListener {
        try VsockFDListener(udsPath: udsPath, port: 8444, fdStoreName: fdStoreName, stored: stored) {
            await agent.serve(fd: $0, profileID: profileID)
        }
    }

    /// The VM is gone: the listener shut down (its thread closes it) and its
    /// socket file removed.
    // @port-skip linux-only: the per-VM vsock listeners
    func stop() {
        // Under the lock: the accept thread closes the socket only once it
        // sees `stopped`, which is after this shutdown.
        lock.lock()
        let first = !stopped
        stopped = true
        if first { shutdown(fd, Int32(SHUT_RDWR)) }
        lock.unlock()
        if first { try? FileManager.default.removeItem(atPath: path) }
    }
}

extension Daemon {
    /// A workspace VM's AWS credentials listener (none for a cluster or
    /// sign-in machine, or without the proxy).
    // @port-skip linux-only: the per-VM AWS credentials listener (macOS: MitmEngine.register's 8445 listener)
    func serveAWSCreds(_ rec: VMRecord, udsPath: String, stored: Int32?) -> VsockFDListener? {
        guard let mitm, !rec.managed, let pid = UUID(uuidString: rec.id) else { if let stored { close(stored) }; return nil }
        do {
            return try VsockFDListener.awsCreds(udsPath: udsPath, fdStoreName: "aws-" + rec.shortId, stored: stored,
                                                profileID: pid, server: mitm.awsCreds)
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no AWS credentials listener: \(error)\n".utf8))
            return nil
        }
    }

    /// The workspace's AWS credentials, handed to the host-side credential
    /// server (static keys as they are; an SSO profile resolved from the AWS
    /// CLI's SSO cache, with a refresh loop that keeps them current), and
    /// the helper ~/.aws/config names staged in its meta share. A server
    /// opens no browser: an SSO session that isn't there (or ends) is the
    /// user's `aws sso login` on this server to run, and the guest's helper
    /// says so until it's resolved.
    // @port ACAppDelegate.pushAWSCredentials(for: Profile, engine: MitmEngine) h=08b3dd4f6296a0b4 @d2db8346
    func pushAWSCredentials(for profile: Profile, meta: String) {
        guard let mitm else { return }
        Self.stageAWSCredsHelper(meta: meta)
        let pid = profile.id
        ssoRefreshTasks.removeValue(forKey: pid)?.cancel()
        guard profile.awsCredentials.authMode == .ssoProfile else {
            // Static keys (Bedrock on them too, or no AWS credentials at all):
            // nothing to resolve.
            AWSSSORefusals.set(false, for: pid)
            mitm.awsCreds.setCredentials(profile.awsCredentials, for: pid)
            return
        }
        let name = profile.awsCredentials.ssoProfileName
        let awsCreds = profile.awsCredentials
        let login = "run `aws sso login --profile \(name)` on this server (as the user the daemon runs as)"
        AWSSSORefusals.set(true, for: pid, reason: "SSO profile '\(name)': credentials not resolved yet")
        FileHandle.standardError.write(Data("[sso] resolving credentials for SSO profile '\(name)'\n".utf8))
        ssoRefreshTasks[pid] = Task.detached {
            do {
                let resolved = try await AWSSSOResolver.resolve(
                    profileName: name, triggerLoginIfNeeded: false,
                    progress: { FileHandle.standardError.write(Data("[sso] \($0)\n".utf8)) })
                guard !Task.isCancelled else { return }
                var creds = awsCreds
                creds.accessKeyID = resolved.accessKeyID
                creds.secretAccessKey = resolved.secretAccessKey
                creds.sessionToken = resolved.sessionToken
                if creds.region.isEmpty { creds.region = resolved.region }
                mitm.awsCreds.setCredentials(creds, for: pid)
                AWSSSORefusals.set(false, for: pid)
                FileHandle.standardError.write(Data("[sso] resolved credentials for '\(name)'\n".utf8))
                let loop = AWSSSOResolver.startRefreshLoop(
                    profileName: name, initialExpiration: resolved.expiration,
                    onRefresh: { fresh in
                        var updated = creds
                        updated.accessKeyID = fresh.accessKeyID
                        updated.secretAccessKey = fresh.secretAccessKey
                        updated.sessionToken = fresh.sessionToken
                        mitm.awsCreds.setCredentials(updated, for: pid)
                        FileHandle.standardError.write(Data("[sso] refreshed credentials for '\(name)'\n".utf8))
                    },
                    onError: { error in
                        FileHandle.standardError.write(Data("[sso] refresh failed: \(error.localizedDescription)\n".utf8))
                        AWSSSORefusals.set(true, for: pid, reason: "SSO session for '\(name)' ended: \(login)")
                    })
                // The loop lives as long as this task: cancelling it (the
                // next push, the session's end) stops the loop.
                await withTaskCancellationHandler { await loop.value } onCancel: { loop.cancel() }
            } catch {
                FileHandle.standardError.write(Data("[sso] credential resolution failed: \(error.localizedDescription)\n".utf8))
                mitm.awsCreds.setCredentials(awsCreds, for: pid)
                AWSSSORefusals.set(true, for: pid, reason: "\(error.localizedDescription): \(login)")
            }
        }
    }

    /// Debug builds, VM e2e only: the SSO portal asked for role credentials
    /// is a test server (`BROMURE_AC_TEST_SSO_PORTAL=http://ip:port`): the
    /// host asks it directly, not through the proxy, so the proxy's test
    /// route doesn't cover it. A release build has none.
    // @port-skip linux-only: e2e hook of the Linux SSO resolution
    static func applyTestSSOPortal() {
        #if DEBUG
        guard let v = ProcessInfo.processInfo.environment["BROMURE_AC_TEST_SSO_PORTAL"], let url = URL(string: v) else { return }
        AWSSSOResolver.portalOverride = url
        FileHandle.standardError.write(Data("bromure-ac daemon: DEBUG: the SSO portal is \(v)\n".utf8))
        #endif
    }

    /// A workspace VM's SSH agent listener (none for a cluster or sign-in
    /// machine, or without the proxy).
    // @port-skip linux-only: the per-VM SSH agent listener (macOS: MitmEngine.register's 8444 listener)
    func serveSSHAgent(_ rec: VMRecord, udsPath: String, stored: Int32?) -> VsockFDListener? {
        guard let mitm, !rec.managed, let pid = UUID(uuidString: rec.id) else { if let stored { close(stored) }; return nil }
        do {
            return try VsockFDListener.sshAgent(udsPath: udsPath, fdStoreName: "ssh-" + rec.shortId, stored: stored,
                                                profileID: pid, agent: mitm.sshAgent)
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no SSH agent listener: \(error)\n".utf8))
            return nil
        }
    }

    /// The workspace's own SSH key (agent/id_ed25519.raw: seed + public),
    /// for the host's agent; none when it has no key or it's malformed.
    // partial: no imported keys (the per-workspace ssh-agent process) or host-agent keys
    // @port ACAppDelegate.loadAgentKeys(for: Profile) h=a3b0ee4331e58485 @d2db8346
    static func loadAgentKeys(for profile: Profile, store: ProfileStore) -> [AgentKey] {
        let raw = store.profileDirectory(for: profile).appendingPathComponent("agent/id_ed25519.raw")
        guard let data = FileManager.default.contents(atPath: raw.path) else { return [] }
        guard data.count == 64 else {
            FileHandle.standardError.write(Data("[mitm] profile '\(profile.name)' agent/id_ed25519.raw is malformed (\(data.count) bytes, expected 64) — regenerate\n".utf8))
            return []
        }
        return [AgentKey(comment: "bromure-ac", publicKey: Data(data.suffix(32)), seed: Data(data.prefix(32)),
                         requireApproval: profile.sshKeyRequiresApproval,
                         consentCredentialID: ConsentCredentialID.bromureSSHKey())]
    }

    /// bromure-aws-creds.py in the meta share, 0755 (macOS: SessionDisk's
    /// awsCredsHelperURL copy).
    // @port-skip linux-only: SessionDisk's meta-share copy of the AWS helper
    static func stageAWSCredsHelper(meta: String) {
        guard let src = acResourceBundle.url(forResource: "vm-setup/bromure-aws-creds", withExtension: "py") else {
            FileHandle.standardError.write(Data("bromure-ac daemon: bromure-aws-creds.py missing from the resources\n".utf8))
            return
        }
        // Copied beside it and renamed over it: a running VM's helper (a
        // taken-back one's) is never missing, even for a moment.
        let dest = meta + "/bromure-aws-creds.py", staging = meta + "/.bromure-aws-creds.py.new"
        try? FileManager.default.removeItem(atPath: staging)
        do {
            try FileManager.default.copyItem(atPath: src.path, toPath: staging)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: staging)
            guard rename(staging, dest) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            FileHandle.standardError.write(Data("bromure-ac daemon: couldn't stage the AWS helper: \(error)\n".utf8))
        }
    }
}

/// A task executor on one thread of its own, for one connection: what the
/// task runs between its awaits (blocking reads included) runs here, off
/// the cooperative pool. The thread ends once finish() is called and its
/// jobs are done.
// @port-skip linux-only: the per-VM vsock listeners
final class ConnectionThread: TaskExecutor, @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [UnownedJob] = []
    private var finished = false

    // @port-skip linux-only: the per-VM vsock listeners
    init(name: String) {
        let t = Thread { [self] in run() }
        t.name = name
        t.start()
    }

    // @port-skip linux-only: the per-VM vsock listeners
    func enqueue(_ job: consuming ExecutorJob) {
        let j = UnownedJob(job)
        cond.lock(); jobs.append(j); cond.signal(); cond.unlock()
    }

    // @port-skip linux-only: the per-VM vsock listeners
    func finish() { cond.lock(); finished = true; cond.signal(); cond.unlock() }

    // @port-skip linux-only: the per-VM vsock listeners
    private func run() {
        while true {
            cond.lock()
            while jobs.isEmpty && !finished { cond.wait() }
            if jobs.isEmpty { cond.unlock(); return }
            let j = jobs.removeFirst()
            cond.unlock()
            j.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// The workspaces whose AWS helper is refused for now (an SSO profile
/// whose credentials aren't resolved: not yet, or the user's SSO session
/// ended), each with the reason the helper gets: `{"Version":1,"Error":…}`,
/// as AWSCredentialServer reports its errors.
// @port-skip linux-only: the helper's answer while an SSO profile isn't resolved (macOS vends nothing then)
enum AWSSSORefusals {
    static let message = "the workspace's AWS SSO credentials aren't resolved yet"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reasons: [UUID: String] = [:]

    // @port-skip linux-only: the SSO refusal
    static func set(_ refused: Bool, for id: UUID, reason: String = message) {
        lock.lock(); defer { lock.unlock() }
        reasons[id] = refused ? reason : nil
    }

    // @port-skip linux-only: the SSO refusal
    static func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return reasons[id] != nil
    }

    // @port-skip linux-only: the SSO refusal
    static func payload(for id: UUID) -> Data {
        lock.lock(); let reason = reasons[id] ?? message; lock.unlock()
        return (try? JSONSerialization.data(withJSONObject: ["Version": 1, "Error": reason] as [String: Any],
                                            options: [.sortedKeys])) ?? Data()
    }

    // @port-skip linux-only: the SSO refusal
    static func refuse(fd: Int32, profileID: UUID) {
        let data = payload(for: profileID)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
        close(fd)
    }
}
