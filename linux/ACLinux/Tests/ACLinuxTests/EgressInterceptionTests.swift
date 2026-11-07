import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux
import SandboxEngine

/// A plain-HTTP upstream that records what reached it.
final class RecordingUpstream: @unchecked Sendable {
    let requests = NIOLockedValueBox<[String]>([])
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(host: String) throws {
        let requests = self.requests
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(requests)) }
            .bind(host: host, port: 0).wait()
    }

    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let requests: NIOLockedValueBox<[String]>
        var buf = ""
        init(_ r: NIOLockedValueBox<[String]>) { requests = r }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            buf += b.readString(length: b.readableBytes) ?? ""
            guard buf.contains("\r\n\r\n") else { return }
            requests.withLockedValue { $0.append(buf) }
            let body = "upstream ok"
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
                string: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")))
                .whenComplete { _ in context.close(promise: nil) }
        }
    }
}

/// The guest's end of a transparent flow: a socketpair, the other end handed to the proxy.
enum GuestEnd {
    static func pair() throws -> (guest: Int32, app: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0 else { throw POSIXError(.EIO) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return (fds[0], fds[1])
    }

    static func send(_ fd: Int32, _ s: String) {
        _ = s.utf8CString.withUnsafeBufferPointer { Glibc.send(fd, $0.baseAddress, $0.count - 1, Int32(MSG_NOSIGNAL)) }
    }

    /// Everything until the proxy closes its end (or the timeout): "" when it
    /// closed at once. nil on a timeout (it neither answered nor closed).
    static func readAll(_ fd: Int32) -> String? {
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n == 0 { return String(decoding: out, as: UTF8.self) }
            if n < 0 { return errno == EAGAIN || errno == EWOULDBLOCK ? nil : String(decoding: out, as: UTF8.self) }
            out += buf[0..<n]
        }
    }
}

