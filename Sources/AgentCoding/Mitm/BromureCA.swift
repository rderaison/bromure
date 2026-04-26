import Foundation
import X509
import Crypto
import SwiftASN1
import _CryptoExtras

/// The Bromure Agentic Coding root CA. One per host, one per app
/// install — every per-profile leaf cert minted on the fly is signed by
/// this. The matching public certificate is mounted into every VM's
/// trust store at session boot, so guest TLS clients accept our forged
/// per-host leaves without complaint.
///
/// **Storage**: `~/Library/Application Support/BromureAC/ca/{cert.pem,
/// key.pem}` with mode 0600 on the key. Plain files for now — keychain
/// can come later if we ever sign across users.
///
/// **Rotation**: nuking the dir regenerates on the next launch and
/// every VM re-installs the new public cert from the meta share. Cheap.
public final class BromureCA: @unchecked Sendable {
    public let certificate: Certificate
    public let privateKey: P256.Signing.PrivateKey
    /// PEM-encoded public certificate, ready to drop in the meta share
    /// for the in-VM `update-ca-certificates` install step.
    public let certificatePEM: String

    /// SecCertificate / SecKey wrappers for use with Apple's security
    /// stack (SecureTransport accepts a SecIdentity built from these).
    public let secCertificate: SecCertificate
    public let secPrivateKey: SecKey

    private init(certificate: Certificate,
                 privateKey: P256.Signing.PrivateKey,
                 certificatePEM: String,
                 secCertificate: SecCertificate,
                 secPrivateKey: SecKey) {
        self.certificate = certificate
        self.privateKey = privateKey
        self.certificatePEM = certificatePEM
        self.secCertificate = secCertificate
        self.secPrivateKey = secPrivateKey
    }

    /// Load from disk if present; otherwise mint a fresh one and persist.
    public static func loadOrCreate(at directory: URL) throws -> BromureCA {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent("cert.pem")
        let keyURL  = directory.appendingPathComponent("key.pem")

        if fm.fileExists(atPath: certURL.path), fm.fileExists(atPath: keyURL.path) {
            do {
                return try load(certURL: certURL, keyURL: keyURL)
            } catch {
                // Corrupt CA on disk — start fresh rather than hanging.
                FileHandle.standardError.write(Data(
                    "[mitm] CA on disk unreadable (\(error)), regenerating\n".utf8))
                try? fm.removeItem(at: certURL)
                try? fm.removeItem(at: keyURL)
            }
        }
        return try mint(certURL: certURL, keyURL: keyURL)
    }

    private static func load(certURL: URL, keyURL: URL) throws -> BromureCA {
        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        let keyPEM  = try String(contentsOf: keyURL,  encoding: .utf8)
        let cert = try Certificate(pemEncoded: certPEM)
        let key  = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)

        let (sec, secKey) = try makeSecPair(cert: cert, key: key)
        return BromureCA(certificate: cert,
                         privateKey: key,
                         certificatePEM: certPEM,
                         secCertificate: sec,
                         secPrivateKey: secKey)
    }

    private static func mint(certURL: URL, keyURL: URL) throws -> BromureCA {
        let key = P256.Signing.PrivateKey()
        let publicKey = try Certificate.PublicKey(key.publicKey)

        // Distinguished name for the CA. Showing up as "Bromure
        // Agentic Coding Root CA" in the trust store is friendlier than
        // a random hex string when the user inspects.
        let subject = try DistinguishedName {
            CommonName("Bromure Agentic Coding Root CA")
            OrganizationName("Bromure")
        }

        let now = Date()
        let notValidBefore = now.addingTimeInterval(-60)         // 1 min ago
        let notValidAfter  = now.addingTimeInterval(10 * 365 * 86_400) // 10 years

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(keyIdentifier: ArraySlice(SHA256.hash(data: Array(publicKey.subjectPublicKeyInfoBytes))))
        }

        let signerKey = Certificate.PrivateKey(key)
        let serial = Certificate.SerialNumber(bytes: Array(randomBytes(20)))
        let cert = try Certificate(
            version: .v3,
            serialNumber: serial,
            publicKey: publicKey,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: signerKey
        )

        let certPEM = try cert.serializeAsPEM().pemString
        let keyPEM  = key.pemRepresentation

        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        try keyPEM.write(to: keyURL,  atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: keyURL.path)

        let (sec, secKey) = try makeSecPair(cert: cert, key: key)
        return BromureCA(certificate: cert,
                         privateKey: key,
                         certificatePEM: certPEM,
                         secCertificate: sec,
                         secPrivateKey: secKey)
    }

    /// Convert the swift-certificates `Certificate` + crypto `PrivateKey`
    /// into Apple-`Sec*` references. SecureTransport / SecIdentity want
    /// these specific types for the server-side TLS handshake.
    static func makeSecPair(cert: Certificate, key: P256.Signing.PrivateKey)
        throws -> (SecCertificate, SecKey)
    {
        // DER-encode the certificate.
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let derBytes = Data(serializer.serializedBytes)
        guard let secCert = SecCertificateCreateWithData(nil, derBytes as CFData) else {
            throw MitmError.certEncodingFailed
        }

        // Build a SecKey from the EC private key. Path is x9.63 for
        // P256 — that's the format `SecKeyCreateWithData` expects for
        // EC private keys (`kSecAttrKeyTypeECSECPrimeRandom`).
        let x963 = key.x963Representation
        let attrs: [CFString: Any] = [
            kSecAttrKeyType:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass:       kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits:  256
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(x963 as CFData, attrs as CFDictionary, &error) else {
            throw MitmError.keyImportFailed("\(error?.takeRetainedValue() as Error?)")
        }
        return (secCert, secKey)
    }
}

// MARK: - Random helper

/// Cryptographic random bytes via SystemRandomNumberGenerator. Only
/// used for cert serial numbers — collisions don't matter for security
/// here since the CA is single-tenant, but uniqueness keeps clients
/// from caching the wrong cert.
@inline(__always)
func randomBytes(_ n: Int) -> [UInt8] {
    var rng = SystemRandomNumberGenerator()
    return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

public enum MitmError: Error, CustomStringConvertible {
    case certEncodingFailed
    case keyImportFailed(String)
    case identityCreationFailed
    case tlsHandshakeFailed(OSStatus)
    case tlsReadFailed(OSStatus)
    case tlsWriteFailed(OSStatus)
    case malformedHTTPRequest
    case unexpectedTermination
    case upstreamFailed(String)

    public var description: String {
        switch self {
        case .certEncodingFailed:        return "MITM: failed to DER-encode certificate"
        case .keyImportFailed(let s):    return "MITM: failed to import private key (\(s))"
        case .identityCreationFailed:    return "MITM: failed to create SecIdentity"
        case .tlsHandshakeFailed(let s): return "MITM: TLS handshake failed (\(s))"
        case .tlsReadFailed(let s):      return "MITM: TLS read failed (\(s))"
        case .tlsWriteFailed(let s):     return "MITM: TLS write failed (\(s))"
        case .malformedHTTPRequest:      return "MITM: malformed HTTP request"
        case .unexpectedTermination:     return "MITM: connection terminated mid-stream"
        case .upstreamFailed(let s):     return "MITM: upstream request failed (\(s))"
        }
    }
}
