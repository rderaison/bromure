import Foundation
#if canImport(Security)
import Security
#endif

/// Stores and retrieves VPN credentials in the macOS Keychain.
///
/// Follows the same pattern as ``ProfileDisk`` for LUKS keys.
/// Each credential is identified by a profile UUID and a key name
/// (e.g. "wg-config", "ikev2-password", "proxy-password").
public enum VPNKeychain {
    private static let service = "io.bromure.app.vpn"

    /// Known credential keys.
    public static let wgConfig = "wg-config"
    public static let proxyPassword = "proxy-password"
    public static let ikev2Password = "ikev2-password"
    public static let ikev2PSK = "ikev2-psk"
    public static let ikev2Cert = "ikev2-cert"
    public static let ikev2CertPass = "ikev2-cert-pass"
    public static let openVPNConfig = "openvpn-config"
    public static let openVPNPassword = "openvpn-password"

    /// Store a secret for a profile. Overwrites any existing value.
    public static func store(profileID: UUID, key: String, secret: String) {
        let account = "\(profileID.uuidString)-\(key)"
        #if !canImport(Security)
        // The Linux daemon's per-user secret store.
        if secret.isEmpty { BACSecretStore.delete(service: service, account: account) }
        else { try? BACSecretStore.store(service: service, account: account, data: Data(secret.utf8)) }
        #else
        // Delete existing entry (ignore errors)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !secret.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        #endif
    }

    /// Retrieve a secret for a profile. Returns nil if not found.
    public static func retrieve(profileID: UUID, key: String) -> String? {
        let account = "\(profileID.uuidString)-\(key)"
        #if !canImport(Security)
        return BACSecretStore.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    /// Delete a specific secret for a profile.
    public static func delete(profileID: UUID, key: String) {
        let account = "\(profileID.uuidString)-\(key)"
        #if !canImport(Security)
        BACSecretStore.delete(service: service, account: account)
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    /// Delete all VPN secrets for a profile.
    public static func deleteAll(profileID: UUID) {
        let allKeys = [wgConfig, proxyPassword, ikev2Password, ikev2PSK, ikev2Cert, ikev2CertPass, openVPNConfig, openVPNPassword]
        for key in allKeys {
            delete(profileID: profileID, key: key)
        }
    }
}
