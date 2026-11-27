import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import bromure_ac

// Regression (CWE-613): a key the fat client enrolled over the debug E2E test
// login went into the persistent authorized_keys and signed in under the
// owner's name, so it kept owner access after the test login was cleared or
// the app relaunched. Now it is the test login's: in memory, under its name
// only, gone with the login.
@Suite("Remote test-login keys", .serialized)
struct RemoteTestLoginKeyTests {
    static let owner = "owner-user"

    static func newKey() -> NIOSSHPublicKey { NIOSSHPrivateKey(ed25519Key: .init()).publicKey }

    /// What the front door decides for `key` under `user`.
    static func signsIn(user: String, key: NIOSSHPublicKey,
                        ownerKeys: Set<NIOSSHPublicKey> = []) throws -> (Bool, RemoteGrant) {
        let delegate = RemoteAuthDelegate(username: owner, allowPassword: false, allowPubkey: true,
                                          authorizedKeys: ownerKeys, throttle: RemoteAuthThrottle(),
                                          peerIP: "127.0.0.1")
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        let request = NIOSSHUserAuthenticationRequest(
            username: user, serviceName: "ssh-connection",
            request: .publicKey(.init(publicKey: key)))
        delegate.requestReceived(request: request, responsePromise: promise)
        loop.run()
        guard case .success = try promise.futureResult.wait() else { return (false, delegate.grant) }
        return (true, delegate.grant)
    }

    @Test("A test-login key signs in under the test login's name only, until the login ends")
    func scopedAndEphemeral() throws {
        let login = RemoteTestLogin.shared.mint()
        defer { RemoteTestLogin.shared.clear() }
        let key = Self.newKey()
        #expect(RemoteTestLogin.shared.addKey(String(openSSHPublicKey: key), user: login.user) != nil)

        let (asTest, grant) = try Self.signsIn(user: login.user, key: key)
        #expect(asTest)
        #expect(grant.testLoginUser == login.user)
        #expect(try Self.signsIn(user: Self.owner, key: key).0 == false)

        RemoteTestLogin.shared.clear()
        #expect(try Self.signsIn(user: login.user, key: key).0 == false)
        #expect(RemoteTestLogin.shared.keyFingerprints.isEmpty)
    }

    @Test("A new test login doesn't inherit the old one's keys")
    func replacedLogin() throws {
        let first = RemoteTestLogin.shared.mint()
        defer { RemoteTestLogin.shared.clear() }
        let key = Self.newKey()
        _ = RemoteTestLogin.shared.addKey(String(openSSHPublicKey: key), user: first.user)
        let second = RemoteTestLogin.shared.mint()
        #expect(try Self.signsIn(user: second.user, key: key).0 == false)
        #expect(try Self.signsIn(user: first.user, key: key).0 == false)
    }

    @Test("A key can't be enrolled for a login that isn't the current one")
    func wrongLogin() {
        _ = RemoteTestLogin.shared.mint()
        defer { RemoteTestLogin.shared.clear() }
        #expect(RemoteTestLogin.shared.addKey(String(openSSHPublicKey: Self.newKey()), user: "bromure-e2e-000000") == nil)
        #expect(RemoteTestLogin.shared.addKey("not a key", user: RemoteTestLogin.shared.current!.user) == nil)
    }

    @Test("An owner key doesn't sign in under the test login's name; it still does under the owner's")
    func ownerKeyStaysOwners() throws {
        let login = RemoteTestLogin.shared.mint()
        defer { RemoteTestLogin.shared.clear() }
        let key = Self.newKey()
        #expect(try Self.signsIn(user: login.user, key: key, ownerKeys: [key]).0 == false)
        let (asOwner, grant) = try Self.signsIn(user: Self.owner, key: key, ownerKeys: [key])
        #expect(asOwner)
        #expect(grant.testLoginUser == nil)
    }

    /// One raw request over the control socket, `prefix` ahead of it; the status and JSON body.
    static func send(_ socketPath: String, prefix: String, _ path: String, _ body: [String: Any]) throws -> (Int, [String: Any]) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(ok == 0)
        let json = try JSONSerialization.data(withJSONObject: body)
        let head = prefix + "POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        let req = Data(head.utf8) + json
        _ = req.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: reply, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] ?? [:]
        return (status, obj)
    }

    @Test("POST /remote/keys over a test-login connection enrolls for the test login, never into authorized_keys")
    func controlSocketRoute() async throws {
        let path = NSTemporaryDirectory() + "tl-\(UUID().uuidString.prefix(6)).sock"
        let server = ACAutomationServer(unixSocketPath: path)
        final class Added: @unchecked Sendable { var keys: [String] = [] }
        let added = Added()
        server.onRemoteAddKey = { key in added.keys.append(key); return ["ok": true] }
        server.start()
        defer { server.stop(); unlink(path) }
        try await Task.sleep(for: .milliseconds(200))
        let login = RemoteTestLogin.shared.mint()
        defer { RemoteTestLogin.shared.clear() }
        let key = Self.newKey()
        let line = String(openSSHPublicKey: key)

        let marker = RemoteTestLogin.bridgeMarker + login.user + "\r\n"
        let viaTest = try await Task.detached { try Self.send(path, prefix: marker, "/remote/keys", ["key": line]) }.value
        #expect(viaTest.0 == 200 && viaTest.1["testLogin"] as? Bool == true)
        #expect(added.keys.isEmpty)
        #expect(try Self.signsIn(user: login.user, key: key).0)

        // Marked for a login that isn't the current one: refused, not persisted.
        let stale = RemoteTestLogin.bridgeMarker + "bromure-e2e-000000\r\n"
        let viaStale = try await Task.detached { try Self.send(path, prefix: stale, "/remote/keys", ["key": line]) }.value
        #expect(viaStale.0 == 400)
        #expect(added.keys.isEmpty)

        // The owner's own connection (no mark) still enrolls an owner key.
        let viaOwner = try await Task.detached { try Self.send(path, prefix: "", "/remote/keys", ["key": line]) }.value
        #expect(viaOwner.0 == 200)
        #expect(added.keys == [line])
    }
}
