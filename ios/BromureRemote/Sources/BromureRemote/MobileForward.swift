import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Loopback → VM TCP forwarder (iOS)
//
// Presents a stable `http://127.0.0.1:<localPort>` on the phone that byte-pumps
// each connection to a workspace VM's `<ip>:<port>` over the fat-client SSH
// tunnel — the existing `bromure-fatclient/1 forward <ip> <port>` verb the
// desktop already uses to reach the remote workspace subnet. A WKWebView then
// loads the loopback URL and, transparently, browses a dev server running
// inside the VM, reachable over the same P2P connection everything else uses.
//
// One forwarder per (host, vmIP, vmPort). Loopback-only (never bindAll on a
// device); the accept loop opens a fresh SSH forward channel per connection so
// a page's parallel resource loads each get their own byte pipe.
final class MobileForward: @unchecked Sendable {
    /// The local URL a WKWebView loads.
    let localURL: URL
    /// The ephemeral loopback port `localURL` binds — exposed so callers can
    /// build path/query-bearing or non-http URLs onto the same tunnel.
    let localPort: Int
    let vmPort: Int
    private let lfd: Int32
    private let host: RemoteHost
    private let vmIP: String
    private let lock = NSLock()
    private var stopped = false

    init?(host: RemoteHost, vmIP: String, vmPort: Int) {
        let (fd, port) = FatForward.listenEphemeral(bindAll: false)   // 127.0.0.1 only
        guard fd >= 0, let url = URL(string: "http://127.0.0.1:\(port)/") else {
            if fd >= 0 { Darwin.close(fd) }
            return nil
        }
        self.lfd = fd
        self.localURL = url
        self.localPort = Int(port)
        self.host = host
        self.vmIP = vmIP
        self.vmPort = vmPort
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        let verb = FatClient.forwardVerbPrefix + "\(vmIP) \(vmPort)"
        let h = host
        while true {
            let cfd = Darwin.accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }   // lfd closed → stop
            lock.lock(); let isStopped = stopped; lock.unlock()
            if isStopped { Darwin.close(cfd); break }
            Thread.detachNewThread {
                // Peer hosts resolve to their live loopback endpoint first (a
                // no-op for a by-address host). Then open a raw forward channel
                // on the pooled SSH connection and splice the two together.
                let resolved = RemoteTransport.resolved(h)
                guard let rfd = SSHDialer.shared.dial(host: resolved, verb: verb) else {
                    Darwin.close(cfd); return
                }
                FatForward.splice(cfd, rfd)
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        // shutdown() is useless here: xnu's soshutdown() returns ENOTCONN for
        // a socket with none of SS_ISCONNECTED/SS_ISCONNECTING/SS_ISDISCONNECTING
        // — which a listening socket never has — so it cannot wake the parked
        // accept. The reliable Darwin wakeup is a self-connect: acceptLoop
        // returns our connection, sees `stopped`, closes it, and breaks.
        wakeAccept()
        Darwin.close(lfd)
    }

    /// Connect to our own loopback listener so the accept parked in
    /// `acceptLoop` returns. Instant on loopback (the queue is empty whenever
    /// the accept thread is parked, which is exactly the case being woken).
    private func wakeAccept() {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        defer { Darwin.close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(localPort).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    deinit { stop() }
}
