import Foundation
import CryptoKit
import Security

/// Per-machine install identity for the managed-profiles control plane.
///
/// Holds:
///   - an X25519 keypair used to receive sealed-box bundle payloads,
///   - the install bearer token returned at enrollment,
///   - metadata linking us to an org and a managed profile.
///
/// All secrets live in the macOS Keychain (WhenUnlockedThisDeviceOnly).
/// Plain metadata lives in a JSON file next to the managed profiles.
public struct InstallIdentity: Codable, Equatable {
    public let installId: String
    public let orgSlug: String
    public let userId: String
    public let userEmail: String
    public let serverURL: URL
    public let enrolledAt: Date
    public var deviceName: String
}

public enum InstallIdentityError: Error {
    case keychainFailure(OSStatus, String)
    case notFound
    case invalidState(String)
}

public enum InstallIdentityStore {
    private static let service = "io.bromure.app.managed-install"
    private static let x25519PrivKey = "x25519-private"
    private static let installTokenKey = "install-token"

    // MARK: - Metadata persistence

    private static var metadataURL: URL {
        let base = VMConfig.defaultStorageDirectory
        let dir = base.appendingPathComponent("managed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("install.json")
    }

    /// Load the persisted install identity, if any.
    public static func load() -> InstallIdentity? {
        let url = metadataURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallIdentity.self, from: data)
    }

    public static func save(_ identity: InstallIdentity) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identity)
        try data.write(to: metadataURL, options: .atomic)
    }

    /// Wipe the install identity, Keychain entries, and on-disk metadata.
    public static func destroy() {
        try? FileManager.default.removeItem(at: metadataURL)
        deleteKeychain(account: x25519PrivKey)
        deleteKeychain(account: installTokenKey)
    }

    // MARK: - X25519 key

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

    // MARK: - Install bearer token

    public static func storeInstallToken(_ token: String) throws {
        try storeKeychain(account: installTokenKey, data: Data(token.utf8))
    }

    public static func loadInstallToken() -> String? {
        guard let data = readKeychain(account: installTokenKey) else { return nil }
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
