import Foundation
import Glibc
import NIOCore
import NIOSSH
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The fat-client E2E suite's generated SSH login on a Linux server
    /// (shared RemoteTestLogin; macOS: Tests/AgentCodingTests/
    /// RemoteTestLoginKeyTests.swift): the SSH front door marks a test-login
    /// connection's control request, the control socket takes the mark off
    /// and the key that request enrolls stays the test login's, in memory,
    /// never in authorized_keys (CWE-613).
    @Suite("Remote test login", .serialized)
    struct RemoteTestLoginLinuxTests {
        static func buffer(_ s: String) -> ByteBuffer { ByteBuffer(string: s) }
        static func publicKeyLine() -> String {
            String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey) + " e2e@test"
        }

        @Test func theMarkComesOffTheFrontOfTheRequest() {
            let marker = RemoteTestLogin.bridgeMarker
            // Marked: the name is taken, the request left whole.
            var b = Self.buffer(marker + "bromure-e2e-ab12cd\r\nPOST /remote/keys HTTP/1.1\r\n\r\n")
            #expect(ControlConnection.takeTestLoginMark(&b) == .user("bromure-e2e-ab12cd"))
            #expect(b.getString(at: b.readerIndex, length: b.readableBytes) == "POST /remote/keys HTTP/1.1\r\n\r\n")
            // Not marked: untouched.
            var plain = Self.buffer("GET /state HTTP/1.1\r\n\r\n")
            #expect(ControlConnection.takeTestLoginMark(&plain) == .none)
            #expect(plain.readableBytes == "GET /state HTTP/1.1\r\n\r\n".utf8.count)
            // A request that only starts like the mark's first letters.
            var bro = Self.buffer("BROWSE /x HTTP/1.1\r\n\r\n")
            #expect(ControlConnection.takeTestLoginMark(&bro) == .none)
            // The mark still arriving: wait, take nothing.
            for partial in ["", "B", String(marker.dropLast(3)), marker, marker + "bromure-e2e-ab12cd", marker + "name\r"] {
                var p = Self.buffer(partial)
                #expect(ControlConnection.takeTestLoginMark(&p) == .incomplete, "\(partial.debugDescription)")
                #expect(p.readableBytes == partial.utf8.count)
            }
        }

        /// One raw request to a control socket; the reply's text.
        static func raw(_ path: String, _ bytes: String) throws -> String {
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { p in
                for (i, c) in path.utf8.enumerated() { p[i] = c }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = bytes.withCString { write(fd, $0, strlen($0)) }
            shutdown(fd, Int32(SHUT_WR))
            var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return String(decoding: out, as: UTF8.self)
        }

        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var requests: [ControlRequest] = []
            func add(_ r: ControlRequest) { lock.lock(); requests.append(r); lock.unlock() }
            var all: [ControlRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        }

        @Test func aMarkedRequestReachesItsHandlerNamedAndWhole() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let seen = Seen()
            let srv = try await ControlServer.start(path: dir + "/c.sock") { req in
                seen.add(req)
                return ControlResponse(200, ["ok": true])
            }
            let body = #"{"key":"ssh-ed25519 AAAA e2e"}"#
            let request = "POST /remote/keys HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
            #expect(try Self.raw(dir + "/c.sock", RemoteTestLogin.bridgeMarker + "bromure-e2e-ab12cd\r\n" + request).hasPrefix("HTTP/1.1 200"))
            #expect(try Self.raw(dir + "/c.sock", request).hasPrefix("HTTP/1.1 200"))
            let got = seen.all
            #expect(got.count == 2)
            #expect(got.first?.testLoginUser == "bromure-e2e-ab12cd")
            #expect(got.first?.path == "/remote/keys" && got.first?.body["key"]?.stringValue == "ssh-ed25519 AAAA e2e")
            #expect(got.last?.testLoginUser == nil, "an ordinary request is nobody's test login")
            await srv.close()
        }

        @Test func aKeyEnrolledOverTheTestLoginIsItsOwn() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            RemoteTestLogin.shared.clear()
            defer { RemoteTestLogin.shared.clear() }
            let line = Self.publicKeyLine()
            // No test login: a request marked as one enrolls nothing.
            #expect(await d.remoteAddKey(["key": .string(line)], testLoginUser: "bromure-e2e-000000").status == 400)
            let c = RemoteTestLogin.shared.mint()
            // Another name than the current login's: nothing either.
            #expect(await d.remoteAddKey(["key": .string(line)], testLoginUser: "bromure-e2e-zzzzzz").status == 400)
            #expect(await d.remoteAddKey(["key": "not a key"], testLoginUser: c.user).status == 400)
            let added = await d.remoteAddKey(["key": .string(line)], testLoginUser: c.user)
            #expect(added.status == 200 && added.body["testLogin"] == .bool(true), "\(added.body)")
            let fp = try #require(added.body["fingerprint"]?.stringValue)
            #expect(fp.hasPrefix("SHA256:") && !fp.hasSuffix("="))
            // It signs in under the test login's name only, and is listed there.
            let key = try NIOSSHPublicKey(openSSHPublicKey: line.split(separator: " ").prefix(2).joined(separator: " "))
            #expect(RemoteTestLogin.shared.authorizes(user: c.user, key: key))
            #expect(!RemoteTestLogin.shared.authorizes(user: NSUserName(), key: key))
            let status = await d.remoteStatus().body
            #expect(status["testLoginUser"]?.stringValue == c.user)
            #expect(status["testLoginKeys"] == .array([.string(fp)]))
            // Never an owner key: not in authorized_keys' list.
            if case .array(let owner)? = status["authorizedKeys"] {
                #expect(!owner.contains { $0["fingerprint"]?.stringValue == fp }, "\(status)")
            } else { Issue.record("no authorizedKeys in \(status)") }
            // Gone with the login.
            RemoteTestLogin.shared.clear()
            #expect(!RemoteTestLogin.shared.authorizes(user: c.user, key: key))
            let after = await d.remoteStatus().body
            #expect(after["testLoginUser"]?.stringValue == "" && after["testLoginKeys"] == .array([]))
            await d.shutdown()
        }

        @Test func mintingNeedsTheDebugSwitch() async throws {
            // The unit tests don't run with BROMURE_DEBUG_CLAUDE.
            try #require(ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] == nil)
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            RemoteTestLogin.shared.clear()
            for method in ["POST", "DELETE"] {
                let r = await d.handle(ControlRequest(method: method, path: "/remote/test-login", body: .object([:])))
                #expect(r.status == 403, "\(method): \(r.body)")
            }
            #expect(RemoteTestLogin.shared.current == nil, "nothing was minted")
            await d.shutdown()
        }
    }
}
