import Foundation
import Crypto

/// End-to-end sealing of push payloads.
///
/// The Mac (sender) seals the rich notification content to each recipient
/// device's X25519 public key with HPKE (RFC 9180); only that device's private
/// key — held in its keychain and shared with its Notification Service
/// Extension — can open it. bromure.io and Apple only ever relay the opaque
/// blob, while the unencrypted APS payload stays a generic fallback.
///
/// Blob layout: base64( encapsulatedKey(32) || ciphertext ).
enum PushCrypto {
    private static let info = Data("bromure-push-v1".utf8)
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    private static func hexToBytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Seal `plaintext` to a recipient's X25519 public key (hex). Nil on bad key.
    static func seal(_ plaintext: Data, toPublicKeyHex hex: String) -> String? {
        guard let raw = hexToBytes(hex),
              let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              var sender = try? HPKE.Sender(recipientKey: pk, ciphersuite: suite, info: info),
              let ct = try? sender.seal(plaintext) else { return nil }
        return (sender.encapsulatedKey + ct).base64EncodedString()
    }

    /// Open a sealed blob with this device's X25519 private key. Nil on any
    /// failure (wrong key, corrupt blob) — the caller falls back to the generic
    /// notification.
    static func open(_ blobBase64: String, privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard let blob = Data(base64Encoded: blobBase64), blob.count > 32 else { return nil }
        let encapsulated = Data(blob.prefix(32))
        let ciphertext = blob.dropFirst(32)
        guard var recipient = try? HPKE.Recipient(privateKey: privateKey, ciphersuite: suite,
                                                  info: info, encapsulatedKey: encapsulated)
        else { return nil }
        return try? recipient.open(ciphertext)
    }
}
