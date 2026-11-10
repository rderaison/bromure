import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import Testing
@testable import ACLinux

/// The multi-user gateway's P2P ingress: a connection is pinned to the
/// account of the uid on its far end, before anything is read from it, and
/// may log in there only; no pin (root, an unknown uid, an account with no
/// control socket) closes it before the SSH banner.
@Suite("Gateway P2P ingress: the peer's account, and no other", .serialized)
struct GatewayP2PIngressTests {
    static let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    static let me = String(cString: getpwuid(getuid())!.pointee.pw_name)

    /// One answer to one auth request.
    static func auth(_ d: RemoteAuthDelegate, user: String, key: NIOSSHPublicKey) async throws -> Bool {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let p = loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
        d.requestReceived(request: .init(username: user, serviceName: "ssh-connection",
                                         request: .publicKey(.init(publicKey: key))), responsePromise: p)
        if case .success = try await p.futureResult.get() { return true }
        return false
    }

    /// The same key opens both alice's and bob's accounts: pinned to alice,
    /// the connection can't be bob's, whatever name it gives.
    @Test func aPinnedConnectionIsItsAccountsOnly() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let keys = GatewayKeyAccessTests.Keys([GatewayKeyAccessTests.line(Self.key, "bromure-account:dev")])
        let a = try await GatewayKeyAccessTests.daemon(dir, "alice", keys)
        let b = try await GatewayKeyAccessTests.daemon(dir, "bob", keys)
        defer { Task { await a.close(); await b.close() } }
        let router = GatewayRouter(socketDir: dir)
        func delegate(_ pin: String?) -> RemoteAuthDelegate {
            RemoteAuthDelegate(username: "gw", allowPassword: false, allowPubkey: true, authorizedKeys: [],
                               throttle: RemoteAuthThrottle(), peerIP: "local", router: router, pinnedAccount: pin)
        }
        let pinned = delegate("alice")
        #expect(try await Self.auth(pinned, user: "bob", key: Self.key) == false, "bob's key, on alice's connection")
        #expect(pinned.grant.account == nil)
        let ok = delegate("alice")
        #expect(try await Self.auth(ok, user: "alice", key: Self.key))
        #expect(ok.grant.account == "alice")
        // Unpinned (the TCP listener), the name decides, as before.
        #expect(try await Self.auth(delegate(nil), user: "bob", key: Self.key))
    }

    @Test func rootAndUnknownUIDsAreNeverPinned() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = GatewayRouter(socketDir: dir)
        let root = try await GatewayKeyAccessTests.daemon(dir, "root", GatewayKeyAccessTests.Keys([]))
        defer { Task { await root.close() } }
        #expect(GatewayP2PIngress.account(uid: 0, router: router) == nil, "root, even with a socket")
        #expect(GatewayP2PIngress.account(uid: 3_999_999_999, router: router) == nil, "no such user")
        #expect(GatewayP2PIngress.account(uid: getuid(), router: router) == nil, "an account with no control socket")
        let mine = try await GatewayKeyAccessTests.daemon(dir, Self.me, GatewayKeyAccessTests.Keys([]))
        defer { Task { await mine.close() } }
        if getuid() != 0 { #expect(GatewayP2PIngress.account(uid: getuid(), router: router) == Self.me) }
    }

    /// Over a real Unix socket: the pin read from the connection
    /// (SO_PEERCRED: this process) lets the banner out; no pin, none.
    @Test func noPinNoBanner() async throws {
        guard getuid() != 0 else { return }
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = GatewayRouter(socketDir: dir + "/sock")
        try FileManager.default.createDirectory(atPath: dir + "/sock", withIntermediateDirectories: true)
        let server = await MainActor.run { () -> RemoteAccessServer in
            let s = RemoteAccessServer(paths: .init(dir: URL(fileURLWithPath: dir + "/remote", isDirectory: true)))
            s.accountRouter = router
            s.accountPin = GatewayP2PIngress.pin(router: router)
            return s
        }
        try await MainActor.run { try server.start(.init(port: 0, bindAddress: "", passwordAuth: false, pubkeyAuth: true,
                                                          unixSocketPath: dir + "/p2p.sock")) }
        defer { Task { @MainActor in server.stop() } }
        // This user has no control socket yet: refused before the banner.
        #expect(Self.firstBytes(dir + "/p2p.sock").isEmpty, "closed with nothing said")
        let mine = try await GatewayKeyAccessTests.daemon(dir + "/sock", Self.me, GatewayKeyAccessTests.Keys([]))
        defer { Task { await mine.close() } }
        #expect(Self.firstBytes(dir + "/p2p.sock").hasPrefix("SSH-2.0-"), "pinned to this user: the banner")
    }

    /// A user's P2P ingress port (what their broker announces) reaches the
    /// gateway's pinned listener as that user: the banner once the account
    /// exists, nothing before.
    @Test func aUsersIngressPortReachesTheGatewayAsThatUser() async throws {
        guard getuid() != 0 else { return }
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sock", withIntermediateDirectories: true)
        let router = GatewayRouter(socketDir: dir + "/sock")
        let server = await MainActor.run { () -> RemoteAccessServer in
            let s = RemoteAccessServer(paths: .init(dir: URL(fileURLWithPath: dir + "/remote", isDirectory: true)))
            s.accountRouter = router
            s.accountPin = GatewayP2PIngress.pin(router: router)
            return s
        }
        try await MainActor.run { try server.start(.init(port: 0, bindAddress: "", passwordAuth: false, pubkeyAuth: true,
                                                          unixSocketPath: dir + "/p2p.sock", proxyHeader: true)) }
        defer { Task { @MainActor in server.stop() } }
        let forwarder = P2PIngressForwarder()
        let port = try #require(forwarder.ensure(gatewaySocket: dir + "/p2p.sock"))
        #expect(forwarder.ensure(gatewaySocket: dir + "/p2p.sock") == port, "one ingress per daemon")
        #expect(Self.firstTCPBytes(port).isEmpty, "no account yet: closed before the banner")
        let mine = try await GatewayKeyAccessTests.daemon(dir + "/sock", Self.me, GatewayKeyAccessTests.Keys([]))
        defer { Task { await mine.close() } }
        #expect(Self.firstTCPBytes(port).hasPrefix("SSH-2.0-"))
    }

    static func firstTCPBytes(_ port: Int) -> String {
        guard let fd = P2PTCP.connect(ip: "127.0.0.1", port: port, timeout: 2) else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    @Test func proxyLinesAreParsedStrictly() {
        #expect(RemoteAccessServer.proxyClientIP("PROXY TCP4 203.0.113.7 10.0.0.1 51000 40123") == .some("203.0.113.7"))
        #expect(RemoteAccessServer.proxyClientIP("PROXY TCP6 2001:db8::1 2001:db8::2 51000 40123") == .some("2001:db8::1"))
        #expect(RemoteAccessServer.proxyClientIP("PROXY UNKNOWN") == .some(nil))
        for bad in ["PROXY TCP4 nothost 10.0.0.1 1 2", "PROXY TCP4 1.2.3.4 10.0.0.1 1", "SSH-2.0-x", "PROXY TCP4 1.2.3.4 5.6.7.8 1 99999", ""] {
            #expect(RemoteAccessServer.proxyClientIP(bad) == nil, "\(bad)")
        }
    }

    /// A listener that takes a PROXY line: a valid one, then the banner; a
    /// bogus one, closed with nothing said.
    @Test func theIngressReadsTheProxyLineFirst() async throws {
        guard getuid() != 0 else { return }
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sock", withIntermediateDirectories: true)
        let router = GatewayRouter(socketDir: dir + "/sock")
        let mine = try await GatewayKeyAccessTests.daemon(dir + "/sock", Self.me, GatewayKeyAccessTests.Keys([]))
        defer { Task { await mine.close() } }
        let server = await MainActor.run { () -> RemoteAccessServer in
            let s = RemoteAccessServer(paths: .init(dir: URL(fileURLWithPath: dir + "/remote", isDirectory: true)))
            s.accountRouter = router
            s.accountPin = GatewayP2PIngress.pin(router: router)
            return s
        }
        try await MainActor.run { try server.start(.init(port: 0, bindAddress: "", passwordAuth: false, pubkeyAuth: true,
                                                          unixSocketPath: dir + "/p2p.sock", proxyHeader: true)) }
        defer { Task { @MainActor in server.stop() } }
        #expect(Self.firstBytes(dir + "/p2p.sock", sending: "PROXY TCP4 203.0.113.7 10.0.0.1 51000 40123\r\n").hasPrefix("SSH-2.0-"))
        #expect(Self.firstBytes(dir + "/p2p.sock", sending: "SSH-2.0-OpenSSH_9\r\n").isEmpty, "no PROXY line: closed")
    }

    @Test func p2pIsOffUnlessTheAdminSaysSo() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(P2PSettings.load(dir + "/none.json") == P2PSettings(enabled: false, bindAddress: nil))
        try P2PSettings(enabled: true, bindAddress: "127.0.0.1").save(dir + "/p2p.json")
        #expect(P2PSettings.load(dir + "/p2p.json") == P2PSettings(enabled: true, bindAddress: "127.0.0.1"))
        var st = stat()
        #expect(stat(dir + "/p2p.json", &st) == 0 && st.st_mode & 0o777 == 0o644)
    }

    /// The ingress listens on the admin's address, and closes when P2P stops.
    @Test func theIngressBindsTheAdminsAddressAndCloses() throws {
        let f = P2PIngressForwarder()
        let port = try #require(f.ensure(gatewaySocket: "/nonexistent", bindAddress: "127.0.0.1"))
        let probe = P2PTCP.connect(ip: "127.0.0.1", port: port, timeout: 2)
        #expect(probe != nil)
        if let probe { close(probe) }
        f.stop()
        #expect(P2PTCP.connect(ip: "127.0.0.1", port: port, timeout: 1) == nil, "closed")
        #expect(P2PIngressForwarder.listen(on: "not-an-address") == nil)
    }

    /// A pinned account has its own cap on password checks in flight
    /// (within the global one), freed as they end.
    @Test func eachAccountHasItsOwnVerificationCap() {
        let t = RemoteAuthThrottle()
        for _ in 0..<RemoteAuthThrottle.perAccountInFlight { #expect(t.beginVerification(account: "alice")) }
        #expect(!t.beginVerification(account: "alice"), "alice's slots are taken")
        #expect(t.beginVerification(account: "bob"), "bob's aren't")
        t.endVerification(account: "alice")
        #expect(t.beginVerification(account: "alice"))
    }

    /// The gateway trusts the switch only from a file root alone may write.
    @Test func p2pSettingsAreTrustedOnlyWhenRootsAlone() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try P2PSettings(enabled: true).save(dir + "/p2p.json")
        #expect(P2PSettings.load(dir + "/p2p.json", trusted: false).enabled)
        #expect(!P2PSettings.load(dir + "/p2p.json", trusted: true).enabled || getuid() == 0, "this user's file, not root's")
    }

    /// No PROXY line in time: closed.
    @Test func aSilentIngressConnectionIsClosed() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ProxyHeaderHandler(timeout: .milliseconds(50)) { _ in
            channel.eventLoop.makeSucceededVoidFuture()
        })
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        #expect(channel.isActive)
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(60))
        #expect(!channel.isActive, "closed at the deadline")
    }

    /// What the server says first on a new connection to `path` (2 s at most).
    static func firstBytes(_ path: String, sending: String? = nil) -> String {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in p.copyBytes(from: Array(path.utf8)); p[path.utf8.count] = 0 }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { return "" }
        if let sending { _ = Array(sending.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }
}
