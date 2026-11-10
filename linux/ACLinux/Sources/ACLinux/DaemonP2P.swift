import Foundation
import Glibc
import NIOConcurrencyHelpers

/// This user's P2P serving (macOS: P2PBroker.shared.startServing beside
/// the SSH front door): when signed in to bromure.io, the broker announces
/// a port that reaches this user's SSH and nothing else. A single-user
/// server's is its own front door. A multi-user server's users have none
/// (the gateway serves them all): each user's broker has an ingress port of
/// its own (P2PIngressForwarder), every connection to it (direct, or a TURN
/// relay leg) handed to the gateway's P2P socket, which pins it to this
/// user's account (SO_PEERCRED: this daemon's uid). A client paired with
/// this user's identity can't reach another account, and this broker can't
/// announce or serve another user's port.
extension Daemon {
    // partial: the front door's port on a single-user server; on a multi-user one, this user's ingress into the gateway
    // @port ACAppDelegate.startRemoteAccessIfNeeded() h=1b169b783684295d @d3ebbda2
    func refreshP2PServing() async {
        guard P2PIdentity.current() != nil else { stopP2PServing(); return }
        if config.multiUser {
            // The admin's call (bromure-ac admin p2p): off, nothing announced.
            let settings = P2PSettings.load()
            guard settings.enabled else { stopP2PServing(); return }
            guard let port = P2PIngressForwarder.shared.ensure(gatewaySocket: config.gatewayP2PSocket,
                                                               bindAddress: settings.bindAddress) else {
                FileHandle.standardError.write(Data("bromure-ac daemon: P2P not served: no ingress port\n".utf8))
                return
            }
            P2PBroker.shared.startServing(sshPort: port)
        } else {
            let s = RemoteSettings.load(remoteSettingsPath)
            guard s.enabled else { stopP2PServing(); return }
            P2PBroker.shared.startServing(sshPort: s.port)
        }
    }

    /// A multi-user daemon re-reads the admin's P2P switch every 30 s and
    /// follows it (on: serve; off: stop, the ingress closed).
    // @port-skip linux-only: see refreshP2PServing
    func watchP2PSettings(every interval: Duration = .seconds(30)) {
        guard config.multiUser else { return }
        Task { [weak self] in
            var last = P2PSettings.load()
            while true {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let now = P2PSettings.load()
                if now != last { last = now; await self.refreshP2PServing() }
            }
        }
    }

    /// Not served any more: the broker stops, the ingress port closes.
    // @port-skip linux-only: see refreshP2PServing
    func stopP2PServing() {
        P2PBroker.shared.stopServing()
        P2PIngressForwarder.shared.stop()
    }
}

/// A multi-user server's per-user P2P ingress: a TCP listener (on the
/// admin's address, an ephemeral port: the one this user's broker announces
/// and maps) whose every connection is spliced into the gateway's P2P
/// socket, connected as this daemon's user, so the gateway pins it to this
/// account; each starts with a PROXY v1 line naming the client, for the
/// gateway's per-client password limit.
// @port-skip linux-only: the multi-user server's per-user P2P ingress
final class P2PIngressForwarder: @unchecked Sendable {
    static let shared = P2PIngressForwarder()
    private let state = NIOLockedValueBox<(fd: Int32, port: Int)>((-1, 0))
    /// Connections being spliced; more than `maxConnections` at once are closed.
    private static let open = NIOLockedValueBox(0)
    static let maxConnections = 64

    /// The ingress port, listening (made on first use), or nil.
    // @port-skip linux-only: see P2PIngressForwarder
    func ensure(gatewaySocket: String, bindAddress: String? = nil) -> Int? {
        state.withLockedValue { s -> Int? in
            if s.fd >= 0 { return s.port }
            guard let (fd, port) = Self.listen(on: bindAddress ?? "0.0.0.0") else { return nil }
            s = (fd, port)
            Thread.detachNewThread { Self.acceptLoop(fd, gatewaySocket: gatewaySocket) }
            return port
        }
    }

    /// The ingress closed (P2P not served any more); a later ensure opens a new one.
    // @port-skip linux-only: see P2PIngressForwarder
    func stop() {
        let fd = state.withLockedValue { s -> Int32 in let fd = s.fd; s = (-1, 0); return fd }
        guard fd >= 0 else { return }
        Glibc.shutdown(fd, Int32(SHUT_RDWR))   // wakes the accept
        close(fd)
    }

    /// A listener on `address` (numeric, v4 or v6), an ephemeral port.
    // @port-skip linux-only: see P2PIngressForwarder
    static func listen(on address: String) -> (Int32, Int)? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_PASSIVE
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, "0", &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0, Glibc.listen(fd, 64) == 0 else { close(fd); return nil }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, endpoint(ss).port)
    }

    // @port-skip linux-only: see P2PIngressForwarder
    static func acceptLoop(_ lfd: Int32, gatewaySocket: String) {
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; return }
            guard open.withLockedValue({ n -> Bool in guard n < maxConnections else { return false }; n += 1; return true }) else {
                close(cfd); continue
            }
            Thread.detachNewThread {
                defer { open.withLockedValue { $0 -= 1 } }
                guard let gfd = connectUnix(gatewaySocket) else { close(cfd); return }
                let line = Array(proxyLine(cfd).utf8)
                guard line.withUnsafeBytes({ Glibc.write(gfd, $0.baseAddress, $0.count) }) == line.count else {
                    close(cfd); close(gfd); return
                }
                SocketTuning.tuneInteractive(cfd)
                FatForward.splice(cfd, gfd)
            }
        }
    }

    /// The PROXY v1 line for an accepted connection (its client and our end).
    // @port-skip linux-only: see P2PIngressForwarder
    static func proxyLine(_ fd: Int32) -> String {
        var peer = sockaddr_storage(), local = sockaddr_storage()
        var pl = socklen_t(MemoryLayout<sockaddr_storage>.size), ll = pl
        let okPeer = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &pl) } } == 0
        let okLocal = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &ll) } } == 0
        let p = endpoint(peer), l = endpoint(local)
        guard okPeer, okLocal, let pip = p.ip, let lip = l.ip else { return "PROXY UNKNOWN\r\n" }
        return "PROXY \(peer.ss_family == sa_family_t(AF_INET6) ? "TCP6" : "TCP4") \(pip) \(lip) \(p.port) \(l.port)\r\n"
    }

    /// A socket address's numeric host and port.
    // @port-skip linux-only: see P2PIngressForwarder
    static func endpoint(_ ss: sockaddr_storage) -> (ip: String?, port: Int) {
        var ss = ss
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)), serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let len = socklen_t(ss.ss_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, len, &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV) } }
        guard rc == 0 else { return (nil, 0) }
        return (String(cString: host), Int(String(cString: serv)) ?? 0)
    }

    /// A stream to the Unix socket at `path`, or nil.
    // @port-skip linux-only: see P2PIngressForwarder
    static func connectUnix(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in p.copyBytes(from: bytes); p[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }
}
