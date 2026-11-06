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
