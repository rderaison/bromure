import Foundation
import Glibc
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux
import SandboxEngine

/// The bake's package proxy on Linux: the switch diverts the guest's TCP to
/// the gateway's proxy port (no listener), and the shared
/// AlpinePackageProxy serves those connections.
@Suite("Bake package proxy", .serialized)
struct BakeProxyTests {
    let gw = TestFrames.ip("192.168.64.1")

    @Test func theSwitchDivertsTheGatewaysServicePortOnly() throws {
        let rig = FirewallRig()
        let service = RecordingInterceptor()
        rig.fw.setGatewayService(port: 3128, service)
        let other = MAC([0x52, 0x54, 0, 0, 0, 0x0b])
        // Any port, governed or not (the bake's is not).
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 3128, flags: 0x02), from: other) == .consumed)
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 3128, flags: 0x10, seq: 1001, ack: 1), from: other) == .consumed)
        let d = service.diverted.withLockedValue { $0 }
        #expect(d.count == 2 && d.allSatisfy { $0.portID == other.portID })
        #expect(d.first.map { Array($0.ip.prefix(1)) } == [0x45], "the IP packet, Ethernet header off")
        // Not: another gateway port, the service port elsewhere, UDP, a fragment.
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 3129, flags: 0x02), from: other) == .consumed)
        #expect(rig.fw.handle(TestFrames.tcp(to: TestFrames.ip("198.51.100.9"), port: 3128, flags: 0x02), from: other) == .pass)
        #expect(rig.fw.handle(TestFrames.udp(to: gw, port: 3128), from: other) == .consumed)
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 3128, flags: 0x02, fragment: 0x2000), from: other) == .consumed)
        #expect(service.diverted.withLockedValue { $0.count } == 2)
        // Stopped: the gateway's port is closed again.
        rig.fw.setGatewayService(port: 3128, nil)
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 3128, flags: 0x02), from: other) == .consumed)
        #expect(service.diverted.withLockedValue { $0.count } == 2)
    }

    /// A local TCP server answering one line, on 127.0.0.1.
    static func echoServer() throws -> (port: UInt16, fd: Int32) {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        Thread.detachNewThread {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(c, &buf, buf.count)
            let reply = "echo:" + String(decoding: buf.prefix(max(0, n)), as: UTF8.self)
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
        return (UInt16(bigEndian: a.sin_port), fd)
    }

    static func readAll(_ fd: Int32, timeout: Int32 = 5) -> String {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf.prefix(n)
        }
        return String(decoding: out, as: UTF8.self)
    }

    @Test func aDivertedConnectionIsServedAsAnAcceptedOne() throws {
        let server = try Self.echoServer()
        defer { close(server.fd) }
        let proxy = AlpinePackageProxy()
        let lines = NIOLockedValueBox<[String]>([])
        AlpinePackageProxy.logSink = { l in lines.withLockedValue { $0.append(l) } }
        defer { AlpinePackageProxy.logSink = nil }
        try proxy.startDiverted(guestGateway: "192.168.64.1", port: 3128)
        #expect(proxy.port == 3128)
        #expect(proxy.guestBase(host: "192.168.64.1")?.absoluteString == "http://192.168.64.1:3128")

        // The guest's end of a diverted flow, and the proxy's.
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
        proxy.serveDiverted(fds[1], peer: TestFrames.ip("192.168.64.2"))
        // A client waits for the 200 before it speaks through the tunnel.
        let req = "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = req.withCString { write(fds[0], $0, strlen($0)) }
        let established = "HTTP/1.1 200 Connection established\r\n\r\n"
        var head = [UInt8](repeating: 0, count: established.utf8.count)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #expect(recv(fds[0], &head, head.count, Int32(MSG_WAITALL)) == head.count)
        #expect(String(decoding: head, as: UTF8.self) == established)
        _ = "hello".withCString { write(fds[0], $0, strlen($0)) }
        let got = Self.readAll(fds[0])
        close(fds[0])
        #expect(got == "echo:hello")
        proxy.stop()
        let log = lines.withLockedValue { $0 }
        #expect(log.contains { $0.contains("CONNECT 127.0.0.1:\(server.port)") })
        #expect(log.contains { $0.contains("upstream hosts contacted") && $0.contains("127.0.0.1") })
    }

    @Test func aPeerOffTheGuestSubnetIsRefused() throws {
        let proxy = AlpinePackageProxy()
        let lines = NIOLockedValueBox<[String]>([])
        AlpinePackageProxy.logSink = { l in lines.withLockedValue { $0.append(l) } }
        defer { AlpinePackageProxy.logSink = nil }
        try proxy.startDiverted(guestGateway: "192.168.64.1", port: 3128)
        for peer in ["10.0.0.5", "192.168.64.1"] {
            var fds: [Int32] = [0, 0]
            #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
            proxy.serveDiverted(fds[1], peer: TestFrames.ip(peer))
            _ = "GET / HTTP/1.1\r\n\r\n".withCString { write(fds[0], $0, strlen($0)) }
            #expect(Self.readAll(fds[0], timeout: 2) == "", "\(peer): closed unanswered")
            close(fds[0])
        }
        proxy.stop()
        #expect(lines.withLockedValue { $0 }.filter { $0.contains("refused a connection") }.count == 2)
    }

    @Test func aBadGatewayIsAnError() {
        #expect(throws: AlpinePackageProxy.Error.self) { try AlpinePackageProxy().startDiverted(guestGateway: "nope", port: 1) }
    }
}
