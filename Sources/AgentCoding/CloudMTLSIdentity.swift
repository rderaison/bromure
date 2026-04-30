import Foundation
import Security
import _CryptoExtras
import SandboxEngine

/// Builds and caches a `SecIdentity` from BAC's stored leaf cert + RSA
/// private key for use as the client identity during mTLS handshakes
/// against the analytics service.
///
/// Mirrors `AnalyticsMTLSIdentity` (the Web equivalent in SandboxEngine):
/// the cert + key are packaged into a PKCS#12 blob entirely in memory by
/// `PKCS12Builder`, handed to `SecPKCS12Import` *without*
/// `kSecImportExportKeychain`, so the resulting identity stays in-memory
/// only — no Keychain Access entry, no unlock prompt, no risk of an
/// unrelated identity being picked up by a system-wide cert search.
///
/// The identity is cached for the process lifetime; `purge()` is called
/// from leaf rotation (`BACEnrollment.fetchLeafCert`) and from
/// `BACEnrollment.unenroll` so a stale identity can't be served on the
/// next handshake.
public enum BACMTLSIdentity {
    public enum Error: Swift.Error, LocalizedError {
        case missingMaterial
        case invalidCertificate
        case invalidPrivateKey
        case pkcs12ImportFailed(OSStatus)
        case identityExtractionFailed

        public var errorDescription: String? {
            switch self {
            case .missingMaterial: return "BAC leaf cert or private key not found on disk"
            case .invalidCertificate: return "Stored leaf cert is not a valid PEM"
            case .invalidPrivateKey: return "Stored leaf private key could not be parsed"
            case .pkcs12ImportFailed(let st): return "SecPKCS12Import failed (OSStatus \(st))"
            case .identityExtractionFailed: return "PKCS#12 import returned no SecIdentity"
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cache: SecIdentity?

    /// Returns the current `SecIdentity`, building (and caching) it on
    /// first use. Safe to call from multiple threads.
    public static func current() throws -> SecIdentity {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache { return cached }
        let id = try buildIdentity()
        cache = id
        return id
    }

    /// Drop the cached identity. Call after a leaf rotation, after
    /// `BACEnrollmentStore.destroy()`, or on any other event that
    /// changes the on-disk material.
    public static func purge() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = nil
    }

    private static func buildIdentity() throws -> SecIdentity {
        guard let certPem = BACEnrollmentStore.loadLeafCertPem(),
              let serialHex = BACEnrollmentStore.loadLeafSerial(),
              let pkcs1Bytes = BACEnrollmentStore.loadLeafPrivateKey(serialHex: serialHex)
        else { throw Error.missingMaterial }
        guard let certDer = derFromPEM(certPem, type: "CERTIFICATE") else {
            throw Error.invalidCertificate
        }

        // We store the key as PKCS#1 RSAPrivateKey (the
        // `_RSA.Signing.PrivateKey.derRepresentation` form), but
        // SecPKCS12Import only synthesizes a SecIdentity from a PKCS#8
        // PrivateKeyInfo plaintext inside a shrouded key bag. Convert
        // here at use-time so we don't need a storage-format migration.
        let priv: _RSA.Signing.PrivateKey
        do {
            priv = try _RSA.Signing.PrivateKey(derRepresentation: pkcs1Bytes)
        } catch {
            throw Error.invalidPrivateKey
        }
        let pkcs8 = priv.pkcs8DERRepresentation

        // Random per-invocation password — never leaves this function.
        // Confidentiality is incidental (the blob is consumed in-process
        // and discarded), but the shrouded-key-bag layout that triggers
        // identity synthesis requires *some* password.
        var pwdBytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, pwdBytes.count, &pwdBytes)
        let password = Data(pwdBytes).base64EncodedString()

        let pfx = PKCS12Builder.build(
            certDER: certDer, privateKeyDER: pkcs8, password: password,
        )

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(pfx as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]] else {
            throw Error.pkcs12ImportFailed(status)
        }
        guard let entry = arr.first,
              let identityAny = entry[kSecImportItemIdentity as String]
        else { throw Error.identityExtractionFailed }
        return identityAny as! SecIdentity
    }

    private static func derFromPEM(_ pem: String, type: String) -> Data? {
        let begin = "-----BEGIN \(type)-----"
        let end = "-----END \(type)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex)
        else { return nil }
        let b64 = pem[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(b64))
    }
}
