import Foundation

// MARK: - Fat-client shared types (platform-independent)
//
// The portable half of the fat-client transport layer: host records, probe
// results, the keychain-backed client identity, and the observable host store.
// Split out of FatClientRemote.swift so the iOS/iPadOS client (which compiles
// a subset of these sources; see ios/) can share them — everything here is
// Foundation + Security only. The Process-based `RemoteTransport`/`SSHTunnel`
// (system ssh, ssh-keygen, ssh-agent) stay macOS-only in FatClientRemote.swift;
// iOS provides its own `RemoteTransport` with the same static API over an
// in-process NIOSSH client (ios/RemoteTransportMobile.swift).

// MARK: - Fat-client diagnostics

/// Unbuffered stderr logging for the fat-client path (print() is fully buffered
/// when stdout is redirected, so it's unreliable for a GUI process we kill).
enum FatClientLog {
    static let enabled = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_LOG"] != nil
        || ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_OPEN"] != nil
    /// When set to a path, also append to that file (survives pty/stderr mixing).
    static let filePath = ProcessInfo.processInfo.environment["BROMURE_ATTACH_DEBUG"]
    static func log(_ msg: @autoclosure () -> String) {
        let line = "[fatclient] \(msg())\n"
        if enabled { FileHandle.standardError.write(Data(line.utf8)) }
        if let filePath {
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: filePath) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            }
        }
    }
}

// MARK: - Fat-client remote transport types

/// A configured remote bromure-ac instance the fat client can mirror.
struct RemoteHost: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String            // display label ("rack mini")
    var address: String         // hostname or IP the SSH server listens on
    var port: Int = 2222
    var user: String            // the macOS account running the remote app
    /// TOFU-pinned SSH host-key fingerprint (`SHA256:…`). Set on first trust;
    /// a mismatch on a later connect is flagged as a possible MITM.
    var pinnedHostKey: String? = nil
    /// Last successful connect — orders the "Recent Servers" list.
    var lastConnected: Date? = nil
    /// When set, this host is reached peer-to-peer through the P2P broker
    /// (REMOTE_P2P_PLAN.md) rather than by dialing `address:port` directly. The
    /// broker resolves it to a live loopback endpoint; `address`/`port` then
    /// carry that `127.0.0.1:N` for the session. Absent ⇒ the classic direct
    /// dial, unchanged. Optional so existing hosts.json decodes untouched.
    var peerDeviceID: String? = nil

    var connectLabel: String {
        peerDeviceID.map { "\(user)@peer:\(String($0.prefix(8)))" } ?? "\(user)@\(address):\(port)"
    }

    /// How the dialer reaches this host.
    enum Kind: Equatable { case direct, peer(String) }
    var kind: Kind { peerDeviceID.map { .peer($0) } ?? .direct }
    var isPeer: Bool { peerDeviceID != nil }

    /// A stable known_hosts alias for a peer connection. The loopback endpoint's
    /// port changes per session, so the SSH host-key pin must key on the peer's
    /// device identity, not on `127.0.0.1:<ephemeral>` (`-o HostKeyAlias=`).
    var hostKeyAlias: String? {
        peerDeviceID.map { "bromure-peer-\($0)" }
    }
}

/// Result of probing a remote with a given credential, classified from ssh's
/// exit + stderr so the connect UI can react (retry password, warn on host-key
/// change, etc.).
enum RemoteProbe: Equatable {
    case ok
    case authFailed          // key/password rejected
    case hostKeyChanged      // pinned host key no longer matches — possible MITM
    case unreachable(String) // refused / timeout / DNS / remote access off
}

/// A scanned remote host key: the `known_hosts` line + its SHA256 fingerprint.
struct HostKeyInfo: Equatable {
    let line: String
    let fingerprint: String
}

/// The fat client's private key at rest: one generic-password item in the
/// data-protection keychain (app-scoped by code signature, no UI — the
/// SecretsVault choice). System ssh can't read it, so macOS dials go through an
/// in-memory ssh-agent (see RemoteTransport.keyAgentSock); the iOS client hands
/// it straight to its in-process NIOSSH dialer.
enum FatClientKeyStore {
    private static let service = "io.bromure.agentic-coding.fatclient"
    private static let account = "client-key-ed25519"

    /// The three states a keychain read can honestly be in. Collapsing
    /// "the keychain won't serve it RIGHT NOW" into "it doesn't exist"
    /// was how a long screen lock ended in the enrolled identity being
    /// regenerated over — and a password re-pair on the next connect.
    enum LoadResult {
        case found(String)
        case notFound
        /// The item exists but is unreadable at this moment (device
        /// locked before first unlock, post-wake window, other transient
        /// Security errors). Callers must fail the attempt — NEVER mint a
        /// replacement identity.
        case unavailable(OSStatus)
    }

    static func load() -> LoadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let dict = out as? [CFString: Any],
                  let data = dict[kSecValueData] as? Data,
                  let pem = String(data: data, encoding: .utf8) else {
                return .unavailable(status)
            }
            // Migrate items stored with the original WhenUnlocked class:
            // the fat client opens SSH channels while the screen is locked
            // (background mirroring), so the key must be readable after
            // first unlock. Re-store is safe — we hold the pem.
            if let acc = dict[kSecAttrAccessible] as? String,
               acc == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) {
                store(pem)
            }
            return .found(pem)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    @discardableResult
    static func store(_ pem: String) -> Bool {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(pem.utf8),
            // After-first-unlock, not when-unlocked: still device-bound and
            // encrypted at rest until the first unlock after boot, but
            // readable while the screen is locked — new terminals must be
            // able to open SSH channels on a locked Mac.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}

/// UI-facing, observable store of configured remote hosts. Delegates all path /
/// transport work to `RemoteTransport`.
@MainActor
@Observable
final class RemoteHostStore {
    static let shared = RemoteHostStore()

    private(set) var hosts: [RemoteHost] = []

    init() { hosts = RemoteTransport.loadHosts() }

    func reload() { hosts = RemoteTransport.loadHosts() }

    @discardableResult
    func upsert(_ host: RemoteHost) -> RemoteHost {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        RemoteTransport.saveHosts(hosts)
        return host
    }

    /// Forget = UNPAIR: best-effort revoke this client's key on the server
    /// (over the still-authenticated tunnel), then drop the record.
    /// Without the revoke, a "removed" server kept trusting this client
    /// forever. The key itself stays — other pairings share it.
    func remove(_ id: UUID) {
        if let host = hosts.first(where: { $0.id == id }),
           let fp = RemoteTransport.clientKeyFingerprint() {
            DispatchQueue.global(qos: .utility).async {
                _ = try? RemoteTransport.client(for: host).request(
                    "DELETE", "/remote/keys/\(ControlClient.encodeSegment(fp))")
            }
        }
        hosts.removeAll { $0.id == id }
        RemoteTransport.saveHosts(hosts)
    }

    func host(_ id: UUID) -> RemoteHost? { hosts.first { $0.id == id } }

    @discardableResult
    func ensureClientKey() -> String? { RemoteTransport.ensureClientKey() }

    func client(for host: RemoteHost) -> ControlClient { RemoteTransport.client(for: host) }
}
