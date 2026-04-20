import Foundation
import CryptoKit

/// Crypto primitives matching the server's `bromure-sealed-box-v1` format and
/// the Ed25519/canonical-JSON manifest signing scheme.
public enum ManagedBundleCrypto {
    /// Context string used in HKDF info; must match server.
    private static let context = Data("bromure-sealed-box-v1".utf8)

    /// Decrypt a sealed-box blob produced by the server:
    ///   eph_pub_raw(32) || nonce(12) || ct || tag(16)
    public static func open(sealedBoxData: Data, recipient: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard sealedBoxData.count >= 32 + 12 + 16 else {
            throw ManagedBundleError.sealedBoxTooShort
        }
        let ephPubRaw = sealedBoxData.prefix(32)
        let nonce = sealedBoxData.dropFirst(32).prefix(12)
        let ctAndTag = sealedBoxData.dropFirst(32 + 12)

        let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubRaw)
        let shared = try recipient.sharedSecretFromKeyAgreement(with: ephPub)

        let salt = ephPubRaw + recipient.publicKey.rawRepresentation
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context,
            outputByteCount: 32,
        )

        // CryptoKit expects `combined = nonce || ct || tag`.
        let combined = nonce + ctAndTag
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: aeadKey)
    }

    /// Verify an Ed25519 signature over canonicalize(manifest) using the
    /// SPKI-PEM public key produced by node's `KeyObject.export({type:'spki',
    /// format:'pem'})`.
    public static func verify(
        manifest: Any,
        signatureB64: String,
        publicKeyPem: String,
    ) throws -> Bool {
        guard let sig = Data(base64Encoded: signatureB64) else {
            throw ManagedBundleError.invalidSignatureEncoding
        }
        let key = try ed25519PublicKey(fromPEM: publicKeyPem)
        let canonical = try canonicalize(manifest)
        return key.isValidSignature(sig, for: Data(canonical.utf8))
    }

    /// Deterministic JSON — must match the server's `canonicalize()` in
    /// src/crypto/signing.js:
    /// - object keys sorted lexicographically, recursively
    /// - no whitespace between tokens
    /// - strings encoded as standard JSON escapes
    public static func canonicalize(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        // Check NSNumber FIRST — `as? Bool` matches NSNumber-wrapped 0/1,
        // which would misclassify integers coming out of JSONSerialization.
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return numberString(n)
        }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String {
            return jsonEscapeString(s)
        }
        if let arr = value as? [Any] {
            let parts = try arr.map { try canonicalize($0) }
            return "[" + parts.joined(separator: ",") + "]"
        }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted()
            let parts = try keys.map { key -> String in
                let kjson = try canonicalize(key)
                let vjson = try canonicalize(dict[key] as Any)
                return "\(kjson):\(vjson)"
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        // Fallback — attempt to round-trip via JSONSerialization.
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed],
        )
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// JSON string escaper matching Node's `JSON.stringify` byte-for-byte.
    ///
    /// Apple's `JSONSerialization` escapes `/` as `\/` (legal per RFC 8259
    /// §7, but not required). Node's `JSON.stringify` does not. Using the
    /// system serializer would make canonical output diverge across the
    /// two sides whenever a string contains `/` (very common in base64-
    /// encoded PEM bodies), breaking signature verification.
    ///
    /// Matches Node's rules:
    /// - `\b \t \n \f \r \" \\` get the short escape.
    /// - Control characters < 0x20 get `\uXXXX`.
    /// - All other code points (including non-BMP) are emitted literally;
    ///   their UTF-8 encoding in the final canonical bytes is what the
    ///   server signs.
    private static func jsonEscapeString(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":        out.append("\\\"")
            case "\\":        out.append("\\\\")
            case "\u{08}":    out.append("\\b")
            case "\u{09}":    out.append("\\t")
            case "\u{0A}":    out.append("\\n")
            case "\u{0C}":    out.append("\\f")
            case "\u{0D}":    out.append("\\r")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }

    private static func numberString(_ n: NSNumber) -> String {
        // Match JS JSON.stringify: integers as "1234", floats as default
        // representation. For our manifests we only ever emit integers and
        // floats that round-trip cleanly via the Double formatter.
        let d = n.doubleValue
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return String(Int64(d))
        }
        return String(d)
    }

    // MARK: - PEM parsing

    private static func ed25519PublicKey(fromPEM pem: String) throws -> Curve25519.Signing.PublicKey {
        let lines = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
        let b64 = lines.joined()
        guard let der = Data(base64Encoded: b64) else {
            throw ManagedBundleError.invalidPublicKey
        }
        // Node exports Ed25519 pub in 44-byte SPKI: 12-byte prefix + 32-byte key.
        guard der.count == 44 else { throw ManagedBundleError.invalidPublicKey }
        let raw = der.suffix(32)
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}

public enum ManagedBundleError: Error {
    case sealedBoxTooShort
    case invalidSignatureEncoding
    case invalidPublicKey
    case signatureInvalid
    case manifestMismatch(String)
    case assetMissing(String)
    case assetHashMismatch(String)
}
