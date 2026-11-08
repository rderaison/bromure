import CACLinuxShims
import Crypto
import Foundation
import NIOConcurrencyHelpers
import SandboxEngine

/// Per-install master key + symmetric encryption for at-rest secrets: the
/// Linux side of `SecretsVault` (Mitm/SecretsVault.swift). Same contract:
/// one 32-byte AES-256 master key in an OS-protected store, every secret an
/// AES-GCM blob in an ordinary file, and losing the key makes the blobs
/// unreadable (re-enter) while non-secret metadata is untouched.
///
/// The OS-protected store is systemd-creds (linux/SECRET_STORE.md):
/// - a system unit gets the key from `$CREDENTIALS_DIRECTORY` (systemd
///   decrypted `LoadCredentialEncrypted=bromure-ac-master-key:…`);
/// - otherwise `master-key.cred` beside the vault, sealed with
///   `systemd-creds [--user] encrypt` (host key, + TPM2 when present);
/// - failing both, a 0600 key file, reported by `masterKeySource`.
///
/// The key lives in mlock'ed, MADV_DONTDUMP memory, and resolving it marks
/// the process non-dumpable (PR_SET_DUMPABLE=0).
// @port-skip linux-only: the namespace; its functions carry @port lines
public enum SecretsVault {
    /// Where the master key came from (what `/state` should show).
    // @port-skip linux-only: reports the key provider; macOS logs its fallback
    public enum MasterKeySource: String, Sendable, Equatable {
        /// `$CREDENTIALS_DIRECTORY` (system unit, LoadCredentialEncrypted=).
        case credentialsDirectory = "credentials-directory"
        /// `master-key.cred`, sealed by systemd-creds.
        case systemdCreds = "systemd-creds"
        /// A 0600 key file beside the ciphertext: weaker, flagged.
        case fileFallback = "file-fallback"
    }

    /// Credential name, versioned like the macOS keychain service/account.
    static let credentialName = "bromure-ac-master-key"
    /// Blob format: `version (1) || nonce (12) || ciphertext || tag (16)`.
    static let formatV1: UInt8 = 0x01
    static let aadBase = Data("bromure-ac/vault/v1".utf8)

    // @port-skip linux-only: vault configuration
    struct State {
        var directory: String
        var key: SecureKey?
        var source: MasterKeySource?
        /// nil: the process environment. Tests pass a dictionary instead of
        /// calling setenv(), which races posix_spawn reading `environ`.
        var environment: [String: String]?
    }

    /// One vault: its directory, environment and (once loaded) key.
    // @port-skip linux-only: vault configuration
    final class Instance: Sendable {
        let state: NIOLockedValueBox<State>
        // @port-skip linux-only: vault configuration
        init(directory: String, environment: [String: String]?) {
            state = NIOLockedValueBox(State(directory: directory, key: nil, source: nil, environment: environment))
        }

        /// SecretsVault.configure on this vault. `restartable`: a test's own
        /// vault, where it drops the key (a restart); otherwise refused once
        /// a key is loaded.
        // @port-skip linux-only: vault configuration
        func configure(directory: String, environment: [String: String]?, restartable: Bool) -> Bool {
            state.withLockedValue { s in
                guard restartable || s.key == nil else {
                    FileHandle.standardError.write(Data("[secrets] the vault is in use: it stays at \(s.directory)\n".utf8))
                    return false
                }
                s.directory = directory
                s.key = nil
                s.source = nil
                s.environment = environment
                return true
            }
        }
    }

    /// The process's vault.
    static let shared = Instance(directory: SecretsVault.defaultDirectory(), environment: nil)
    /// A test's own vault (withInstance): bound to its task, so a test never
    /// changes the vault another suite's code is using meanwhile.
    @TaskLocal static var bound: Instance?
    // @port-skip linux-only: vault configuration
    static var current: Instance { bound ?? shared }
    // @port-skip linux-only: vault configuration
    static var state: NIOLockedValueBox<State> { current.state }

    /// Runs `body` with a vault of its own at `directory` (tests): every vault
    /// call in it, on this task, uses that one; the process's is untouched.
    // @port-skip linux-only: vault configuration
    public static func withInstance<T>(directory: String, environment: [String: String]? = nil,
                                       _ body: () throws -> T) rethrows -> T {
        try $bound.withValue(Instance(directory: directory, environment: environment)) { try body() }
    }

    /// `$XDG_DATA_HOME/bromure-ac/secrets` (default `~/.local/share/…`), or
    /// `/var/lib/bromure-ac/secrets` for a system service (euid 0).
    // @port-skip linux-only: Linux data directory layout
    public static func defaultDirectory() -> String {
        if geteuid() == 0 { return "/var/lib/bromure-ac/secrets" }
        let env = ProcessInfo.processInfo.environment
        let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/share"
        return data + "/bromure-ac/secrets"
    }

