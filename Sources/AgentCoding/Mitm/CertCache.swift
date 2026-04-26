import Foundation
import X509
import Crypto
import SwiftASN1

/// Mints + caches per-host TLS leaf certificates signed by the Bromure
/// CA. Same host repeated → cached SecIdentity (no re-mint). Different
/// host → fresh cert with that host as the CN + SAN.
public final class CertCache: @unchecked Sendable {
    private let ca: BromureCA
    private var cache: [String: SecIdentity] = [:]
    private let lock = NSLock()

    public init(ca: BromureCA) {
        self.ca = ca
    }

    /// SecIdentity = cert + private key, ready for SecureTransport's
    /// SSLSetCertificate. Generated lazily, cached for the process
    /// lifetime.
    public func identity(for host: String) throws -> SecIdentity {
        lock.lock()
        if let id = cache[host] {
            lock.unlock()
            return id
        }
        lock.unlock()

        let id = try mint(for: host)
        lock.lock()
        cache[host] = id
        lock.unlock()
        return id
    }

    private func mint(for host: String) throws -> SecIdentity {
        // Per-host EC key. Sharing a single key across leaves would let
        // a leaked leaf re-impersonate every host; per-host keys keep
        // blast radius scoped to the leaked host.
        let leafKey = P256.Signing.PrivateKey()
        let leafPub = Certificate.PublicKey(leafKey.publicKey)

        let subject = try DistinguishedName {
            CommonName(host)
        }

        let san: GeneralName = Self.isIPAddress(host)
            ? .ipAddress(ASN1OctetString(contentBytes: ArraySlice(Self.ipBytes(host))))
            : .dnsName(host)

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([san])
        }

        let now = Date()
        let serial = Certificate.SerialNumber(bytes: Array(randomBytes(20)))
        let cert = try Certificate(
            version: .v3,
            serialNumber: serial,
            publicKey: leafPub,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter:  now.addingTimeInterval(365 * 86_400),
            issuer: ca.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(ca.privateKey)
        )

        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let derBytes = Data(serializer.serializedBytes)
        guard let secCert = SecCertificateCreateWithData(nil, derBytes as CFData) else {
            throw MitmError.certEncodingFailed
        }

        let attrs: [CFString: Any] = [
            kSecAttrKeyType:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass:      kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            leafKey.x963Representation as CFData,
            attrs as CFDictionary,
            &keyError
        ) else {
            throw MitmError.keyImportFailed("\(String(describing: keyError?.takeRetainedValue()))")
        }

        // SecIdentityCreate is a private SPI on macOS — present in the
        // Security framework binary, just not in the public headers.
        // It's the supported way to bind a SecCertificate to a SecKey
        // that isn't sitting in any keychain. Vapor / NIO-Transport-
        // Services / Cryptography-related projects all rely on it.
        guard let identity = bromure_SecIdentityCreate(nil, secCert, secKey) else {
            throw MitmError.identityCreationFailed
        }
        return identity.takeRetainedValue()
    }

    private static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return true }
        return false
    }

    private static func ipBytes(_ s: String) -> [UInt8] {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return []
    }
}

// MARK: - SecIdentityCreate SPI bridge

// Declared with @_silgen_name so the linker resolves it against the
// Security framework's existing symbol. The function is part of
// Apple's Security.framework but only declared in SecIdentityPriv.h
// (the SPI header), which Apple doesn't ship with the public SDK.
//
// Signature lifted from <Security/SecIdentityPriv.h> in the open-source
// Security project at opensource.apple.com.
@_silgen_name("SecIdentityCreate")
private func bromure_SecIdentityCreate(
    _ allocator: CFAllocator?,
    _ certificate: SecCertificate,
    _ privateKey: SecKey
) -> Unmanaged<SecIdentity>?
