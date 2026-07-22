import Foundation
import Crypto
import Security

/// The device's X25519 push key. The private key lives in the **shared**
/// keychain access group so the Notification Service Extension (a separate
/// process) can open sealed payloads with it; the public key is registered with
/// the account so the Mac can seal to it. Generated once and reused.
enum PushKeypair {
    private static let service = "io.bromure.remote.push"
    private static let account = "x25519"
    /// Shared with the NSE via the `keychain-access-groups` entitlement
    /// ($(AppIdentifierPrefix)io.bromure.remote → this team prefix).
    private static let accessGroup = "W3RD8G85BC.io.bromure.remote"

    /// This device's push public key (hex, 64 chars) — nil only if the keychain
    /// is unavailable.
    static var publicKeyHex: String? {
        privateKey()?.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// The device's private key, loading it or generating + storing one.
    static func privateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        if let existing = load() { return existing }
        let key = Curve25519.KeyAgreement.PrivateKey()
        return store(key) ? key : nil
    }

    private static func load() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    @discardableResult
    private static func store(_ key: Curve25519.KeyAgreement.PrivateKey) -> Bool {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecValueData: key.rawRepresentation,
            // After first unlock so the NSE can open pushes on the lock screen.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}
