import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import X509
import NIOSSL
import NIOTLS
import Testing
@testable import ACLinux
import SandboxEngine

// MARK: - The proxy layer

/// The guest's side of the proxy: raw bytes over the workspace's listener.
enum RawProxyClient {
    /// Sends `request` and returns what the proxy answers until it closes
    /// (or `timeout`).
    static func exchange(_ path: String, _ request: String, timeout: TimeInterval = 10) throws -> String {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in path.utf8.prefix(p.count - 1).enumerated() { p[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, Int32(MSG_NOSIGNAL)) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }
}

@Suite("Proxy egress policy", .serialized)
struct ProxyEgressPolicyTests {
    final class Rig {
        let dir: String
        let proxy: MitmProxy
        let listener: MitmListener
        let listenerB: MitmListener
        let pid = UUID()
        let pidB = UUID()
        init() throws {
            dir = try shortTempDir()
            proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            listener = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "eg-\(pid)")
            listenerB = try proxy.serve(udsPath: dir + "/vmb.sock", profileID: pidB, fdStoreName: "eg-\(pidB)")
        }
        func path(b: Bool = false) -> String {
            HybridVsockListener.path(uds: dir + (b ? "/vmb.sock" : "/vm.sock"), port: MitmProxy.vsockPort)
        }
        func policy(_ rules: String, for id: UUID? = nil) throws {
            proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: try EgressPolicy.parse(rules)), for: id ?? pid)
        }
        func stop() {
            listener.stop(); listenerB.stop()
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    @Test func aDeniedCONNECTGetsMacOSs403AndTheOtherWorkspaceIsUntouched() throws {
        let rig = try Rig(); defer { rig.stop() }
        try rig.policy("deny tcp blocked.example\ndefault allow")
        let out = try RawProxyClient.exchange(rig.path(), "CONNECT blocked.example:443 HTTP/1.1\r\nHost: blocked.example:443\r\n\r\n")
        let expected = ProxyPolicy.connectDenied(policy: try EgressPolicy.parse("deny tcp blocked.example\ndefault allow"),
                                                 profileID: rig.pid, host: "blocked.example", port: 443)
        #expect(out == expected, "byte for byte: \(out)")
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        // Workspace B has no such rule: its CONNECT goes on to the
        // destination check (the name doesn't resolve here: 502, not 403).
        let b = try RawProxyClient.exchange(rig.path(b: true), "CONNECT blocked.example:443 HTTP/1.1\r\nHost: blocked.example:443\r\n\r\n")
        #expect(!b.hasPrefix("HTTP/1.1 403"), "B: \(b)")
    }

    @Test func aDeniedPlainHTTPRequestIsRefusedToo() throws {
        let rig = try Rig(); defer { rig.stop() }
        try rig.policy("deny tcp blocked.example\ndefault allow")
        let out = try RawProxyClient.exchange(rig.path(), "GET http://blocked.example/x HTTP/1.1\r\nHost: blocked.example\r\n\r\n")
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), "\(out)")
    }

    @Test func anOpenShellDenialCarriesItsJSONBody() throws {
        let rig = try Rig(); defer { rig.stop() }
        let yaml = """
        version: 1
        network_policies:
          only:
            endpoints:
              - host: allowed.example
                port: 443
        """
        let cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                   egressPolicy: EgressPolicy(openShell: try OpenShellPolicy.parse(yaml)))
        rig.proxy.setGuardrailsConfig(cfg, for: rig.pid)
        let out = try RawProxyClient.exchange(rig.path(), "CONNECT other.example:443 HTTP/1.1\r\nHost: other.example:443\r\n\r\n")
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\n"), "\(out)")
        #expect(out.contains("\"error\":\"policy_denied\"") && out.contains("\"layer\":\"l4\""), "\(out)")
    }

    @Test func aRuleChangeCutsAnOpenTunnel() throws {
        let ip = try #require(Daemon.primaryIPv4(), "a host address to listen on (loopback is always blocked)")
        // Something listening at the destination, so the tunnel opens.
        let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: ip, port: 0).wait()
        defer { server.close(promise: nil) }
        let port = server.localAddress!.port!
        let rig = try Rig(); defer { rig.stop() }
        try rig.policy("default allow")
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in rig.path().utf8.prefix(p.count - 1).enumerated() { p[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "CONNECT \(ip):\(port) HTTP/1.1\r\nHost: \(ip):\(port)\r\n\r\n"
        _ = req.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, Int32(MSG_NOSIGNAL)) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        // Now the workspace's rules deny it: the open tunnel is closed.
        try rig.policy("deny tcp \(ip)\ndefault allow")
        let after = recv(fd, &buf, buf.count, 0)
        #expect(after == 0, "the cut closes the guest's side (got \(after), errno \(errno))")
    }

    @Test func aCONNECTsSNIRoutesNothing() throws {
        // `openssl s_client -proxy P -connect allowed:443 -servername evil`:
        // every check is made for the CONNECT host, and so is the leaf (and
        // the dial), as on macOS; the SNI routes nothing. The client sees a
        // certificate for the CONNECT host, not for the name it sent.
        let ip = try #require(Daemon.primaryIPv4())
        let upstream = try RecordingUpstream(host: ip)
        defer { upstream.stop() }
        let rig = try Rig(); defer { rig.stop() }
        let fd = try Self.connectUDS(rig.path())
        GuestEnd.send(fd, "CONNECT \(ip):\(upstream.port) HTTP/1.1\r\nHost: \(ip):\(upstream.port)\r\n\r\n")
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200"), "the tunnel opens")
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.trustRoots = .certificates([rig.proxy.caNIO])
        cfg.certificateVerification = .noHostnameVerification   // to read what the leaf names
        let ctx = try NIOSSLContext(configuration: cfg)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let done = loop.makePromise(of: Void.self)
        let ch = try ClientBootstrap(group: loop)
            .channelInitializer { c in
                c.eventLoop.makeCompletedFuture {
                    try c.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: ctx, serverHostname: "evil.example"))
                    try c.pipeline.syncOperations.addHandler(HandshakeDone(done))
                }
            }
            .withConnectedSocket(fd).wait()
        defer { ch.close(promise: nil) }
        loop.scheduleTask(in: .seconds(10)) { done.fail(POSIXError(.ETIMEDOUT)) }
        try done.futureResult.wait()
        let leaf = try ch.nioSSL_peerCertificate().wait()
        let pem = try #require(leaf).toDERBytes()
        let cert = try Certificate(derEncoded: pem)
        let sans = try cert.extensions.subjectAlternativeNames.map { Array($0) } ?? []
        let named = sans.map { "\($0)" }.joined(separator: " ")
        let ipBytes = "[" + ip.split(separator: ".").joined(separator: ", ") + "]"   // how a SAN prints an IP
        #expect(named.contains(ipBytes) && !named.contains("evil.example"), "the leaf names the CONNECT host: \(named)")
        #expect(upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    @Test func plainHTTPGetsTheWorkspacesDestinationCheck() throws {
        // An OpenShell endpoint whose allowed_ips don't hold the address:
        // the verdict allows the host and port, the address check refuses
        // the dial. (Without the workspace's check at the dial, the request
        // went out.)
        let ip = try #require(Daemon.primaryIPv4())
        let upstream = try RecordingUpstream(host: ip)
        defer { upstream.stop() }
        let rig = try Rig(); defer { rig.stop() }
        let yaml = """
        version: 1
        network_policies:
          only:
            endpoints: [{ host: "\(ip)", port: \(upstream.port), allowed_ips: [10.255.255.0/24] }]
        """
        rig.proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: EgressPolicy(openShell: try OpenShellPolicy.parse(yaml))),
                                      for: rig.pid)
        let out = try RawProxyClient.exchange(rig.path(), "GET http://\(ip):\(upstream.port)/x HTTP/1.1\r\nHost: \(ip):\(upstream.port)\r\n\r\n")
        #expect(out.hasPrefix("HTTP/1.1 403") && out.contains("destination_denied") && out.contains("allowed_ips"), "\(out)")
        #expect(upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    static func connectUDS(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in path.utf8.prefix(p.count - 1).enumerated() { p[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    @Test func aGuardrailsWebRuleRefusesTheRequestBeforeItLeaves() throws {
        // `deny web` is a method rule: decided on the decrypted request, by
        // the shared ProxyPolicy.guardrailsAnswer.
        let cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                   egressPolicy: try EgressPolicy.parse("deny web blocked.example POST\ndefault allow"))
        let rig = try Rig(); defer { rig.stop() }
        rig.proxy.setGuardrailsConfig(cfg, for: rig.pid)
        let proxy = rig.proxy, pid = rig.pid
        let answer = try #require(waitAsync {
            var req = Data("POST /x HTTP/1.1\r\nHost: blocked.example\r\nContent-Length: 0\r\n\r\n".utf8)
            return await RequestReader.policyAnswer(&req, proxy: proxy, profileID: pid,
                                                    host: "blocked.example", port: 443, tls: true)
        })
        let text = String(decoding: answer, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), "\(text)")
        #expect(waitAsync {
            var get = Data("GET /x HTTP/1.1\r\nHost: blocked.example\r\n\r\n".utf8)
            return await RequestReader.policyAnswer(&get, proxy: proxy, profileID: pid,
                                                    host: "blocked.example", port: 443, tls: true)
        } == nil, "a GET goes on")
    }
}

/// Runs `body` to completion from synchronous test code.
func waitAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = NIOLockedValueBox<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task { let v = await body(); box.withLockedValue { $0 = v }; done.signal() }
    _ = done.wait(timeout: .now() + 30)
    return box.withLockedValue { $0 }!
}

/// Fulfils `done` once the TLS handshake completes.
final class HandshakeDone: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let done: EventLoopPromise<Void>
    init(_ done: EventLoopPromise<Void>) { self.done = done }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { done.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { done.fail(error) }
}
