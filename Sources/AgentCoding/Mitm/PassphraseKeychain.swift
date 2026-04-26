import Foundation
import Security

/// Thin wrapper around Apple's Security framework for storing
/// per-(profile, key-file) ssh-key passphrases. Uses
/// `kSecClassGenericPassword` items scoped to bromure-ac's bundle so
/// ad-hoc-signed builds can read/write their own slot without prompts
/// for the user's main keychain.
enum PassphraseKeychain {
    /// Service tag — unique to bromure AC so we don't collide with
    /// anything else the user has in their keychain.
    private static let service = "io.bromure.agentic-coding.ssh-key-passphrases"

    /// Account = "<profile UUID>/<filename>" so multiple imported
    /// keys per profile coexist and deletes are scoped.
    private static func account(profileID: UUID, filename: String) -> String {
        "\(profileID.uuidString)/\(filename)"
    }

    static func set(passphrase: String, profileID: UUID, filename: String) throws {
        let account = account(profileID: profileID, filename: filename)
        guard let data = passphrase.data(using: .utf8) else { return }

        // Try update-then-add. SecItemUpdate fails if the item doesn't
        // exist; we then fall through to SecItemAdd.
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.failed("update", updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.failed("add", addStatus)
        }
    }

    static func get(profileID: UUID, filename: String) -> String? {
        let account = account(profileID: profileID, filename: filename)
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    static func delete(profileID: UUID, filename: String) {
        let account = account(profileID: profileID, filename: filename)
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error, CustomStringConvertible {
        case failed(String, OSStatus)
        var description: String {
            switch self {
            case .failed(let op, let s): return "Keychain \(op) failed (\(s))"
            }
        }
    }
}
