import Foundation
import Testing
import Security
@testable import bromure_ac

/// Covers the upstream TLS material on the HTTP-upgrade fast path.
///
/// `kubectl exec` upgrades to SPDY/3.1 (or v5.channel.k8s.io over
/// WebSocket), which bypasses URLSession — and therefore bypasses
/// `ClientCertChallengeDelegate`, the only place the profile's client
/// identity and pinned cluster CA used to be applied. Against a private-CA
/// API server that made the upstream handshake fail, the tunnel was dropped
/// with no HTTP response, and the guest reported "unexpected EOF".
///
/// These tests stand up an openssl server with the same shape as a k8s API
/// server — serving cert issued by a private CA, client cert required — and
/// assert that `TLSClientStream` reaches it only when handed both.
@Suite("TLSClientStream cluster pinning", .serialized)
struct TLSClientStreamPinningTests {

    // MARK: - PKI + server fixture

    /// SecPKCS12Import rejects an empty passphrase (errSecAuthFailed), so the
    /// throwaway bundle gets a real one.
    private static let p12Passphrase = "bromure-test"

    /// A throwaway PKI: private CA, a server cert for "localhost" issued by
    /// it, and a client cert issued by it.
    private struct PKI {
        let dir: URL
        var caPEM: String { try! String(contentsOf: dir.appendingPathComponent("ca.crt")) }
        var serverCert: String { dir.appendingPathComponent("server.crt").path }
        var serverKey: String { dir.appendingPathComponent("server.key").path }
        var clientP12: URL { dir.appendingPathComponent("client.p12") }
    }

