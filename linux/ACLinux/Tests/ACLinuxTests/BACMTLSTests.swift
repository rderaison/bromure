import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOSSL
import Testing
@testable import ACLinux

/// The install's mTLS client on Linux (macOS: URLSession + BACMTLSDelegate):
/// the request reaches a server that demands a client certificate signed by
/// the org CA, presenting the leaf; without a leaf nothing is sent; a server
/// the client doesn't trust is refused. A test CA (openssl) and a Python TLS
/// server on loopback: no real host.
@Suite("BAC mTLS client", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")
                && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct BACMTLSTests {
    final class Rig {
        let dir: String
        let port: Int
        let server: Process
        let ca: [NIOSSLCertificate]
        let material: BACMTLSIdentity.Material

        init() throws {
            let dir = try shortTempDir()
            self.dir = dir
            func run(_ args: [String]) throws {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw NIOMTLSHTTPClient.Refused(description: "openssl \(args.first ?? "")") }
            }
            try run(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "1",
                     "-subj", "/CN=test org CA", "-addext", "basicConstraints=critical,CA:TRUE",
                     "-addext", "keyUsage=critical,keyCertSign", "-keyout", "ca.key", "-out", "ca.pem"])
            try "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n".write(toFile: dir + "/srv.ext", atomically: true, encoding: .utf8)
            try run(["req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=ingest",
                     "-keyout", "srv.key", "-out", "srv.csr"])
            try run(["x509", "-req", "-in", "srv.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "1",
                     "-extfile", "srv.ext", "-out", "srv.pem"])
            // The install's leaf: RSA, its key as PKCS#1 DER (BACEnrollmentStore's form).
            try "extendedKeyUsage=clientAuth\n".write(toFile: dir + "/cli.ext", atomically: true, encoding: .utf8)
            try run(["genrsa", "-traditional", "-out", "cli.key", "2048"])
            try run(["req", "-new", "-key", "cli.key", "-subj", "/CN=install-e2e", "-out", "cli.csr"])
            try run(["x509", "-req", "-in", "cli.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "1",
                     "-extfile", "cli.ext", "-out", "cli.pem"])
            try run(["rsa", "-in", "cli.key", "-outform", "DER", "-traditional", "-out", "cli.der"])
            ca = try NIOSSLCertificate.fromPEMFile(dir + "/ca.pem")
            material = .init(chain: try NIOSSLCertificate.fromPEMFile(dir + "/cli.pem"),
                             key: try NIOSSLPrivateKey(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: dir + "/cli.der"))), format: .der))
            try """
            import http.server, json, ssl, sys
            class H(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"
                def do_POST(self):
                    n = int(self.headers.get("Content-Length") or 0)
                    body = self.rfile.read(n)
                    peer = dict(x[0] for x in self.connection.getpeercert()["subject"])
                    out = json.dumps({"cn": peer.get("commonName"), "path": self.path, "body": body.decode(),
                                      "auth": self.headers.get("Authorization")}).encode()
                    self.send_response(201); self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
                def log_message(self, *a): pass
            s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
            c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("srv.pem", "srv.key")
            c.verify_mode = ssl.CERT_REQUIRED; c.load_verify_locations("ca.pem")
            s.socket = c.wrap_socket(s.socket, server_side=True)
            open("port.tmp", "w").write(str(s.server_address[1])); __import__("os").rename("port.tmp", "port")
            s.serve_forever()
            """.write(toFile: dir + "/srv.py", atomically: true, encoding: .utf8)
            server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-I", "srv.py"]
            server.currentDirectoryURL = URL(fileURLWithPath: dir)
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            // Its port, written once it listens (never a blocking read).
            var p = 0
            for _ in 0..<100 where p == 0 {
                p = Int((try? String(contentsOfFile: dir + "/port", encoding: .utf8)) ?? "") ?? 0
                if p == 0 { usleep(50_000) }
            }
            port = p
        }

        deinit {
            // By pid, and reaped here (Process.waitUntilExit doesn't return
            // from an async test's thread).
            let pid = server.processIdentifier
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            try? FileManager.default.removeItem(atPath: dir)
        }

        func request(_ path: String = "/ac-ingest") -> URLRequest {
            var r = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(#"{"events":[1]}"#.utf8)
            return r
        }
    }

    @Test func theLeafIsPresentedToTheOrgsServer() async throws {
        let rig = try Rig()
        #expect(rig.port > 0)
        let m = rig.material
        let client = NIOMTLSHTTPClient(timeout: 10, identity: { m }, extraRoots: rig.ca)
        let (data, resp) = try await client.data(for: rig.request())
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(doc["cn"] as? String == "install-e2e", "the server saw the install's leaf")
        #expect(doc["path"] as? String == "/ac-ingest" && doc["body"] as? String == #"{"events":[1]}"#)
        #expect(doc["auth"] is NSNull || doc["auth"] == nil, "no bearer: the leaf is the credential")
        client.shutdown(cancelling: false)
    }

    @Test func noLeafSendsNothing() async throws {
        let client = NIOMTLSHTTPClient(timeout: 5, identity: { throw BACMTLSIdentity.Failure.missingMaterial })
        var r = URLRequest(url: URL(string: "https://127.0.0.1:9/ac-ingest")!)
        r.httpMethod = "POST"
        await #expect(throws: BACMTLSIdentity.Failure.self) { _ = try await client.data(for: r) }
        // Not enrolled here (a fresh secret store): the real client has no leaf either.
        BACMTLSIdentity.purge()
    }

    @Test func anUntrustedServerIsRefused() async throws {
        let rig = try Rig()
        let m = rig.material
        // The system roots only: the test CA's server isn't trusted.
        let client = NIOMTLSHTTPClient(timeout: 10, identity: { m })
        await #expect(throws: (any Error).self) { _ = try await client.data(for: rig.request()) }
    }

    @Test func httpIsRefused() async throws {
        let client = NIOMTLSHTTPClient(timeout: 5, identity: { throw BACMTLSIdentity.Failure.missingMaterial })
        await #expect(throws: NIOMTLSHTTPClient.Refused.self) {
            _ = try await client.data(for: URLRequest(url: URL(string: "http://127.0.0.1:9/")!))
        }
    }
}

