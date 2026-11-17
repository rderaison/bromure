import Foundation
import Testing
import X509
import SwiftASN1
@testable import bromure_ac

/// Minted leaves pass strict X.509 verification: Python 3.13+ verifies
/// with VERIFY_X509_STRICT, which refuses a leaf without an Authority Key
/// Identifier ("Missing Authority Key Identifier").
@Suite("MITM leaf certificates")
struct MitmLeafCertTests {
    private func leaf(for host: String) throws -> (Certificate, BromureCA) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-ca-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try BromureCA.loadOrCreate(at: dir)
        let identity = try CertCache(ca: ca).identity(for: host)
        var secCert: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &secCert) == errSecSuccess)
        let der = try #require(secCert.map { SecCertificateCopyData($0) as Data })
        let cert = try Certificate(derEncoded: Array(der))
        if let out = ProcessInfo.processInfo.environment["BROMURE_DUMP_LEAF_DIR"] {
            try ca.certificatePEM.write(toFile: out + "/ca.pem", atomically: true, encoding: .utf8)
            try cert.serializeAsPEM().pemString.write(toFile: out + "/leaf-\(host).pem",
                                                      atomically: true, encoding: .utf8)
        }
        return (cert, ca)
    }

    @Test("A leaf's Authority Key Identifier is the CA's Subject Key Identifier")
    func authorityKeyID() throws {
        let (cert, ca) = try leaf(for: "nodejs.org")
        let caSKI = try #require(try ca.certificate.extensions.subjectKeyIdentifier)
        let aki = try #require(try cert.extensions.authorityKeyIdentifier)
        #expect(aki.keyIdentifier == caSKI.keyIdentifier)
        #expect(aki.authorityCertIssuer == nil)
        #expect(cert.issuer == ca.certificate.subject)
    }

    @Test("A leaf carries its own Subject Key Identifier and keeps its SAN and EKU")
    func leafExtensions() throws {
        let (cert, _) = try leaf(for: "10.0.0.1")
        let ski = try #require(try cert.extensions.subjectKeyIdentifier)
        #expect(ski.keyIdentifier.count == 20)
        let san = try #require(try cert.extensions.subjectAlternativeNames)
        #expect(san.count == 1)
        let eku = try #require(try cert.extensions.extendedKeyUsage)
        #expect(eku.contains(.serverAuth))
        #expect(try cert.extensions.basicConstraints == .notCertificateAuthority)
    }
}