    private static func run(_ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "openssl", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "failed: \(args.joined(separator: " "))"])
        }
    }

    private static func makePKI() throws -> PKI {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Private CA — the "cluster CA".
        try run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", "ca.key", "-out", "ca.crt", "-days", "2",
                 "-subj", "/CN=Test Cluster CA"], cwd: dir)

        // Server leaf for localhost, issued by the CA, with a SAN (the SSL
        // policy requires hostname binding).
        try run(["openssl", "req", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", "server.key", "-out", "server.csr",
                 "-subj", "/CN=localhost"], cwd: dir)
        let ext = dir.appendingPathComponent("server.ext")
        try "subjectAltName=DNS:localhost\n".write(to: ext, atomically: true, encoding: .utf8)
        try run(["openssl", "x509", "-req", "-in", "server.csr",
                 "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
                 "-out", "server.crt", "-days", "2",
                 "-extfile", "server.ext"], cwd: dir)

        // Client cert, issued by the same CA — the kubeconfig identity.
        try run(["openssl", "req", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", "client.key", "-out", "client.csr",
                 "-subj", "/CN=test-user"], cwd: dir)
        try run(["openssl", "x509", "-req", "-in", "client.csr",
                 "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
                 "-out", "client.crt", "-days", "2"], cwd: dir)
        // A real passphrase: SecPKCS12Import rejects an empty one with
        // errSecAuthFailed.
        try run(["openssl", "pkcs12", "-export", "-out", "client.p12",
                 "-inkey", "client.key", "-in", "client.crt",
                 "-passout", "pass:\(p12Passphrase)"], cwd: dir)

        return PKI(dir: dir)
    }

    /// `openssl s_server` on an ephemeral port. `requireClientCert` mirrors a
    /// k8s API server configured for client-certificate auth.
    private final class TLSServer {
        let process: Process
        let port: Int
        init(pki: PKI, requireClientCert: Bool) throws {
            // Bind port 0 first to learn a free port, then release it.
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafePointer(to: &addr) {
                _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, len) }
            }
            withUnsafeMutablePointer(to: &addr) {
                _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &len) }
            }
            self.port = Int(UInt16(bigEndian: addr.sin_port))
            close(probe)

            // `-www` (serve a status page) rather than `-naccept 1`: macOS
            // ships LibreSSL, which has no `-naccept`.
            var args = ["openssl", "s_server", "-accept", "\(port)",
                        "-cert", pki.serverCert, "-key", pki.serverKey,
                        "-www", "-quiet"]
            if requireClientCert {
                args += ["-Verify", "1", "-CAfile", pki.dir.appendingPathComponent("ca.crt").path]
            }
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Let s_server bind before we dial.
            Thread.sleep(forTimeInterval: 0.6)
        }
        func stop() {
            if process.isRunning { process.terminate() }
        }
    }

    private static func loadIdentity(p12: URL) throws -> SecIdentity {
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: p12Passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "p12", code: Int(status))
        }
        return raw as! SecIdentity
    }

    private static func connectTCP(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            throw NSError(domain: "connect", code: Int(errno))
        }
        return fd
    }

    // MARK: - Tests

    /// The regression: a private-CA server is unreachable on the default
    /// system trust store. This is what dropped the tunnel and surfaced in
    /// the guest as "unexpected EOF".
    @Test("private-CA upstream fails without a pinned CA")
    func privateCAFailsUnpinned() throws {
        let pki = try Self.makePKI()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        let server = try TLSServer(pki: pki, requireClientCert: false)
        defer { server.stop() }

        let fd = try Self.connectTCP(port: server.port)
        defer { close(fd) }
        let tls = try TLSClientStream(fd: fd, peerName: "localhost")
        #expect(throws: MitmError.self) { try tls.handshake() }
    }

    /// The fix, half one: pinning the cluster CA makes the same server
    /// reachable.
    @Test("pinned cluster CA admits the private-CA upstream")
    func pinnedCASucceeds() throws {
        let pki = try Self.makePKI()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        let server = try TLSServer(pki: pki, requireClientCert: false)
        defer { server.stop() }

        let ca = ClusterCATrustRegistry()
        let profile = UUID()
        ca.setCA(pem: pki.caPEM, host: "localhost", profileID: profile)
        let anchor = try #require(ca.ca(for: "localhost", profileID: profile))

        let fd = try Self.connectTCP(port: server.port)
        defer { close(fd) }
        let tls = try TLSClientStream(fd: fd, peerName: "localhost", pinnedCA: anchor)
        try tls.handshake()
    }

    /// The fix, half two: a client-cert-requiring upstream (k8s
    /// `client-certificate-data` auth) completes only when the identity is
    /// supplied. Together with the CA, this is the full `kubectl exec` shape.
    @Test("client identity satisfies an mTLS upstream")
    func clientIdentitySucceeds() throws {
        let pki = try Self.makePKI()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        let server = try TLSServer(pki: pki, requireClientCert: true)
        defer { server.stop() }

        let ca = ClusterCATrustRegistry()
        let profile = UUID()
        ca.setCA(pem: pki.caPEM, host: "localhost", profileID: profile)
        let anchor = try #require(ca.ca(for: "localhost", profileID: profile))
        let identity = try Self.loadIdentity(p12: pki.clientP12)

        let fd = try Self.connectTCP(port: server.port)
        defer { close(fd) }
        let tls = try TLSClientStream(fd: fd, peerName: "localhost",
                                      clientIdentity: identity,
                                      pinnedCA: anchor)
        try tls.handshake()
        // Prove the session actually carries data, not just a handshake.
        try tls.write(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
    }

    /// The pin is an anchor, not a bypass: a cert from an unrelated CA is
    /// still refused when a CA is pinned for the host.
    @Test("pinning rejects a cert from a different CA")
    func pinnedCARejectsForeignCert() throws {
        let serving = try Self.makePKI()
        let unrelated = try Self.makePKI()
        defer {
            try? FileManager.default.removeItem(at: serving.dir)
            try? FileManager.default.removeItem(at: unrelated.dir)
        }
        let server = try TLSServer(pki: serving, requireClientCert: false)
        defer { server.stop() }

        // Pin the *unrelated* CA for this host.
        let ca = ClusterCATrustRegistry()
        let profile = UUID()
        ca.setCA(pem: unrelated.caPEM, host: "localhost", profileID: profile)
        let anchor = try #require(ca.ca(for: "localhost", profileID: profile))

        let fd = try Self.connectTCP(port: server.port)
        defer { close(fd) }
        let tls = try TLSClientStream(fd: fd, peerName: "localhost", pinnedCA: anchor)
        #expect(throws: MitmError.self) { try tls.handshake() }
    }
}
