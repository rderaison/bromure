import Foundation
import CryptoKit
import Security

/// Per-machine enrollment into the managed-profiles control plane. A single
/// Bromure install may be enrolled in multiple orgs at the same time, one
/// `InstallIdentity` per enrollment.
///
/// Holds:
///   - a shared X25519 keypair used to receive sealed-box bundle payloads,
///   - one install bearer token per enrollment (keyed by `installId`),
///   - metadata linking us to an org and a managed profile.
///
/// All secrets live in the macOS Keychain (WhenUnlockedThisDeviceOnly).
/// Plain metadata lives in JSON files next to the managed profiles.
public struct InstallIdentity: Codable, Equatable, Identifiable {
    public let installId: String
    public let orgSlug: String
    public let userId: String
    public let userEmail: String
    public let serverURL: URL
    public let enrolledAt: Date
    public var deviceName: String

    public var id: String { installId }
}

public enum InstallIdentityError: Error {
    case keychainFailure(OSStatus, String)
    case notFound
    case invalidState(String)
}

public enum InstallIdentityStore {
    private static let service = "io.bromure.app.managed-install"
    private static let x25519PrivKey = "x25519-private"
    private static let installTokenPrefix = "install-token-"

    // MARK: - Metadata persistence

    /// Directory holding one `install-<installId>.json` per enrollment.
    private static var installsDir: URL {
        let base = VMConfig.defaultStorageDirectory
        let dir = base.appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("installs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyIfNeeded()
        return dir
    }

    private static var legacyMetadataURL: URL {
        VMConfig.defaultStorageDirectory
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("install.json")
    }

    private static func metadataURL(for installId: String) -> URL {
        let safe = sanitizedInstallId(installId)
        return installsDir.appendingPathComponent("install-\(safe).json")
    }

    /// Only [A-Za-z0-9_.-] — guards the filename against path traversal even
    /// though the installId is server-issued.
    private static func sanitizedInstallId(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// Migration: v1 stored a single `install.json` with its install token at
    /// Keychain account `install-token`. On first access of the new store,
    /// rename the file and keychain entry to the multi-install layout.
    private static var migrationRan = false
    private static func migrateLegacyIfNeeded() {
        guard !migrationRan else { return }
        migrationRan = true
        let fm = FileManager.default
        let legacy = legacyMetadataURL
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard let data = try? Data(contentsOf: legacy) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let identity = try? decoder.decode(InstallIdentity.self, from: data) else { return }
        let newURL = installsDir.appendingPathComponent(
            "install-\(sanitizedInstallId(identity.installId)).json")
        try? data.write(to: newURL, options: .atomic)
        try? fm.removeItem(at: legacy)
        if let legacyToken = readKeychain(account: "install-token") {
            try? storeKeychain(account: installTokenPrefix + identity.installId, data: legacyToken)
            deleteKeychain(account: "install-token")
        }
    }

    /// Load all persisted install identities (may be empty).
    public static func loadAll() -> [InstallIdentity] {
        let fm = FileManager.default
        let dir = installsDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [InstallIdentity] = []
        for name in names {
            guard name.hasPrefix("install-"), name.hasSuffix(".json") else { continue }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let identity = try? decoder.decode(InstallIdentity.self, from: data)
            else { continue }
            out.append(identity)
        }
        return out.sorted { $0.enrolledAt < $1.enrolledAt }
    }

    /// Load a specific enrollment by install id.
    public static func load(installId: String) -> InstallIdentity? {
        let url = metadataURL(for: installId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallIdentity.self, from: data)
    }

    /// Back-compat accessor: returns the earliest-enrolled install, if any.
    /// New code should prefer `loadAll()`.
    public static func load() -> InstallIdentity? {
        loadAll().first
    }

    public static func save(_ identity: InstallIdentity) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identity)
        try data.write(to: metadataURL(for: identity.installId), options: .atomic)
    }

    /// Remove one enrollment's metadata + bearer token. X25519 key stays
    /// (shared across remaining enrollments).
    public static func remove(installId: String) {
        try? FileManager.default.removeItem(at: metadataURL(for: installId))
        deleteKeychain(account: installTokenPrefix + installId)
    }

    /// Wipe every enrollment, keychain tokens, and the shared X25519 key.
    public static func destroy() {
        for identity in loadAll() {
            deleteKeychain(account: installTokenPrefix + identity.installId)
        }
        try? FileManager.default.removeItem(at: installsDir)
        deleteKeychain(account: x25519PrivKey)
        // Clean up any legacy artefacts that somehow survived migration.
        try? FileManager.default.removeItem(at: legacyMetadataURL)
        deleteKeychain(account: "install-token")
    }

    // MARK: - X25519 key (shared across enrollments)

    /// Return the existing X25519 keypair, generating + persisting one on first call.
    public static func ensureX25519Key() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = readKeychain(account: x25519PrivKey) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        try storeKeychain(account: x25519PrivKey, data: fresh.rawRepresentation)
        return fresh
    }

    public static func loadX25519Key() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let data = readKeychain(account: x25519PrivKey) else {
            throw InstallIdentityError.notFound
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Install bearer token (one per enrollment)

    public static func storeInstallToken(_ token: String, for installId: String) throws {
        try storeKeychain(account: installTokenPrefix + installId, data: Data(token.utf8))
    }

    public static func loadInstallToken(for installId: String) -> String? {
        guard let data = readKeychain(account: installTokenPrefix + installId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Keychain wrappers

    private static func storeKeychain(account: String, data: Data) throws {
        deleteKeychain(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw InstallIdentityError.keychainFailure(status, "store \(account)")
        }
    }

    private static func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public extension Curve25519.KeyAgreement.PrivateKey {
    /// 32-byte hex encoding of the public key — the wire format we use with the
    /// server for sealed-box delivery.
    var publicKeyHex: String {
        publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }
}
