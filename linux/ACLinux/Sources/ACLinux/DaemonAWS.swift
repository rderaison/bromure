import Foundation

/// One VM's host end of the AWS `credential_process` helper
/// (/mnt/bromure-meta/bromure-aws-creds.py, which ~/.aws/config names):
/// Firecracker delivers the guest's vsock 8445 connections on
/// `<v.sock>_8445`; each is handed to the credential server, which writes
/// the workspace's credentials (a fake secret: the proxy re-signs) and
/// closes (macOS: AWSCredsListenerDelegate).
// @port-skip linux-only: AWSCredsListenerDelegate over hybrid vsock
final class AWSCredsListener: @unchecked Sendable {
    /// macOS: MitmEngine.awsCredsVsockPort.
    static let vsockPort: UInt32 = 8445
    let path: String
    let fdStoreName: String
    private let fd: Int32

    // @port AWSCredsListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=e8fd6c0c1f44aa28 @8e2543eb
    init(udsPath: String, fdStoreName: String, stored: Int32?, profileID: UUID, server: AWSCredentialServer) throws {
        path = HybridVsockListener.path(uds: udsPath, port: Self.vsockPort)
        self.fdStoreName = fdStoreName
        if let stored { fd = stored } else {
            fd = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [fd])
        }
        // Accepts until stop() shuts the socket down; the thread owns the
        // close, so no accept ever runs on a reused descriptor number.
        let listening = fd
        let t = Thread {
            while true {
                let c = accept(listening, nil, nil)
                if c < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    close(listening)
                    return
                }
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                Task.detached(priority: .userInitiated) { await server.serve(fd: c, profileID: profileID) }
            }
        }
        t.name = "aws-creds-" + fdStoreName
        t.start()
    }

    /// The VM is gone: the listener shut down (its thread closes it) and its
    /// socket file removed.
    // @port-skip linux-only: the per-VM AWS credentials listener
    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension Daemon {
    /// A workspace VM's AWS credentials listener (none for a cluster or
    /// sign-in machine, or without the proxy).
    // @port-skip linux-only: the per-VM AWS credentials listener (macOS: MitmEngine.register's 8445 listener)
    func serveAWSCreds(_ rec: VMRecord, udsPath: String, stored: Int32?) -> AWSCredsListener? {
        guard let mitm, !rec.managed, let pid = UUID(uuidString: rec.id) else { if let stored { close(stored) }; return nil }
        do {
            return try AWSCredsListener(udsPath: udsPath, fdStoreName: "aws-" + rec.shortId, stored: stored,
                                        profileID: pid, server: mitm.awsCreds)
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no AWS credentials listener: \(error)\n".utf8))
            return nil
        }
    }

    /// The workspace's AWS credentials, handed to the host-side credential
    /// server (static keys as they are), and the helper ~/.aws/config names
    /// staged in its meta share.
    // partial: no SSO resolution or refresh loop (AWSSSOResolver isn't shared yet): an SSO profile's stored keys are used, as macOS falls back when resolution fails
    // @port ACAppDelegate.pushAWSCredentials(for: Profile, engine: MitmEngine) h=08b3dd4f6296a0b4 @d2db8346
    func pushAWSCredentials(for profile: Profile, meta: String) {
        guard let mitm else { return }
        if profile.awsCredentials.authMode == .ssoProfile {
            FileHandle.standardError.write(Data(
                "[sso] SSO profile '\(profile.awsCredentials.ssoProfileName)': not resolved on this Linux server yet; its stored keys are used\n".utf8))
        }
        mitm.awsCreds.setCredentials(profile.awsCredentials, for: profile.id)
        Self.stageAWSCredsHelper(meta: meta)
    }

    /// bromure-aws-creds.py in the meta share, 0755 (macOS: SessionDisk's
    /// awsCredsHelperURL copy).
    // @port-skip linux-only: SessionDisk's meta-share copy of the AWS helper
    static func stageAWSCredsHelper(meta: String) {
        guard let src = acResourceBundle.url(forResource: "vm-setup/bromure-aws-creds", withExtension: "py") else {
            FileHandle.standardError.write(Data("bromure-ac daemon: bromure-aws-creds.py missing from the resources\n".utf8))
            return
        }
        let dest = meta + "/bromure-aws-creds.py"
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try FileManager.default.copyItem(atPath: src.path, toPath: dest)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest)
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: couldn't stage the AWS helper: \(error)\n".utf8))
        }
    }
}
