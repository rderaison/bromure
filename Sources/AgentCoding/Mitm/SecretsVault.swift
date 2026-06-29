import Foundation
import CryptoKit
import Security

/// Per-install master key + symmetric encryption helpers for
/// at-rest secret storage. The master key is a 32-byte random AES-256
/// stored in the macOS **Data Protection Keychain** — the iOS-style
/// keychain that's app-scoped by code-signing identity and (critically)
/// never prompts the user for access. The legacy "file-based" macOS
/// keychain is what would pop the "Always Allow / Allow / Deny" dialog
/// every time the app rebuilt; DPKC sidesteps that entirely.
///
/// Wiping the keychain entry rotates the key — every existing secret
/// blob becomes unreadable, but the non-sensitive metadata in
/// profile.json is unaffected, so the user can re-enter their API keys.
public enum SecretsVault {
    /// Service tag for the master-key keychain item. Versioned so we
    /// can rotate the storage scheme without overwriting user data.
    private static let service = "io.bromure.agentic-coding.master-key"
    private static let account = "v1"

    /// In-memory cache so we hit the keychain at most once per process.
    /// Reset on app quit. SymmetricKey holds bytes in a buffer that
    /// CryptoKit zeroes on dealloc.
    private static var cachedKey: SymmetricKey?
    private static let cacheLock = NSLock()

    /// Fetch (or lazily create) the per-install master key.
    public static func masterKey() throws -> SymmetricKey {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let k = cachedKey { return k }

        // Preferred: the Data Protection Keychain (at-rest protected, no prompt).
        if let fetched = (try? fetchFromKeychain()) ?? nil {
            cachedKey = fetched
            return fetched
        }
        let fresh = SymmetricKey(size: .bits256)
        if (try? storeInKeychain(fresh)) != nil {
            cachedKey = fresh
            return fresh
        }

        // Fallback: a 0600 key file under Application Support. The Data
        // Protection Keychain is unreachable to a signed-but-not-notarized /
        // no-provisioning-profile build, which *silently* broke every at-rest
        // feature — notably trace-body capture (encrypt threw, writeBody skipped
        // the write, and the inspector showed "not captured"). The file key is
        // weaker (it sits beside the ciphertext), but it keeps the feature
        // working; a fully-provisioned release still uses the keychain.
        let key = try fileFallbackKey()
        FileHandle.standardError.write(Data(
            "[secrets] keychain unavailable — using file-backed master key (trace/secret encryption is local-key only)\n".utf8))
        cachedKey = key
        return key
    }

    /// Master key in a 0600 file under Application Support — the fallback when
    /// the keychain is unavailable.
    private static func fileFallbackKey() throws -> SymmetricKey {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("secrets-master.key")
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let bytes: Data = fresh.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        return fresh
    }

    /// Encrypt arbitrary bytes with the master key. Output is the
    /// AES-GCM "combined" form: 12-byte nonce || ciphertext || 16-byte tag.
    public static func encrypt(_ plain: Data) throws -> Data {
        let key = try masterKey()
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw VaultError.sealFailed
        }
        return combined
    }

    public static func decrypt(_ blob: Data) throws -> Data {
        let key = try masterKey()
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - Keychain plumbing

    private static func fetchFromKeychain() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:                       kSecClassGenericPassword,
            kSecAttrService:                 service,
            kSecAttrAccount:                 account,
            kSecReturnData:                  true,
            kSecMatchLimit:                  kSecMatchLimitOne,
            // CRITICAL: opt into the data-protection (iOS-style)
            // keychain on macOS so we never get the legacy "Always
            // Allow" prompt. App-scoped by signing identity; no UI.
            kSecUseDataProtectionKeychain:   true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            throw VaultError.keychain("fetch", status)
        }
        return SymmetricKey(data: data)
    }

    private static func storeInKeychain(_ key: SymmetricKey) throws {
        let data: Data = key.withUnsafeBytes { Data($0) }
        let attrs: [CFString: Any] = [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrService:               service,
            kSecAttrAccount:               account,
            kSecValueData:                 data,
            // Available after the user has unlocked the device once
            // since boot — same window the user uses bromure-ac in.
            // ThisDeviceOnly prevents iCloud sync so secrets never
            // leave this Mac.
            kSecAttrAccessible:            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            // Race: another concurrent call won. Re-fetch and use that.
            return
        }
        throw VaultError.keychain("add", status)
    }
}

public enum VaultError: Error, CustomStringConvertible {
    case keychain(String, OSStatus)
    case sealFailed

    public var description: String {
        switch self {
        case .keychain(let op, let s): return "Keychain \(op) failed (\(s))"
        case .sealFailed:              return "AES-GCM seal returned no combined output"
        }
    }
}
