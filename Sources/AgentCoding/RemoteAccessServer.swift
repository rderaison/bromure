import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SandboxEngine

// MARK: - Remote access (optional embedded SSH server)

/// Optional remote access to bromure-ac over SSH.
///
/// We embed Apple's `swift-nio-ssh` rather than shell out to the system
/// `/usr/sbin/sshd`. Why: macOS's sshd can only verify a *password* through its
/// PAM stack (`/etc/pam.d/sshd`), which enforces the SSH Service ACL
/// (`pam_sacl ssh`) — that ACL denies every login unless *Remote Login* is
/// enabled, and the PAM service name is hardcoded. So the only way to honor
/// "log in with the Mac account password, without enabling Remote Login and
/// without root" is to own the auth layer ourselves: here we verify the
/// password against OpenDirectory and public keys against a managed
/// `authorized_keys`. Every session is forced into `bromure-ac __remote-menu`
/// (the curses-style minishell) on a real PTY; a raw shell is never reachable.
///
/// Disabled by default. Toggled via Preferences → Remote Access or the
/// `bromure-ac remote` CLI.
@MainActor
final class RemoteAccessServer {

    static let shared = RemoteAccessServer()

    /// On-disk layout under ~/Library/Application Support/BromureAC/remote/.
    struct Paths {
        let dir: URL
        var hostKey: URL    { dir.appendingPathComponent("hostkey_ed25519") }        // raw 32-byte seed
        var hostKeyPub: URL { dir.appendingPathComponent("hostkey_ed25519.pub") }    // OpenSSH line
        var authKeys: URL   { dir.appendingPathComponent("authorized_keys") }

        static var `default`: Paths {
            let base = ProfileStore().controlSocketURL.deletingLastPathComponent()
            return Paths(dir: base.appendingPathComponent("remote", isDirectory: true))
        }
    }

    /// User-facing knobs, sourced from UserDefaults by the caller.
    struct Config: Equatable {
        var port: Int = 2222
        var bindAddress: String = "0.0.0.0"
        var passwordAuth: Bool = true
        var pubkeyAuth: Bool = true
    }

    private let paths: Paths
    private let fm = FileManager.default
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var current: Config?
    private var running = false

    private static let sshKeygenBinary = "/usr/bin/ssh-keygen"

    init(paths: Paths = .default) { self.paths = paths }

    enum RemoteError: LocalizedError {
        case keygenFailed(String)
        case startFailed(String)
        case badKey(String)
        case noAuthMethods
        var errorDescription: String? {
            switch self {
            case .keygenFailed(let m): return "Couldn't generate host key: \(m)"
            case .startFailed(let m):  return "Couldn't start the SSH server: \(m)"
            case .badKey(let m):       return "Not a valid public key: \(m)"
            case .noAuthMethods:       return "At least one of password / public-key auth must be enabled."
            }
        }
    }

    var isRunning: Bool { running }

    // MARK: Lifecycle

