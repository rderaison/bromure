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
        guard P2PIdentity.current() != nil else { P2PBroker.shared.stopServing(); return }
        if config.multiUser {
            guard let port = P2PIngressForwarder.shared.ensure(gatewaySocket: config.gatewayP2PSocket) else {
                FileHandle.standardError.write(Data("bromure-ac daemon: P2P not served: no ingress port\n".utf8))
                return
            }
            P2PBroker.shared.startServing(sshPort: port)
        } else {
            let s = RemoteSettings.load(remoteSettingsPath)
            guard s.enabled else { P2PBroker.shared.stopServing(); return }
            P2PBroker.shared.startServing(sshPort: s.port)
        }
    }
}

/// A multi-user server's per-user P2P ingress: a TCP listener (all
/// interfaces, an ephemeral port: the one this user's broker announces and
/// maps) whose every connection is spliced into the gateway's P2P socket,
/// connected as this daemon's user, so the gateway pins it to this account.
// @port-skip linux-only: the multi-user server's per-user P2P ingress
final class P2PIngressForwarder: @unchecked Sendable {
    static let shared = P2PIngressForwarder()
    private let state = NIOLockedValueBox<(fd: Int32, port: Int)>((-1, 0))

    /// The ingress port, listening (made on first use), or nil.
    // @port-skip linux-only: see P2PIngressForwarder
    func ensure(gatewaySocket: String) -> Int? {
        state.withLockedValue { s -> Int? in
            if s.fd >= 0 { return s.port }
            let (fd, port) = FatForward.listenEphemeral(bindAll: true)
            guard fd >= 0 else { return nil }
            s = (fd, port)
            Thread.detachNewThread { Self.acceptLoop(fd, gatewaySocket: gatewaySocket) }
            return port
        }
    }

    // @port-skip linux-only: see P2PIngressForwarder
    static func acceptLoop(_ lfd: Int32, gatewaySocket: String) {
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; return }
            Thread.detachNewThread {
                guard let gfd = connectUnix(gatewaySocket) else { close(cfd); return }
                SocketTuning.tuneInteractive(cfd)
                FatForward.splice(cfd, gfd)
            }
        }
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
