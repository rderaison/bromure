import Foundation
import Security
import Testing
@testable import bromure_ac

/// Finding (CWE-295): "A failed cluster-CA parse republishes a removed
/// context's CA on the bare host". The bare-host slot (the one the proxy's
/// CONNECT lookup reads) belongs to whichever `host:port` registered last.
/// A rebuild where one context's PEM failed to parse copied that slot
/// forward, so with the last writer removed the surviving context's
/// handshakes were pinned to the removed context's CA.
///
/// Finding (CWE-295): "Portless kube CA parse failure republishes another
/// context's certificate". The bare slot was also the port-less host's own
/// key, so its restore copied whatever `host:port` wrote the slot last --
/// and every lookup dropped the port, so even without a failure a
/// `host:8443` context's CA (and client certificate) answered for `host`.
/// Each endpoint now has its own key, looked up with the dialed port.
@Suite("Cluster CA: a failed parse keeps the host's own CA, not its neighbour's")
struct ClusterCARestoreTests {
    private static func selfSignedPEM(_ cn: String) throws -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=\(cn)",
                       "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return try? String(contentsOf: dir.appendingPathComponent("c.pem"), encoding: .utf8)
    }

    private static func keyPair(_ cn: String) throws -> (cert: String, key: String)? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                       "-days", "1", "-subj", "/CN=\(cn)",
                       "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard let c = try? String(contentsOf: dir.appendingPathComponent("c.pem"), encoding: .utf8),
              let k = try? String(contentsOf: dir.appendingPathComponent("k.pem"), encoding: .utf8) else { return nil }
        return (c, k)
    }

    private static func der(_ c: SecCertificate?) -> Data? { c.map { SecCertificateCopyData($0) as Data } }
    private static let broken = "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----"

    private static let h = "10.163.15.50"

    @Test("the removed context's CA isn't restored on the address; the survivor keeps its own")
    func ownCARestored() throws {
        let caA = try #require(try Self.selfSignedPEM("cluster-a"))
        let caB = try #require(try Self.selfSignedPEM("cluster-b"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        reg.replaceAll([(pem: caA, host: "\(Self.h):6443"), (pem: caB, host: "\(Self.h):8443")], for: pid)
        let a = Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid))
        let b = Self.der(reg.ca(for: Self.h, port: 8443, profileID: pid))
        #expect(a != nil && b != nil && a != b)
        #expect(reg.ca(for: Self.h, port: 443, profileID: pid) == nil)   // no context there

        // :8443 removed; :6443's PEM is now unparseable.
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443")], for: pid)
        #expect(Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid)) == a)
        #expect(reg.ca(for: Self.h, port: 8443, profileID: pid) == nil)
        #expect(reg.ca(for: Self.h, port: 443, profileID: pid) == nil)
    }

    @Test("a failed host with no CA of its own stays unpinned, whatever its neighbours held")
    func noOwnCAStaysUnpinned() throws {
        let caB = try #require(try Self.selfSignedPEM("cluster-b"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        reg.replaceAll([(pem: caB, host: "\(Self.h):8443")], for: pid)
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443")], for: pid)
        for port in [443, 6443, 8443] { #expect(reg.ca(for: Self.h, port: port, profileID: pid) == nil) }
    }

    @Test("a failed neighbour's restore doesn't touch an endpoint whose PEM parsed")
    func parsedEndpointUntouched() throws {
        let caA = try #require(try Self.selfSignedPEM("cluster-a"))
        let caB = try #require(try Self.selfSignedPEM("cluster-b"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        reg.replaceAll([(pem: caA, host: "\(Self.h):6443")], for: pid)
        let a = Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid))
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443"), (pem: caB, host: "\(Self.h):8443")], for: pid)
        let b = Self.der(reg.ca(for: Self.h, port: 8443, profileID: pid))
        #expect(Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid)) == a)
        #expect(b != nil && b != a)
    }

    @Test("every PEM on an address failing: each endpoint keeps its own CA, across edits")
    func allFailedKeepOwn() throws {
        let caA = try #require(try Self.selfSignedPEM("cluster-a"))
        let caB = try #require(try Self.selfSignedPEM("cluster-b"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        reg.replaceAll([(pem: caA, host: "\(Self.h):6443"), (pem: caB, host: "\(Self.h):8443")], for: pid)
        let a = Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid))
        let b = Self.der(reg.ca(for: Self.h, port: 8443, profileID: pid))
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443"), (pem: Self.broken, host: "\(Self.h):8443")], for: pid)
        #expect(Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid)) == a)
        #expect(Self.der(reg.ca(for: Self.h, port: 8443, profileID: pid)) == b)
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443"), (pem: caB, host: "\(Self.h):8443")], for: pid)
        reg.replaceAll([(pem: Self.broken, host: "\(Self.h):6443"), (pem: Self.broken, host: "\(Self.h):8443")], for: pid)
        #expect(Self.der(reg.ca(for: Self.h, port: 6443, profileID: pid)) == a)
        #expect(Self.der(reg.ca(for: Self.h, port: 8443, profileID: pid)) == b)
    }

    @Test("the finding's sequence: a port-less host keeps its own CA, never the removed :8443's")
    func portless() throws {
        let caA = try #require(try Self.selfSignedPEM("cluster-a"))
        let caB = try #require(try Self.selfSignedPEM("cluster-b"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        // https://k8s.example.com (CA-A), then https://k8s.example.com:8443 (CA-B).
        reg.replaceAll([(pem: caA, host: "k8s.example.com"), (pem: caB, host: "k8s.example.com:8443")], for: pid)
        let a = Self.der(reg.ca(for: "k8s.example.com", port: 443, profileID: pid))
        let b = Self.der(reg.ca(for: "k8s.example.com", port: 8443, profileID: pid))
        // Both live: each endpoint is pinned to its own, whichever came last.
        #expect(a != nil && b != nil && a != b)
        // :8443 dropped, the port-less PEM no longer parses.
        reg.replaceAll([(pem: Self.broken, host: "k8s.example.com")], for: pid)
        #expect(Self.der(reg.ca(for: "k8s.example.com", port: 443, profileID: pid)) == a)
        #expect(reg.ca(for: "k8s.example.com", port: 8443, profileID: pid) == nil)
        // Never had one: stays unpinned.
        let fresh = UUID()
        reg.replaceAll([(pem: caB, host: "k8s.example.com:8443")], for: fresh)
        reg.replaceAll([(pem: Self.broken, host: "k8s.example.com")], for: fresh)
        #expect(reg.ca(for: "k8s.example.com", port: 443, profileID: fresh) == nil)
    }

    @Test("an explicit :443 is the port-less endpoint")
    func explicit443() throws {
        let caA = try #require(try Self.selfSignedPEM("cluster-a"))
        let reg = ClusterCATrustRegistry(), pid = UUID()
        reg.replaceAll([(pem: caA, host: "K8S.example.com:443")], for: pid)
        #expect(reg.ca(for: "k8s.example.com", port: 443, profileID: pid) != nil)
        #expect(endpointKey("k8s.example.com:443") == endpointKey(host: "k8s.example.com", port: 443))
        #expect(endpointKey(host: "k8s.example.com", port: 6443) == "k8s.example.com:6443")
    }

    @Test("client certificates: each endpoint presents its own, never another port's")
    @MainActor
    func identitiesPerEndpoint() throws {
        let x = try #require(try Self.keyPair("user-x")), y = try #require(try Self.keyPair("user-y"))
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.kubeconfigs = [KubeconfigEntry(name: "x", serverURL: "https://k8s.example.com", auth: .clientCert(certPEM: x.cert, keyPEM: x.key)),
                         KubeconfigEntry(name: "y", serverURL: "https://k8s.example.com:8443", auth: .clientCert(certPEM: y.cert, keyPEM: y.key))]
        let ids = ClientIdentityRegistry(), cas = ClusterCATrustRegistry(), poller = ExecCredentialPoller(), pid = UUID()
        let mat = KubeconfigMaterializer().materialize(profile: p, bromureCAPEM: "PEM")
        MitmEngine.applyKubeMaterial(mat, profileID: pid, identities: ids, clusterCAs: cas, poller: poller,
                                     swapper: TokenSwapper(consent: ConsentBroker()))
        func subject(_ port: Int) -> String? {
            guard let id = ids.identity(for: "k8s.example.com", port: port, profileID: pid) else { return nil }
            var cert: SecCertificate?
            SecIdentityCopyCertificate(id, &cert)
            return cert.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        }
        #expect(subject(443) == "user-x")
        #expect(subject(8443) == "user-y")
        #expect(subject(6443) == nil)
    }
}