    /// Start (or restart) the embedded SSH server. Idempotent.
    func start(_ config: Config) throws {
        guard config.passwordAuth || config.pubkeyAuth else { throw RemoteError.noAuthMethods }
        stop()

        try ensureLayout()
        let hostKey = try loadOrCreateHostKey()
        let authorized = config.pubkeyAuth ? loadAuthorizedNIOKeys() : []
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let user = NSUserName()

        let g = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let delegate = RemoteAuthDelegate(
            username: user,
            allowPassword: config.passwordAuth,
            allowPubkey: config.pubkeyAuth,
            authorizedKeys: authorized)

        // NOTE: swift-nio-ssh (0.13.0, latest) offers no post-quantum key
        // exchange — only curve25519-sha256 and ecdh-sha2-nistp*, and the KEX
        // list isn't configurable (SSHServerConfiguration only exposes the
        // symmetric `transportProtectionSchemes`). So OpenSSH clients print a
        // "not using a post-quantum key exchange" warning. Revisit (offer
        // mlkem768x25519-sha256) once upstream adds PQ KEX.
        let bootstrap = ServerBootstrap(group: g)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .server(.init(
                                hostKeys: [hostKey],
                                userAuthDelegate: delegate,
                                globalRequestDelegate: nil)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: { childChannel, channelType in
                                guard channelType == .session else {
                                    return childChannel.eventLoop.makeFailedFuture(RemoteSSHError.invalidChannelType)
                                }
                                return childChannel.eventLoop.makeCompletedFuture {
                                    try childChannel.pipeline.syncOperations.addHandler(
                                        SSHPTYSessionHandler(menuExe: exe, user: user))
                                }
                            }),
                        RemoteErrorHandler(),
                    ])
                }
            }

        do {
            let ch = try bootstrap.bind(host: config.bindAddress, port: config.port).wait()
            self.group = g
            self.channel = ch
            self.current = config
            self.running = true
            SupplyChainLog.shared.record("[remote] embedded SSH server listening on \(config.bindAddress):\(config.port).")
        } catch {
            try? g.syncShutdownGracefully()
            throw RemoteError.startFailed(error.localizedDescription)
        }
    }

    func stop() {
        running = false
        if let ch = channel { try? ch.close().wait(); channel = nil }
        if let g = group { try? g.syncShutdownGracefully(); group = nil }
        current = nil
    }

    // MARK: Host key

    private func loadOrCreateHostKey() throws -> NIOSSHPrivateKey {
        let curve: Curve25519.Signing.PrivateKey
        if let data = try? Data(contentsOf: paths.hostKey), data.count == 32,
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            curve = k
        } else {
            curve = Curve25519.Signing.PrivateKey()
            try curve.rawRepresentation.write(to: paths.hostKey)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.hostKey.path)
        }
        // Always (re)write the public line so display/fingerprint stay in sync.
        try? Self.opensshPublicLine(curve.publicKey).write(to: paths.hostKeyPub, atomically: true, encoding: .utf8)
        return NIOSSHPrivateKey(ed25519Key: curve)
    }

    private func currentHostPublicKey() -> Curve25519.Signing.PublicKey? {
        guard let data = try? Data(contentsOf: paths.hostKey), data.count == 32,
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return k.publicKey
    }

    /// `SHA256:…` fingerprint of the host key (same format as `ssh-keygen -l`).
    func hostKeyFingerprint() -> String? {
        guard let pub = currentHostPublicKey() else { return nil }
        let blob = Self.ed25519SSHBlob(pub)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "256 SHA256:\(b64) bromure-ac-remote (ED25519)"
    }

    /// Build the SSH wire blob for an ed25519 public key: string("ssh-ed25519") || string(rawpub).
    private static func ed25519SSHBlob(_ pub: Curve25519.Signing.PublicKey) -> Data {
        var d = Data()
        func sshString(_ bytes: Data) {
            var be = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            d.append(bytes)
        }
        sshString(Data("ssh-ed25519".utf8))
        sshString(pub.rawRepresentation)
        return d
    }

    private static func opensshPublicLine(_ pub: Curve25519.Signing.PublicKey) -> String {
        "ssh-ed25519 \(ed25519SSHBlob(pub).base64EncodedString()) bromure-ac-remote"
    }

    // MARK: Authorized keys

    private func loadAuthorizedNIOKeys() -> Set<NIOSSHPublicKey> {
        var set = Set<NIOSSHPublicKey>()
        for k in listAuthorizedKeys() {
            if let pk = try? NIOSSHPublicKey(openSSHPublicKey: k.line) { set.insert(pk) }
        }
        return set
    }

    struct AuthorizedKey {
        let line: String
        let type: String
        let comment: String
        let fingerprint: String
    }

    func listAuthorizedKeys() -> [AuthorizedKey] {
        guard let body = try? String(contentsOf: paths.authKeys, encoding: .utf8) else { return [] }
        return body.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let comment = parts.count >= 3 ? parts[2] : ""
            return AuthorizedKey(line: line, type: parts[0], comment: comment,
                                 fingerprint: Self.fingerprint(ofPublicKeyLine: line) ?? "?")
        }
    }

    func addAuthorizedKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate by parsing it the same way the server will.
        guard (try? NIOSSHPublicKey(openSSHPublicKey: key)) != nil else {
            throw RemoteError.badKey("couldn't parse it (supported: ed25519, ecdsa)")
        }
        try ensureLayout()
        var lines = (try? String(contentsOf: paths.authKeys, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        let blob = key.split(separator: " ").prefix(2).joined(separator: " ")
        lines.removeAll { $0.split(separator: " ").prefix(2).joined(separator: " ") == blob }
        lines.append(key)
        try (lines.joined(separator: "\n") + "\n").write(to: paths.authKeys, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.authKeys.path)
        reloadIfRunning()
    }

    func removeAuthorizedKey(_ selector: String) throws {
        var keys = listAuthorizedKeys()
        let sel = selector.trimmingCharacters(in: .whitespaces)
        if let idx = Int(sel), idx >= 1, idx <= keys.count {
            keys.remove(at: idx - 1)
        } else {
            keys.removeAll { $0.fingerprint == sel || $0.fingerprint.contains(sel) }
        }
        let body = keys.map(\.line).joined(separator: "\n")
        try (body.isEmpty ? "" : body + "\n").write(to: paths.authKeys, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.authKeys.path)
        reloadIfRunning()
    }

    /// Authorized keys are read at start; restart to pick up edits while live.
    private func reloadIfRunning() {
        guard running, let cfg = current else { return }
        try? start(cfg)
    }

    // MARK: Filesystem

    private func ensureLayout() throws {
        try fm.createDirectory(at: paths.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.dir.path)
        if !fm.fileExists(atPath: paths.authKeys.path) {
            fm.createFile(atPath: paths.authKeys.path, contents: Data(),
                          attributes: [.posixPermissions: 0o600])
        }
    }

    private static func fingerprint(ofPublicKeyLine line: String) -> String? {
        let tmp = NSTemporaryDirectory() + "bromure-pk-\(abs(line.hashValue)).pub"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? line.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshKeygenBinary)
        p.arguments = ["-lf", tmp]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }).map(String.init)
            ?? out.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