    /// Points the vault at `directory` (a daemon with a custom data dir),
    /// before it's used: once a key is loaded the process's vault stays where
    /// it is (moving it under code that holds its key would split the secrets
    /// between two keys). In a test's own vault (`withInstance`) it's a
    /// restart: the key is dropped and read again. False when refused.
    // @port-skip linux-only: vault configuration
    @discardableResult
    public static func configure(directory: String, environment: [String: String]? = nil) -> Bool {
        current.configure(directory: directory, environment: environment, restartable: bound != nil)
    }

    // @port-skip linux-only: vault configuration
    public static var directory: String { state.withLockedValue { $0.directory } }

    /// The provider the key came from, once resolved.
    // @port-skip linux-only: reports the key provider
    public static var masterKeySource: MasterKeySource? { state.withLockedValue { $0.source } }

    /// Fetch (or lazily create) the per-install master key. Order: a system
    /// unit's credential, then the systemd-creds sealed file, then the 0600
    /// key file (BROMURE_VAULT_KEY_SOURCE=file forces the last).
    // @port SecretsVault.static masterKey() h=4275da8496882a1c @08d935d2
    static func masterKey() throws -> SymmetricKey {
        try state.withLockedValue { s -> SymmetricKey in
            if let k = s.key { return k.symmetricKey }
            _ = acl_set_nondumpable()
            let dir = s.directory
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let env = s.environment ?? ProcessInfo.processInfo.environment
            let creds = Creds(env: env)
            if env["BROMURE_VAULT_KEY_SOURCE"] != "file" {
                // A system unit's credential. (A system unit adopting a vault
                // that already has a user credential is a migration, not a
                // fresh key: `bromure-ac secrets migrate`, not built yet.)
                if let dirEnv = env["CREDENTIALS_DIRECTORY"],
                   var data = FileManager.default.contents(atPath: dirEnv + "/" + credentialName), data.count == 32 {
                    defer { wipe(&data) }
                    return install(&s, data, .credentialsDirectory)
                }
                let cred = dir + "/master-key.cred"
                if FileManager.default.fileExists(atPath: cred) {
                    // A sealed key we can't even try to open is not a lost key.
                    guard creds.available else {
                        throw VaultError.credentials("decrypt", "master-key.cred exists but \(creds.binary) is unavailable")
                    }
                    switch creds.unseal(cred) {
                    case .key(var data):
                        defer { wipe(&data) }
                        return install(&s, data, .systemdCreds)
                    case .cannotOpen(let why):
                        // Positive "this credential can't be opened with this
                        // host's keys" (corrupt, or sealed to another TPM/host
                        // secret): the macOS "keychain entry wiped" case. Keep it
                        // aside and rotate; blobs under it read as `unreadable`.
                        FileHandle.standardError.write(Data(
                            "[secrets] master-key.cred can't be opened (\(why)); rotating the master key\n".utf8))
                        try FileManager.default.moveItem(
                            atPath: cred, toPath: cred + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                    case .failed(let why):
                        // Anything else (no credential service under sudo/cron,
                        // a timeout, EMFILE, a busy TPM) is transient: never
                        // rotate on it. The credential stays as it is.
                        throw VaultError.credentials("decrypt", why)
                    }
                }
                if creds.available {
                    // An existing file-fallback key is adopted, not replaced:
                    // its blobs must stay readable. A fresh key otherwise.
                    let keyFile = dir + "/secrets-master.key"
                    let adopted = FileManager.default.contents(atPath: keyFile).flatMap { $0.count == 32 ? $0 : nil }
                    var bytes = adopted ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    defer { wipe(&bytes) }
                    // A credential that appears meanwhile (another process of
                    // this user starting fresh) is the vault's key from then on:
                    // it's used, never replaced, and never falls back to a file
                    // key (that would split the secrets between two keys).
                    var appeared = false
                    do {
                        try creds.seal(bytes, at: cred)
                        // Only drop the plaintext once the sealed copy reads back.
                        if adopted != nil {
                            guard case .key(var back) = creds.unseal(cred), back == bytes else {
                                try? FileManager.default.removeItem(atPath: cred)
                                throw VaultError.credentials("verify", "sealed key didn't read back")
                            }
                            wipe(&back)
                            shred(keyFile)
                            FileHandle.standardError.write(Data(
                                "[secrets] moved the file-backed master key into systemd-creds\n".utf8))
                        }
                        return install(&s, bytes, .systemdCreds)
                    } catch VaultError.exists {
                        appeared = true
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[secrets] systemd-creds seal failed: \(error) — falling back to file key\n".utf8))
                    }
                    if appeared {
                        guard case .key(var theirs) = creds.unseal(cred) else {
                            throw VaultError.credentials("decrypt", "master-key.cred appeared meanwhile but can't be opened")
                        }
                        defer { wipe(&theirs) }
                        FileHandle.standardError.write(Data("[secrets] another process sealed the master key first: using it\n".utf8))
                        return install(&s, theirs, .systemdCreds)
                    }
                }
            }
            var key = try fileFallbackKey(directory: dir)
            defer { wipe(&key) }
            FileHandle.standardError.write(Data(
                "[secrets] systemd-creds unavailable — using file-backed master key (secret encryption is local-key only)\n".utf8))
            return install(&s, key, .fileFallback)
        }
    }

    // @port-skip linux-only: key installation into locked memory
    private static func install(_ s: inout State, _ bytes: Data, _ source: MasterKeySource) -> SymmetricKey {
        let k = SecureKey(bytes)
        s.key = k
        s.source = source
        return k.symmetricKey
    }

    /// Zeroes a transient copy of key bytes (in place, when the buffer is
    /// uniquely ours; Data is copy-on-write).
    // @port-skip linux-only: key hygiene
    static func wipe(_ d: inout Data) {
        d.withUnsafeMutableBytes { b in if let p = b.baseAddress { memset(p, 0, b.count) } }
    }

    /// Overwrites a key file with zeros, flushes, then unlinks it.
    // @port-skip linux-only: key hygiene
    static func shred(_ path: String) {
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0 {
                let zeros = [UInt8](repeating: 0, count: Int(st.st_size))
                _ = zeros.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                fsync(fd)
            }
            close(fd)
        }
        unlink(path)
    }

