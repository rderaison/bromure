import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// AWS SSO on a Linux server (macOS: pushAWSCredentials with the shared
    /// AWSSSOResolver): an SSO profile's role credentials come from the AWS
    /// CLI's SSO cache, asked of the portal with its token; with no valid
    /// token the guest's helper is told to run `aws sso login` (a server opens
    /// no browser). A fake home and a fake portal on loopback: nothing of the
    /// user's is read, no AWS host is reached.
    @Suite("AWS SSO", .serialized)
    struct AWSSSOTests {
        static let startURL = "https://e2e-test.awsapps.com/start"
        static let keyID = "ASIA" + "TESTSSO000000001"

        /// A portal answering /federation/credentials; its requests, in order.
        final class Portal: @unchecked Sendable {
            let port: UInt16
            private let fd: Int32
            private let lock = NSLock()
            private var seen: [String] = []
            var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }

            init(expiresInMs: Int64) throws {
                let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                var one: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET)
                a.sin_addr.s_addr = inet_addr("127.0.0.1")
                a.sin_port = 0
                _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                listen(sock, 8)
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(sock, $0, &len) } }
                fd = sock
                port = UInt16(bigEndian: a.sin_port)
                let keyID = AWSSSOTests.keyID
                Thread.detachNewThread { [self] in
                    while true {
                        let c = accept(fd, nil, nil)
                        guard c >= 0 else { return }
                        var buf = [UInt8](repeating: 0, count: 8192)
                        let n = read(c, &buf, buf.count)
                        let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                        lock.lock(); seen.append(req); lock.unlock()
                        let exp = Int64(Date().timeIntervalSince1970 * 1000) + expiresInMs
                        let body = #"{"roleCredentials":{"accessKeyId":"\#(keyID)","secretAccessKey":"sso-secret-e2e","sessionToken":"sso-token-e2e","expiration":\#(exp)}}"#
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        _ = resp.withCString { write(c, $0, strlen($0)) }
                        close(c)
                    }
                }
            }
            func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
        }

        /// A home with an SSO profile `dev`, and its SSO token cached (valid
        /// for `tokenValidFor`, or none).
        static func home(_ dir: String, tokenValidFor: TimeInterval?) throws -> URL {
            let home = URL(fileURLWithPath: dir + "/home", isDirectory: true)
            let aws = home.appendingPathComponent(".aws", isDirectory: true)
            try FileManager.default.createDirectory(at: aws.appendingPathComponent("sso/cache"), withIntermediateDirectories: true)
            try """
            [profile dev]
            sso_start_url = \(startURL)
            sso_region = us-east-1
            sso_account_id = 123456789012
            sso_role_name = Developer
            region = eu-west-1
            """.write(to: aws.appendingPathComponent("config"), atomically: true, encoding: .utf8)
            if let valid = tokenValidFor {
                let f = ISO8601DateFormatter()
                let token = #"{"accessToken":"sso-access-token-e2e","expiresAt":"\#(f.string(from: Date().addingTimeInterval(valid)))","region":"us-east-1","startUrl":"\#(startURL)"}"#
                let name = AWSSSOResolver.sha1Hex("\(startURL)|us-east-1") + ".json"
                try token.write(to: aws.appendingPathComponent("sso/cache/" + name), atomically: true, encoding: .utf8)
            }
            return home
        }

        static func ssoProfile() -> Profile {
            var p = Profile(name: "sso", tool: .claude, authMode: .token)
            p.awsCredentials.authMode = .ssoProfile
            p.awsCredentials.ssoProfileName = "dev"
            return p
        }

        @Test func theCacheFileNameIsTheCLIs() {
            // SHA-1 through swift-crypto here (CommonCrypto on macOS): the same digest.
            #expect(AWSSSOResolver.sha1Hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        }

        @Test func anSSOProfileIsResolvedFromTheCache() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let portal = try Portal(expiresInMs: 3_600_000)
            defer { portal.stop() }
            AWSSSOResolver.homeOverride = try Self.home(dir, tokenValidFor: 3600)
            AWSSSOResolver.portalOverride = URL(string: "http://127.0.0.1:\(portal.port)")
            defer { AWSSSOResolver.homeOverride = nil; AWSSSOResolver.portalOverride = nil }
            let mitm = try #require(await d.mitm)
            let p = Self.ssoProfile()
            try FileManager.default.createDirectory(atPath: dir + "/meta", withIntermediateDirectories: true)
            await d.pushAWSCredentials(for: p, meta: dir + "/meta")
            for _ in 0..<100 where mitm.awsCreds.accessKeyID(for: p.id) != Self.keyID { try await Task.sleep(nanoseconds: 50_000_000) }
            #expect(mitm.awsCreds.accessKeyID(for: p.id) == Self.keyID, "the role's credentials, resolved")
            #expect(!AWSSSORefusals.contains(p.id), "the helper is served")
            let req = try #require(portal.requests.first)
            #expect(req.hasPrefix("GET /federation/credentials?"))
            #expect(req.contains("role_name=Developer") && req.contains("account_id=123456789012"))
            #expect(req.lowercased().contains("x-amz-sso_bearer_token: sso-access-token-e2e"))
            // The session's end stops the refresh loop with it.
            #expect(await d.ssoRefreshTasks[p.id] != nil)
            await d.clearWorkspaceProxyState(p.id)
            #expect(await d.ssoRefreshTasks[p.id] == nil)
            await d.shutdown()
        }

        @Test func noValidTokenTellsTheHelperToLogIn() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let portal = try Portal(expiresInMs: 3_600_000)
            defer { portal.stop() }
            // A token about to expire (under 5 minutes): not used.
            AWSSSOResolver.homeOverride = try Self.home(dir, tokenValidFor: 60)
            AWSSSOResolver.portalOverride = URL(string: "http://127.0.0.1:\(portal.port)")
            defer { AWSSSOResolver.homeOverride = nil; AWSSSOResolver.portalOverride = nil }
            let p = Self.ssoProfile()
            defer { AWSSSORefusals.set(false, for: p.id) }
            try FileManager.default.createDirectory(atPath: dir + "/meta", withIntermediateDirectories: true)
            await d.pushAWSCredentials(for: p, meta: dir + "/meta")
            var reason = ""
            for _ in 0..<100 {
                reason = String(decoding: AWSSSORefusals.payload(for: p.id), as: UTF8.self)
                if reason.contains("aws sso login") { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(AWSSSORefusals.contains(p.id))
            #expect(reason.contains("aws sso login --profile dev"), "\(reason)")
            #expect(portal.requests.isEmpty, "the portal isn't asked without a token")
            // Static keys: nothing to resolve, the helper served.
            var s = Profile(name: "static", tool: .claude, authMode: .token)
            s.awsCredentials.accessKeyID = "AKID" + "STATICTEST"
            s.awsCredentials.secretAccessKey = "not-a-real-secret"
            await d.pushAWSCredentials(for: s, meta: dir + "/meta")
            #expect(!AWSSSORefusals.contains(s.id))
            await d.shutdown()
        }
    }
}
