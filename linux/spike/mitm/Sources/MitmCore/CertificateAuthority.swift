import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOSSL
import SwiftASN1
import X509

/// The interception CA and its leaves: ECDSA P-256, a leaf per host minted
/// on demand, SANs from the SNI (DNS name or IP), a bounded LRU of ready
/// NIOSSLContexts keyed by (host, ALPN).
public final class CertificateAuthority: Sendable {
    public let certificate: Certificate
    public let privateKey: P256.Signing.PrivateKey
    let caNIO: NIOSSLCertificate
    private let skid: SubjectKeyIdentifier
    private let cache: LRU<String, NIOSSLContext>
    private let counters = NIOLockedValueBox<(minted: Int, hits: Int)>((0, 0))

    /// A fresh CA, valid for `days`.
    public static func generate(commonName: String = "Bromure Spike CA", days: Int = 365,
                                cacheCapacity: Int = 1024) throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(commonName); OrganizationName("Bromure") }
        let ski = SubjectKeyIdentifier(hash: .init(key.publicKey))
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + Double(days) * 86_400,
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                ski
            },
            issuerPrivateKey: .init(key))
        return try CertificateAuthority(certificate: cert, privateKey: key, cacheCapacity: cacheCapacity)
    }

    /// Loads a CA from PEM files.
    public static func load(certPEM: String, keyPEM: String, cacheCapacity: Int = 1024) throws -> CertificateAuthority {
        try CertificateAuthority(certificate: Certificate(pemEncoded: certPEM),
                                 privateKey: P256.Signing.PrivateKey(pemRepresentation: keyPEM),
                                 cacheCapacity: cacheCapacity)
    }

    init(certificate: Certificate, privateKey: P256.Signing.PrivateKey, cacheCapacity: Int) throws {
        self.certificate = certificate
        self.privateKey = privateKey
        var ser = DER.Serializer()
        try ser.serialize(certificate)
        caNIO = try NIOSSLCertificate(bytes: ser.serializedBytes, format: .der)
        skid = try certificate.extensions.subjectKeyIdentifier ?? SubjectKeyIdentifier(hash: .init(privateKey.publicKey))
        cache = LRU(capacity: cacheCapacity)
    }

    public var certificatePEM: String { (try? certificate.serializeAsPEM().pemString) ?? "" }
    public var keyPEM: String { privateKey.pemRepresentation }
    public var minted: Int { counters.withLockedValue { $0.minted } }
    public var cacheHits: Int { counters.withLockedValue { $0.hits } }

    /// A server context for `host` advertising exactly `alpn` (what upstream
    /// negotiated), minting the leaf on a miss.
    public func serverContext(host: String, alpn: [String]) throws -> NIOSSLContext {
        let key = host + "|" + alpn.joined(separator: ",")
        if let c = cache.get(key) {
            counters.withLockedValue { $0.hits += 1 }
            return c
        }
        let (leaf, leafKey) = try mintLeaf(host: host)
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leaf), .certificate(caNIO)], privateKey: .privateKey(leafKey))
        cfg.applicationProtocols = alpn
        let ctx = try NIOSSLContext(configuration: cfg)
        cache.put(key, ctx)
        counters.withLockedValue { $0.minted += 1 }
        return ctx
    }

    /// A leaf for `host`: its own P-256 key, 7 days, serverAuth, SAN = host.
    public func mintLeaf(host: String) throws -> (NIOSSLCertificate, NIOSSLPrivateKey) {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let san: GeneralName
        if let ip = IPv4Address(host) { san = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip.bytes))) }
        else { san = .dnsName(host) }
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 7 * 86_400,
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(String(host.prefix(64))) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
                AuthorityKeyIdentifier(keyIdentifier: skid.keyIdentifier)
            },
            issuerPrivateKey: .init(privateKey))
        var ser = DER.Serializer()
        try ser.serialize(leaf)
        return (try NIOSSLCertificate(bytes: ser.serializedBytes, format: .der),
                try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem))
    }
}

/// Dotted-quad parsing for IP SANs.
struct IPv4Address {
    let bytes: [UInt8]
    init?(_ s: String) {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var b: [UInt8] = []
        for x in p { guard let v = UInt8(x) else { return nil }; b.append(v) }
        bytes = b
    }
}

/// A small thread-safe LRU.
final class LRU<K: Hashable & Sendable, V: Sendable>: Sendable {
    private let box: NIOLockedValueBox<(map: [K: (V, UInt64)], tick: UInt64)>
    let capacity: Int
    init(capacity: Int) {
        self.capacity = capacity
        box = .init(([:], 0))
    }
    func get(_ k: K) -> V? {
        box.withLockedValue { s in
            guard let (v, _) = s.map[k] else { return nil }
            s.tick += 1
            s.map[k] = (v, s.tick)
            return v
        }
    }
    func put(_ k: K, _ v: V) {
        box.withLockedValue { s in
            s.tick += 1
            s.map[k] = (v, s.tick)
            if s.map.count > capacity, let oldest = s.map.min(by: { $0.value.1 < $1.value.1 })?.key {
                s.map.removeValue(forKey: oldest)
            }
        }
    }
    var count: Int { box.withLockedValue { $0.map.count } }
}