@Suite("Transparent interception", .serialized)
struct TransparentInterceptionTests {
    final class Rig {
        let dir: String
        let proxy: MitmProxy
        let pid = UUID()
        let ip: String
        let upstream: RecordingUpstream
        init() throws {
            ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always blocked)")
            dir = try shortTempDir()
            proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            upstream = try RecordingUpstream(host: ip)
            proxy.routeAllTo = (ip, upstream.port)
        }
        func policy(_ rules: String) throws {
            proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: try EgressPolicy.parse(rules)), for: pid)
        }
        func stop() { upstream.stop(); try? FileManager.default.removeItem(atPath: dir) }
    }

    @Test(arguments: ["127.0.0.1", "169.254.169.254", "0.0.0.0"])
    func alwaysBlockedDestinationsAreRefused(dest: String) throws {
        let rig = try Rig(); defer { rig.stop() }
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        GuestEnd.send(guest, "GET / HTTP/1.1\r\nHost: allowed.example\r\n\r\n")
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: dest, destPort: 80)
        #expect(GuestEnd.readAll(guest) == "", "closed, never answered")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    @Test func aMultiUserServersOwnAddressIsRefused() throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.proxy.blocksHostAddresses = true
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        GuestEnd.send(guest, "GET / HTTP/1.1\r\nHost: allowed.example\r\n\r\n")
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: rig.ip, destPort: 80)
        #expect(GuestEnd.readAll(guest) == "")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    @Test func plainHTTPGoesThroughTheProxysPipeline() throws {
        let rig = try Rig(); defer { rig.stop() }
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        // The Host names the rig's own address (it resolves here, and isn't
        // refused on a single-user server); routeAllTo takes the dial.
        GuestEnd.send(guest, "GET /hello HTTP/1.1\r\nHost: \(rig.ip)\r\n\r\n")
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: "198.51.100.9", destPort: 80)
        let out = GuestEnd.readAll(guest) ?? "TIMEOUT"
        #expect(out.hasSuffix("upstream ok"), "\(out)")
        let seen = rig.upstream.requests.withLockedValue { $0 }
        #expect(seen.count == 1 && seen[0].hasPrefix("GET /hello HTTP/1.1"), "\(seen)")
        #expect(seen.first?.lowercased().contains("host: \(rig.ip)") == true)
    }

    @Test func aDeniedHostIsRefusedByItsHostHeader() throws {
        let rig = try Rig(); defer { rig.stop() }
        try rig.policy("deny tcp evil.example\ndefault allow")
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        GuestEnd.send(guest, "GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n")
        // An address the switch had no name for: the MITM decides by the Host.
        // Defence in depth: with that deny disabled, the tracked-connection
        // re-check (trackForFirewall, macOS's trackedForFirewall) still
        // closes the flow, so this test fails only with both off (mutation run).
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: "198.51.100.9", destPort: 80)
        #expect(GuestEnd.readAll(guest) == "")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    @Test func aDeniedSNIIsRefusedBeforeAnyHandshake() throws {
        let rig = try Rig(); defer { rig.stop() }
        try rig.policy("deny tcp evil.example\ndefault allow")
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        let hello = TestHello.clientHello(sni: "evil.example")
        _ = hello.withUnsafeBufferPointer { Glibc.send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: "198.51.100.9", destPort: 443)
        #expect(GuestEnd.readAll(guest) == "", "closed: no ServerHello, no leaf")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    @Test func anIPLiteralRuleDecidesASNILessFlowUnderOpenShell() throws {
        // OpenShell decides by the destination address when there's no name.
        let rig = try Rig(); defer { rig.stop() }
        let yaml = """
        version: 1
        network_policies:
          only:
            endpoints:
              - host: allowed.example
                port: 443
        """
        rig.proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: EgressPolicy(openShell: try OpenShellPolicy.parse(yaml))),
                                      for: rig.pid)
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        let hello = TestHello.clientHello(sni: nil)
        _ = hello.withUnsafeBufferPointer { Glibc.send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: "198.51.100.9", destPort: 443)
        #expect(GuestEnd.readAll(guest) == "")
    }

    @Test func theInterceptorTerminatesTheGuestsTCPAndForgetsAClosedPort() throws {
        let rig = try Rig(); defer { rig.stop() }
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: rig.proxy, guestMTU: 1500) { _, ip in
            injected.withLockedValue { $0.append(ip) }
        }
        // A SYN from the guest (IP header onward), to an always-blocked
        // address: the stack still answers the handshake, then the proxy
        // closes its end and the stack FINs.
        let syn = Array(TestFrames.tcp(to: TestFrames.ip("169.254.169.254"), port: 80, flags: 0x02, seq: 100).dropFirst(14))
        interceptor.handleDivertedPacket(portID: 7, profileID: rig.pid, ipPacket: syn)
        var synAck: [UInt8]?
        for _ in 0..<200 where synAck == nil {
            synAck = injected.withLockedValue { $0 }.first { $0.count >= 40 && $0[33] == (UtunPacket.SYN | UtunPacket.ACK) }
            if synAck == nil { usleep(10_000) }
        }
        let sa = try #require(synAck, "the stack answered the SYN")
        #expect(Array(sa[28..<32]) == TestFrames.be32(101), "acks the guest's ISN")
        #expect(interceptor.openFlows == 1)
        // A stray segment for no flow: a RST, no new flow.
        let stray = Array(TestFrames.tcp(to: TestFrames.ip("198.51.100.9"), port: 443, flags: 0x10, seq: 5, ack: 9).dropFirst(14))
        interceptor.handleDivertedPacket(portID: 7, profileID: rig.pid, ipPacket: stray)
        #expect(injected.withLockedValue { $0 }.last.map { $0[33] & UtunPacket.RST != 0 } == true)
        interceptor.portClosed(portID: 7)
        #expect(interceptor.openFlows == 0)
    }
}

/// A TCP listener that only counts the connections it gets.
final class CountingListener: @unchecked Sendable {
    let accepted = NIOLockedValueBox<Int>(0)
    let channel: Channel
    var port: Int { channel.localAddress!.port! }
    init(host: String) throws {
        let accepted = self.accepted
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in accepted.withLockedValue { $0 += 1 }; return ch.close() }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }
}

@Suite("Transparent interception limits", .serialized)
struct TransparentInterceptionLimitTests {
    @Test func aFlowThatSendsNothingIsNeverSpliced() throws {
        // A guest that opens a :443 flow and closes it (or stays silent):
        // nothing to decide, so no host connect on its behalf.
        let ip = try #require(Daemon.primaryIPv4())
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let target = try CountingListener(host: ip); defer { target.stop() }
        MitmProxy.firstByteTimeoutMs = 300
        defer { MitmProxy.firstByteTimeoutMs = 5000 }
        for silent in [false, true] {
            let (guest, app) = try GuestEnd.pair()
            if !silent { shutdown(guest, Int32(SHUT_WR)) }    // closed with no byte sent
            proxy.acceptTransparentFlow(appFD: app, profileID: UUID(), destIP: ip, destPort: target.port)
            #expect(GuestEnd.readAll(guest) == "", silent ? "a silent flow is closed" : "an empty flow is closed")
            close(guest)
        }
        usleep(300_000)
        #expect(target.accepted.withLockedValue { $0 } == 0, "no host connect for either")
    }