    /// Master key in a 0600 file in the vault directory: the fallback when
    /// systemd-creds is unavailable (containers, systemd < 256 for --user).
    // @port SecretsVault.static fileFallbackKey() h=47d6fbebb8289f55 @08d935d2
    static func fileFallbackKey(directory: String) throws -> Data {
        let path = directory + "/secrets-master.key"
        if let data = FileManager.default.contents(atPath: path) {
            if data.count == 32 { return data }
            // Not a key: kept aside, never overwritten (its blobs read as unreadable).
            try FileManager.default.moveItem(atPath: path, toPath: path + ".unreadable-\(Int(Date().timeIntervalSince1970))")
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = path + ".tmp-\(getpid())-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard FileManager.default.createFile(atPath: tmp, contents: fresh,
                                             attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw VaultError.io("write \(tmp)")
        }
        do {
            try placeNew(tmp, at: path)
        } catch VaultError.exists {
            // Another process made it meanwhile: theirs is the key.
            guard let theirs = FileManager.default.contents(atPath: path), theirs.count == 32 else {
                throw VaultError.io("\(path) appeared but isn't a key")
            }
            return theirs
        }
        return fresh
    }

    /// Puts the file `tmp` at `path` only if nothing is there: link(2) fails
    /// on an existing name, where rename(2) would replace it. The vault's
    /// key files are only ever created this way; an existing one is only
    /// ever moved aside (rotate), never replaced.
    // @port-skip linux-only: the vault's no-replace invariant
    static func placeNew(_ tmp: String, at path: String) throws {
        if link(tmp, path) == 0 { return }
        if errno == EEXIST { throw VaultError.exists(path) }
        throw VaultError.io("link \(path): \(String(cString: strerror(errno)))")
    }

    /// Encrypt arbitrary bytes with the master key.
    // Format change vs macOS (which writes the bare AES-GCM combined form,
    // nonce || ciphertext || tag): a leading version byte (0x01), and AAD
    // binding the blob to the vault (and, via encrypt(_:item:), to its item
    // name). decrypt reads both, so a shared-core version can too.
    // @port SecretsVault.static encrypt(_: Data) h=0727860328d8d5f7 @08d935d2
    public static func encrypt(_ plain: Data) throws -> Data {
        try encrypt(plain, item: nil)
    }

