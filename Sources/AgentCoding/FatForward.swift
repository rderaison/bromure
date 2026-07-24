// FatForward core socket helpers, split from FatClientForward.swift so the
// iOS P2P transport (P2PBroker/TurnTCP) can reuse listenEphemeral/splice/
// peerIPv4 without the ArgumentParser CLI + RemoteHost SOCKS methods.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum FatForward {
    /// Why `copyOnce` stopped. `.more` copied a chunk (keep going); `.eof` hit
    /// end-of-stream or a hard error on this direction (a graceful half-close —
    /// keep draining the other way); `.stalled` gave up writing to a peer that
    /// stopped draining for `maxWriteStalls` send-timeout windows — a DEAD peer,
    /// which must tear the WHOLE pump down (both directions are futile), not
    /// half-close and linger polling a leg that will never deliver EOF.
    private enum CopyResult { case more, eof, stalled }

    /// Max consecutive no-progress write stalls (each an SO_SNDTIMEO window)
    /// before a pump declares the write peer dead. Only a socket given a send
    /// timeout (`SocketTuning.boundStalledPeer` — the TURN relay leg, or the TLS
    /// tunnel's loopback socketpair on the `turns:` path) ever reaches this: a
    /// plain blocking socket blocks in `write()` and never returns EWOULDBLOCK,
    /// so every other splice/proxy caller is unaffected.
    private static let maxWriteStalls = 4

    /// Read up to bufSize from `from` and write it all to `to`.
    private static func copyOnce(_ from: Int32, _ to: Int32, _ buf: inout [UInt8]) -> CopyResult {
        let r = buf.withUnsafeMutableBytes { Darwin.read(from, $0.baseAddress, $0.count) }
        if r <= 0 { return .eof }
        var off = 0
        var stalls = 0
        while off < r {
            let w = buf.withUnsafeBytes { Darwin.write(to, $0.baseAddress!.advanced(by: off), r - off) }
            if w > 0 { off += w; stalls = 0; continue }
            if w < 0 && errno == EINTR { continue }
            if w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // `to` isn't draining — a send-timeout'd relay leg toward a peer
                // that stopped reading (coturn's zero-window persist when the far
                // client died; neither keepalive nor the retransmit timer breaks
                // it). Tolerate a few windows for a merely-slow link — any
                // progress resets the count — then declare the peer dead.
                stalls += 1
                if stalls >= maxWriteStalls { return .stalled }
                continue
            }
            if w <= 0 { return .eof }   // hard error
        }
        return .more
    }

    /// Bidirectional byte pump between two full-duplex fds, half-close aware:
    /// when one direction ends, keep draining the other until it also ends.
    static func splice(_ a: Int32, _ b: Int32) {
        // Every forwarded byte stream (loopback shim, relay data leg, SSH channel
        // splice) passes through here — the one place to kill Nagle on both ends
        // so interactive traffic isn't buffered. No-ops harmlessly on the AF_UNIX
        // / loopback ends.
        SocketTuning.tuneInteractive(a, keepalive: false)
        SocketTuning.tuneInteractive(b, keepalive: false)
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let pollIn = Int16(POLLIN)
        var aOpen = true, bOpen = true   // "still readable"
        pump: while aOpen || bOpen {
            var fds = [pollfd(fd: aOpen ? a : -1, events: pollIn, revents: 0),
                       pollfd(fd: bOpen ? b : -1, events: pollIn, revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if aOpen, fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                switch copyOnce(a, b, &buf) {
                case .more:    break
                case .eof:     aOpen = false; Darwin.shutdown(b, SHUT_WR)
                case .stalled: break pump   // `b` is a dead peer → close both now
                }
            }
            if bOpen, fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                switch copyOnce(b, a, &buf) {
                case .more:    break
                case .eof:     bOpen = false; Darwin.shutdown(a, SHUT_WR)
                case .stalled: break pump   // `a` is a dead peer → close both now
                }
            }
        }
        // A dead-peer stall (or both directions ended) closes BOTH fds: closing
        // sshFD is what fires NIOSSH's channelInactive and reaps the session/PTY;
        // half-closing and lingering would just move the hang into poll().
        Darwin.close(a); Darwin.close(b)
    }

    /// Like `splice` but for a process with SEPARATE stdin/stdout fds bridged to
    /// one full-duplex `sock`. Does not close the std fds.
    static func proxy(inFD: Int32, outFD: Int32, sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let pollIn = Int16(POLLIN)
        var inOpen = true, sockOpen = true
        while inOpen || sockOpen {
            var fds = [pollfd(fd: inOpen ? inFD : -1, events: pollIn, revents: 0),
                       pollfd(fd: sockOpen ? sock : -1, events: pollIn, revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if inOpen, fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if copyOnce(inFD, sock, &buf) != .more { inOpen = false; Darwin.shutdown(sock, SHUT_WR) }
            }
            if sockOpen, fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if copyOnce(sock, outFD, &buf) != .more { sockOpen = false }
            }
        }
        Darwin.close(sock)
    }

    /// Bind a local TCP listener on 127.0.0.1 (or 0.0.0.0) : `localPort`.
    static func listen(port: Int, bindAll: Bool) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = bindAll ? INADDR_ANY : inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 64) == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    /// Bind an ephemeral-port listener (`bindAll` → 0.0.0.0, else loopback);
    /// returns the fd and the actual port, or (-1, 0) on failure. The browser
    /// pane binds 0.0.0.0 so the guest can reach it at the vmnet gateway (the
    /// gateway IP isn't on the host until the switch starts, so we can't bind it
    /// directly); `acceptSocks`'s peer filter keeps it from being an open relay.
    static func listenEphemeral(bindAll: Bool = false) -> (fd: Int32, port: Int) {
        let fd = listen(port: 0, bindAll: bindAll)
        guard fd >= 0 else { return (-1, 0) }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { Darwin.close(fd); return (-1, 0) }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    /// Dotted-quad of an accepted peer's IPv4 address (network byte order).
    static func peerIPv4(_ addr: sockaddr_in) -> String {
        let a = addr.sin_addr.s_addr
        return "\(a & 0xff).\((a >> 8) & 0xff).\((a >> 16) & 0xff).\((a >> 24) & 0xff)"
    }
}