    @Test func aPortsFlowsAreCappedAndHalfOpenOnesExpire() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: proxy, guestMTU: 1500) { _, ip in injected.withLockedValue { $0.append(ip) } }
        defer { interceptor.portClosed(portID: 9) }
        // SYNs to an always-blocked address (refused by the proxy at once):
        // the flows stay half-open, as a SYN flood's would.
        for i in 0..<SwitchInterceptor.maxFlowsPerPort {
            let syn = Array(TestFrames.tcp(to: TestFrames.ip("169.254.169.254"), port: 80, flags: 0x02,
                                           seq: 100, sport: UInt16(20000 + i)).dropFirst(14))
            interceptor.handleDivertedPacket(portID: 9, profileID: UUID(), ipPacket: syn)
        }
        #expect(interceptor.openFlows == SwitchInterceptor.maxFlowsPerPort)
        let over = Array(TestFrames.tcp(to: TestFrames.ip("169.254.169.254"), port: 80, flags: 0x02,
                                        seq: 100, sport: 30000).dropFirst(14))
        interceptor.handleDivertedPacket(portID: 9, profileID: UUID(), ipPacket: over)
        #expect(interceptor.openFlows == SwitchInterceptor.maxFlowsPerPort, "the port's cap holds")
        #expect(injected.withLockedValue { $0 }.contains { UtunPacket.parse($0).map { $0.dstPort == 30000 && $0.flags & UtunPacket.RST != 0 } == true },
                "the SYN past the cap is reset")
        // None completed its handshake: swept once past the timeout.
        interceptor.sweepHalfOpen(now: Date().addingTimeInterval(SwitchInterceptor.synTimeout + 1))
        #expect(interceptor.openFlows == 0)
    }
}

@Suite("E2e mode without a test upstream", .serialized)
struct E2eUpstreamGuardTests {
    @Test func everyUpstreamIsRefusedNeverDialed() throws {
        let ip = try #require(Daemon.primaryIPv4())
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let target = try CountingListener(host: ip); defer { target.stop() }
        proxy.refusesRealUpstreams = true
        let pid = UUID()
        let l = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "e2eg-\(pid)")
        defer { l.stop() }
        // Through the proxy: refused with the reason, no connect.
        let out = try RawProxyClient.exchange(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort),
                                              "GET http://\(ip):\(target.port)/ HTTP/1.1\r\nHost: \(ip):\(target.port)\r\n\r\n")
        #expect(out.hasPrefix("HTTP/1.1 403") && out.contains("e2e mode"), "\(out)")
        // A raw splice (a transparent flow's fail-open, a tls: skip endpoint): none.
        let (guest, app) = try GuestEnd.pair()
        GuestEnd.send(guest, "not tls, not http\r\n")
        proxy.acceptTransparentFlow(appFD: app, profileID: pid, destIP: ip, destPort: target.port)
        #expect(GuestEnd.readAll(guest) == "")
        close(guest)
        usleep(300_000)
        #expect(target.accepted.withLockedValue { $0 } == 0, "no host connect")
        // With the test route on, the guard stands aside.
        proxy.routeAllTo = (ip, target.port)
        let (g2, a2) = try GuestEnd.pair()
        GuestEnd.send(g2, "not tls, not http\r\n")
        proxy.acceptTransparentFlow(appFD: a2, profileID: pid, destIP: ip, destPort: target.port)
        _ = GuestEnd.readAll(g2)
        close(g2)
        usleep(300_000)
        #expect(target.accepted.withLockedValue { $0 } >= 1, "spliced to the address the guest chose")
    }

    /// With a test route that can't be used (a name that doesn't resolve),
    /// a request isn't dialed to the real host instead; and a splice goes to
    /// the test host only.
    @Test func aRouteThatFailsFallsBackToNothing() throws {
        let ip = try #require(Daemon.primaryIPv4())
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let target = try CountingListener(host: ip); defer { target.stop() }
        proxy.refusesRealUpstreams = true
        proxy.routeAllTo = ("no-such-test-upstream.invalid", 1)
        let pid = UUID()
        let l = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "e2eg2-\(pid)")
        defer { l.stop() }
        let out = try RawProxyClient.exchange(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort),
                                              "GET http://\(ip):\(target.port)/ HTTP/1.1\r\nHost: \(ip):\(target.port)\r\n\r\n")
        #expect(out.hasPrefix("HTTP/1.1 403") && out.contains("e2e mode"), "\(out)")
        // A splice to an address that isn't the test host's: none.
        proxy.routeAllTo = ("127.0.0.1", 1)
        let (guest, app) = try GuestEnd.pair()
        GuestEnd.send(guest, "not tls, not http\r\n")
        proxy.acceptTransparentFlow(appFD: app, profileID: pid, destIP: ip, destPort: target.port)
        #expect(GuestEnd.readAll(guest) == "")
        close(guest)
        usleep(300_000)
        #expect(target.accepted.withLockedValue { $0 } == 0, "no host connect")
    }
}