    /// `encrypt`, bound to `item`: the blob only decrypts as that item.
    // @port-skip linux-only: item-bound AAD (Linux format addition)
    public static func encrypt(_ plain: Data, item: String?) throws -> Data {
        let key = try masterKey()
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: aad(item))
        guard let combined = sealed.combined else { throw VaultError.sealFailed }
        return Data([formatV1]) + combined
    }

    // Reads the Linux v1 format (version byte + AAD) and the macOS legacy
    // format (bare combined form, no AAD). A legacy blob whose random first
    // nonce byte happens to be 0x01 fails v1 authentication and is retried as
    // legacy; GCM's tag makes the retry safe.
    // @port SecretsVault.static decrypt(_: Data) h=f8b597332fec01c9 @08d935d2
    public static func decrypt(_ blob: Data) throws -> Data {
        try decrypt(blob, item: nil)
    }

    // @port-skip linux-only: item-bound AAD (Linux format addition)
    public static func decrypt(_ blob: Data, item: String?) throws -> Data {
        let key = try masterKey()
        if blob.first == formatV1, blob.count >= 1 + 12 + 16,
           let box = try? AES.GCM.SealedBox(combined: blob.dropFirst()),
           let plain = try? AES.GCM.open(box, using: key, authenticating: aad(item)) {
            return plain
        }
        if item == nil, blob.count >= 12 + 16,
           let box = try? AES.GCM.SealedBox(combined: blob),
           let plain = try? AES.GCM.open(box, using: key) {
            return plain
        }
        throw VaultError.unreadable
    }

    // @port-skip linux-only: item-bound AAD
    static func aad(_ item: String?) -> Data {
        guard let item else { return aadBase }
        return aadBase + Data([0]) + Data(item.utf8)
    }

    // MARK: systemd-creds plumbing (the Keychain's counterpart)

    /// systemd-creds as the vault uses it. The binary is injectable
    /// (BROMURE_SYSTEMD_CREDS in the vault's environment) so tests can stand in
    /// for every failure mode without depending on the host.
    // @port-skip linux-only: systemd-creds invocation
    struct Creds {
        let binary: String
        /// `--user` unless we're root (a system service seals with the
        /// system's host key, for LoadCredentialEncrypted=).
        let scope: [String]

        // @port-skip linux-only: systemd-creds invocation
        init(env: [String: String]) {
            binary = env["BROMURE_SYSTEMD_CREDS"] ?? "/usr/bin/systemd-creds"
            scope = geteuid() == 0 ? [] : ["--user"]
        }

        // @port-skip linux-only: systemd-creds availability probe
        var available: Bool { FileManager.default.isExecutableFile(atPath: binary) }

        enum Unseal {
            case key(Data)
            /// Definitely can't be opened with this host's keys: rotate.
            case cannotOpen(String)
            /// Couldn't tell (didn't run, IPC, timeout, TPM busy…): don't touch.
            case failed(String)
        }

        /// Unseals; classifies failures conservatively. Observed on lnx-ntv
        /// (systemd 259): a corrupted or foreign credential fails with
        /// "Failed to read encrypted credential data: Invalid argument"
        /// (authentication failed); truncation and garbage give "Broken pipe",
        /// which an IPC failure could too, so those count only when the file
        /// itself is structurally malformed (not base64, or too short).
        // @port SecretsVault.static fetchFromKeychain() h=6ee726011c0be0fc @08d935d2
        func unseal(_ path: String) -> Unseal {
            do {
                let out = try ChildProcess.capture(binary, ["decrypt"] + scope + ["--name=\(credentialName)", path, "-"],
                                                   input: nil)
                guard out.count == 32 else { return .cannotOpen("decrypted to \(out.count) bytes") }
                return .key(out)
            } catch MachineError.toolFailed(_, _, let err) {
                if err.contains("Failed to read encrypted credential data: Invalid argument") {
                    return .cannotOpen(err)
                }
                if Self.malformed(path) { return .cannotOpen("malformed credential file (\(err))") }
                return .failed(err)
            } catch {
                return .failed("\(error)")
            }
        }

        /// Seals `key` into `path` (0600), never over an existing file: it's
        /// sealed beside it and linked into place, so a credential another
        /// process put there meanwhile is never replaced (VaultError.exists).
        /// Key bytes go over a pipe.
        // @port SecretsVault.static storeInKeychain(_: SymmetricKey) h=07a0ca756e929bb0 @08d935d2
        func seal(_ key: Data, at path: String) throws {
            let tmp = path + ".tmp-\(getpid())-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            do {
                _ = try ChildProcess.capture(binary, ["encrypt"] + scope + ["--name=\(credentialName)", "-", tmp], input: key)
            } catch MachineError.toolFailed(_, _, let err) {
                throw VaultError.credentials("encrypt", err)
            }
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: tmp)
            try SecretsVault.placeNew(tmp, at: path)
        }

        /// A systemd credential file is base64 of a binary header + payload; a
        /// file that isn't, or is shorter than any real one, is corrupt.
        // @port-skip linux-only: credential sanity check
        static func malformed(_ path: String) -> Bool {
            guard let raw = FileManager.default.contents(atPath: path) else { return false }
            let text = String(decoding: raw, as: UTF8.self).filter { !$0.isWhitespace }
            guard let bin = Data(base64Encoded: text) else { return true }
            return bin.count < 64
        }
    }
}

