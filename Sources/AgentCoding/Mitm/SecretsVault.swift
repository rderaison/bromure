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

        if let existing = try fetchFromKeychain() {
            cachedKey = existing
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try storeInKeychain(fresh)
        cachedKey = fresh
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