/// A TCP echo server: what a connection sends comes straight back.
final class EchoServer: @unchecked Sendable {
    let channel: Channel
    var port: Int { channel.localAddress!.port! }
    init(host: String) throws {
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: host, port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }
    final class Echo: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    }
}

@Suite("Raw splices keep every byte", .serialized)
struct SpliceByteTests {
    /// Reads until `n` bytes or 5 s.
    static func read(_ fd: Int32, _ n: Int) -> [UInt8] {
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while out.count < n {
            let k = recv(fd, &buf, buf.count, 0)
            if k <= 0 { break }
            out += buf[0..<k]
        }
        return out
    }

    @Test func aTLSSkipCONNECTsFirstBytesArrive() throws {
        // The client's first bytes (a ClientHello) right after the 200, before
        // the upstream has connected: every one reaches the endpoint, in order.
        let ip = try #require(Daemon.primaryIPv4())
        let echo = try EchoServer(host: ip); defer { echo.stop() }
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        let yaml = """
        version: 1
        network_policies:
          raw:
            endpoints: [{ host: "\(ip)", port: \(echo.port), tls: skip }]
        """
        proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                   egressPolicy: EgressPolicy(openShell: try OpenShellPolicy.parse(yaml))), for: pid)
        let l = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "sb-\(pid)"); defer { l.stop() }
        let fd = try ProxyEgressPolicyTests.connectUDS(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort))
        defer { close(fd) }
        let payload = (0..<3000).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        let req = Array("CONNECT \(ip):\(echo.port) HTTP/1.1\r\nHost: \(ip):\(echo.port)\r\n\r\n".utf8)
        // The CONNECT and the first bytes in one write: the proxy has them
        // before it even dials.
        _ = (req + payload).withUnsafeBufferPointer { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        let head = Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        let got = Self.read(fd, head.count + payload.count)
        #expect(Array(got.prefix(head.count)) == head, "\(String(decoding: got.prefix(80), as: UTF8.self))")
        #expect(Array(got.dropFirst(head.count)) == payload, "byte for byte: \(got.count - head.count) of \(payload.count)")
        // A client that waits for the 200 first (most do), then sends at once.
        let fd2 = try ProxyEgressPolicyTests.connectUDS(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort))
        defer { close(fd2) }
        _ = req.withUnsafeBufferPointer { Glibc.send(fd2, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        #expect(Self.read(fd2, head.count) == head)
        _ = payload.withUnsafeBufferPointer { Glibc.send(fd2, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        #expect(Self.read(fd2, payload.count) == payload, "after the 200: byte for byte too")
    }

    @Test func aTransparentSpliceKeepsWhatThePeekSaw() throws {
        // A flow the proxy leaves alone (not TLS here; a pinned host's
        // ClientHello in life): the bytes in the socket before it's accepted,
        // which the peeks only looked at, reach the destination, in order.
        let ip = try #require(Daemon.primaryIPv4())
        let echo = try EchoServer(host: ip); defer { echo.stop() }
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        let payload = Array("not TLS, not HTTP: a raw protocol's first words".utf8)
        _ = payload.withUnsafeBufferPointer { Glibc.send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        proxy.acceptTransparentFlow(appFD: app, profileID: UUID(), destIP: ip, destPort: echo.port)
        #expect(Self.read(guest, payload.count) == payload)
    }
}

/// A minimal TLS 1.2-shaped ClientHello, with or without server_name.
enum TestHello {
    static func clientHello(sni: String?) -> [UInt8] {
        var ext: [UInt8] = []
        if let sni {
            let name = Array(sni.utf8)
            let list: [UInt8] = [0] + TestFrames.be16(UInt16(name.count)) + name
            ext += [0, 0] + TestFrames.be16(UInt16(list.count + 2)) + TestFrames.be16(UInt16(list.count)) + list
        }
        let body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 7, count: 32) + [0]
            + [0, 2, 0x13, 0x01] + [1, 0] + TestFrames.be16(UInt16(ext.count)) + ext
        let hs: [UInt8] = [1, 0] + TestFrames.be16(UInt16(body.count)) + body
        return [0x16, 0x03, 0x01] + TestFrames.be16(UInt16(hs.count)) + hs
    }
}
