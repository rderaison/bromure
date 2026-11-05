import CACLinuxShims
import Foundation

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

    // @port-skip linux-only: the VZVirtioSocketListener delegates over hybrid vsock
    init(udsPath: String, port: UInt32, fdStoreName: String, stored: Int32?,
         accept: @escaping @Sendable (Int32) -> Int32 = { acl_accept_cloexec($0) },
         serve: @escaping @Sendable (Int32) async -> Void) throws {
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
                Task.detached(priority: .userInitiated) { await serve(c) }
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

    // @port-skip linux-only: the per-VM vsock listeners
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// The AWS credential_process helper's end (vsock 8445): the server
    /// writes the workspace's key id and a fake secret, and closes.
    // @port AWSCredsListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=e8fd6c0c1f44aa28 @8e2543eb
    static func awsCreds(udsPath: String, fdStoreName: String, stored: Int32?, profileID: UUID,
                         server: AWSCredentialServer) throws -> VsockFDListener {
        try VsockFDListener(udsPath: udsPath, port: 8445, fdStoreName: fdStoreName, stored: stored) {
            if AWSSSORefusals.contains(profileID) {
                AWSSSORefusals.refuse(fd: $0)
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
    /// server (static keys as they are), and the helper ~/.aws/config names
    /// staged in its meta share.
    // partial: no SSO resolution or refresh loop (AWSSSOResolver isn't shared yet): an SSO profile's helper gets an error payload
    // partial: no re-push when a running workspace moves onto Bedrock (macOS: LiveModelRefresh); its keys are pushed at launch and adoption
    // @port ACAppDelegate.pushAWSCredentials(for: Profile, engine: MitmEngine) h=08b3dd4f6296a0b4 @d2db8346
    func pushAWSCredentials(for profile: Profile, meta: String) {
        guard let mitm else { return }
        if profile.awsCredentials.authMode == .ssoProfile {
            // No keys to vend (an SSO profile's are resolved on the host):
            // the helper is told why, rather than signing with empty keys.
            FileHandle.standardError.write(Data(
                "[sso] SSO profile '\(profile.awsCredentials.ssoProfileName)': not resolved on this Linux server yet; the guest's AWS helper is refused\n".utf8))
            AWSSSORefusals.set(true, for: profile.id)
            mitm.awsCreds.setCredentials(AWSCredentials(), for: profile.id)
        } else {
            AWSSSORefusals.set(false, for: profile.id)
            mitm.awsCreds.setCredentials(profile.awsCredentials, for: profile.id)
        }
        Self.stageAWSCredsHelper(meta: meta)
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

/// The workspaces whose AWS helper is refused (an SSO profile, which this
/// server can't resolve yet), and the refusal it gets: the helper's
/// `{"Version":1,"Error":…}`, as AWSCredentialServer reports its errors.
// @port-skip linux-only: stands in for macOS's AWSSSOResolver until it's shared
enum AWSSSORefusals {
    static let message = "SSO isn't supported on this server yet"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: Set<UUID> = []

    // @port-skip linux-only: the SSO stand-in
    static func set(_ refused: Bool, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if refused { ids.insert(id) } else { ids.remove(id) }
    }

    // @port-skip linux-only: the SSO stand-in
    static func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    // @port-skip linux-only: the SSO stand-in
    static var payload: Data {
        (try? JSONSerialization.data(withJSONObject: ["Version": 1, "Error": message] as [String: Any],
                                     options: [.sortedKeys])) ?? Data()
    }

    // @port-skip linux-only: the SSO stand-in
    static func refuse(fd: Int32) {
        let data = payload
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