/// Named secrets: the Linux home for what macOS keeps as Keychain
/// generic-password items (service + account). One 0600 blob per item under
/// `<vault>/items/<service>/<account>.blob`, sealed with the item's name as
/// AAD, so a blob copied over another item's file doesn't decrypt.
// @port-skip linux-only: replaces Keychain generic-password items
public enum VaultItems {
    // @port-skip linux-only: Keychain item replacement
    static func name(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    // @port-skip linux-only: Keychain item replacement
    static func path(_ service: String, _ account: String) -> String {
        func safe(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")) ?? s
        }
        return SecretsVault.directory + "/items/" + safe(service) + "/" + safe(account) + ".blob"
    }

    // @port-skip linux-only: Keychain item replacement
    public static func set(_ data: Data, service: String, account: String) throws {
        let p = path(service, account)
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let blob = try SecretsVault.encrypt(data, item: name(service, account))
        let tmp = p + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: blob,
                                             attributes: [.posixPermissions: NSNumber(value: 0o600)]),
              rename(tmp, p) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw VaultError.io("write \(p)")
        }
    }

    /// nil when there's no such item; throws `.unreadable` when there is one
    /// the current master key can't open (lost key, tampering, a swapped blob).
    // @port-skip linux-only: Keychain item replacement
    public static func get(service: String, account: String) throws -> Data? {
        guard let blob = FileManager.default.contents(atPath: path(service, account)) else { return nil }
        return try SecretsVault.decrypt(blob, item: name(service, account))
    }

    // @port-skip linux-only: Keychain item replacement
    public static func delete(service: String, account: String) {
        try? FileManager.default.removeItem(atPath: path(service, account))
    }
}

/// The master key's bytes in mlock'ed, MADV_DONTDUMP memory, zeroed on free.
/// (A SymmetricKey made from it for each operation is a short-lived copy that
/// swift-crypto zeroes on dealloc.)
// @port-skip linux-only: locked key memory (macOS relies on the Keychain + CryptoKit)
final class SecureKey: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    let locked: Bool

    // @port-skip linux-only: locked key memory
    init(_ bytes: Data) {
        var l: Int32 = 0
        count = bytes.count
        pointer = acl_secure_alloc(bytes.count, &l)!
        locked = l != 0
        bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    }

    // @port-skip linux-only: locked key memory
    var symmetricKey: SymmetricKey {
        SymmetricKey(data: UnsafeRawBufferPointer(start: pointer, count: count))
    }

    // @port-skip linux-only: locked key memory
    deinit { acl_secure_free(pointer, count) }
}

// @port-skip linux-only: the Linux vault's errors (macOS: VaultError)
public enum VaultError: Error, CustomStringConvertible, Equatable {
    case credentials(String, String)
    case sealFailed
    /// The blob doesn't open with the current master key: lost key, a
    /// tampered byte, or a blob moved to another item. Re-enter the secret.
    case unreadable
    case io(String)
    /// A key file that was to be created exists already (another process
    /// made it meanwhile): it's never replaced.
    case exists(String)

    // @port VaultError.var description h=0e6f9aca2e366991 @08d935d2
    public var description: String {
        switch self {
        case .credentials(let op, let detail): return "systemd-creds \(op) failed: \(detail)"
        case .sealFailed: return "AES-GCM seal returned no combined output"
        case .unreadable: return "secret unreadable with the current master key; re-enter it"
        case .io(let what): return "vault I/O failed: \(what)"
        case .exists(let path): return "\(path) exists already"
        }
    }
}

/// The shared code's Keychain stand-in (BACSecretStore: the enrollment's
/// install token and leaf key, InstallIdentity's items) kept in this
/// daemon's encrypted vault. Plugged in when the daemon starts.
// @port-skip linux-only: plugs the vault into the shared BACSecretStore seam
struct VaultSecretBackend: BACSecretStore.Backend {
    // @port-skip linux-only: BACSecretStore seam
    func store(service: String, account: String, data: Data) throws {
        try VaultItems.set(data, service: service, account: account)
    }

    // @port-skip linux-only: BACSecretStore seam
    func read(service: String, account: String) -> Data? {
        try? VaultItems.get(service: service, account: account)
    }

    // @port-skip linux-only: BACSecretStore seam
    func delete(service: String, account: String) {
        VaultItems.delete(service: service, account: account)
    }
}
