import Darwin
import Foundation
import Testing
@testable import SandboxEngine

/// The bake's package proxy serves only the guest's subnet — never the Mac
/// itself or another machine on the LAN.
@Suite("Bake package proxy scope")
struct AlpinePackageProxyScopeTests {

    private func ip(_ s: String) -> UInt32 { AlpinePackageProxy.ipv4(s)! }

    @Test("Only the guest's /24 is served, not the gateway (the Mac) or anyone else")
    func peers() {
        let gw = ip("192.168.64.1")
        #expect(AlpinePackageProxy.admitsPeer(ip("192.168.64.2"), gateway: gw))
        #expect(AlpinePackageProxy.admitsPeer(ip("192.168.64.254"), gateway: gw))
        #expect(!AlpinePackageProxy.admitsPeer(gw, gateway: gw))
        #expect(!AlpinePackageProxy.admitsPeer(ip("127.0.0.1"), gateway: gw))
        #expect(!AlpinePackageProxy.admitsPeer(ip("192.168.1.20"), gateway: gw))
        #expect(!AlpinePackageProxy.admitsPeer(ip("192.168.64.2"), gateway: 0))
    }

    // MARK: End to end, on loopback

    private func dial(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(rc == 0)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    @Test("A peer on the guest subnet is served")
    func guestServed() throws {
        let proxy = AlpinePackageProxy()
        // Loopback stands in for the guest subnet: 127.0.0.1 is a peer of 127.0.0.2.
        try proxy.start(guestGateway: "127.0.0.2")
        defer { proxy.stop() }
        let fd = dial(proxy.port)
        defer { close(fd) }
        // Answered (not dropped): a bad request gets its 400.
        #expect(exchange(fd, "BOGUS\r\n\r\n").hasPrefix("HTTP/1.1 400"))
    }

    private func exchange(_ fd: Int32, _ request: String) -> String {
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    @Test("A connection from outside the guest subnet gets nothing")
    func outsiderRefused() throws {
        let proxy = AlpinePackageProxy()
        try proxy.start(guestGateway: "10.200.0.1")   // loopback isn't its subnet
        defer { proxy.stop() }
        let fd = dial(proxy.port)
        defer { close(fd) }
        #expect(exchange(fd, "CONNECT example.com:443 HTTP/1.1\r\n\r\n").isEmpty)
    }
}
