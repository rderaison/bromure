import Foundation
import Glibc

/// The load balancer's TCP listener and splice on Linux (macOS:
/// FatForward.listen / FatForward.splice, which also carry the fat client's
/// transport and stay as they are there). Same listener (SO_REUSEADDR,
/// 0.0.0.0, backlog 64) and the same half-close-aware pump; every send says
/// MSG_NOSIGNAL, so a peer gone mid-relay can't SIGPIPE the daemon.
// @port-skip linux-only: FatForward.listen / splice for the Linux load balancer (FatForward is the macOS/iOS fat-client transport)
enum LinuxTCPRelay {
    // @port-skip linux-only: FatForward.listen(port:bindAll: true) on Linux
    static func listen(port: Int) -> Int32 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Glibc.listen(fd, 64) == 0 else { close(fd); return -1 }
        return fd
    }

    /// Read what's there from `from` and send it all to `to`; false at EOF
    /// or a hard error.
    // @port-skip linux-only: FatForward.copyOnce on Linux
    private static func copyOnce(_ from: Int32, _ to: Int32, _ buf: inout [UInt8]) -> Bool {
        let r = buf.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
        if r <= 0 { return false }
        var off = 0
        while off < r {
            let w = buf.withUnsafeBytes { send(to, $0.baseAddress!.advanced(by: off), r - off, Int32(MSG_NOSIGNAL)) }
            if w > 0 { off += w; continue }
            if w < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Both ways until both directions ended; one direction's end half-closes
    /// the other. Closes both fds.
    // @port-skip linux-only: FatForward.splice on Linux
    static func splice(_ a: Int32, _ b: Int32) {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var aOpen = true, bOpen = true
        while aOpen || bOpen {
            var fds = [pollfd(fd: aOpen ? a : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: bOpen ? b : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            let ready = Int16(POLLIN | POLLHUP | POLLERR)
            if aOpen, fds[0].revents & ready != 0, !copyOnce(a, b, &buf) { aOpen = false; shutdown(b, Int32(SHUT_WR)) }
            if bOpen, fds[1].revents & ready != 0, !copyOnce(b, a, &buf) { bOpen = false; shutdown(a, Int32(SHUT_WR)) }
        }
        close(a)
        close(b)
    }
}
