import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bromure_ac

// The per-host SOCKS forwarder is auto-started when a remote host connects and
// feeds the browser pane's PAC. These cover the listener lifecycle (ephemeral
// bind + clean stop) without needing a live remote host or a VM.
@Suite("FatForward")
struct FatForwardTests {
    @Test("listenEphemeral binds a real loopback port")
    func ephemeralBind() {
        let (fd, port) = FatForward.listenEphemeral()
        #expect(fd >= 0)
        #expect(port > 0 && port < 65536)
        if fd >= 0 { Darwin.close(fd) }
    }

    @Test("RemoteSocksForwarder accepts a connection, then stops cleanly")
    func forwarderLifecycle() throws {
        let host = RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody")
        let fwd = try #require(RemoteSocksForwarder(host: host))
        #expect(fwd.port > 0 && fwd.port < 65536)

        // A client can connect — proves the accept loop is live. We DON'T send a
        // SOCKS greeting (that would trigger an outbound ssh dial); an immediate
        // close makes handleSocks fail its first read cleanly.
        let c = connectLoopback(port: fwd.port)
        #expect(c >= 0)
        if c >= 0 { Darwin.close(c) }

        fwd.stop()
        fwd.stop()   // idempotent — second close is a no-op
    }

    private func connectLoopback(port: Int) -> Int32 {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { Darwin.close(s); return -1 }
        return s
    }
}
