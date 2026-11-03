import Foundation
import ServiceManagement
#if canImport(Darwin)
import Darwin
#endif

// MARK: - System-wide subnet tunnel (utun + userspace TCP)

/// Makes a connected remote's workspace subnet reachable from ANY local process
/// at its literal address (`curl 192.168.64.5:3000`, scripts, the host) — the
/// optional system-wide counterpart to the browser pane's SOCKS/PAC path.
///
/// The privileged daemon (`FatClientTunnelDaemon`) creates a utun + routes the
/// subnet to it and hands us the utun fd. We (the user) read raw packets and run
/// a userspace TCP stack (`UtunForwarder`) that terminates each flow and splices
/// it to `RemoteTransport.forwardDial`, so it uses the user's SSH identity. No
/// pf, no kernel forwarding: the kernel writes the process's packets to the utun,
/// we speak TCP back to it and carry the bytes to the remote guest.
///
/// Off unless `BROMURE_FATCLIENT_UTUN` is set and the daemon is installed
/// (SMAppService); otherwise the browser pane still works via SOCKS/PAC.
final class FatClientTunnel {
    let host: RemoteHost
    let localCIDR: String        // routed subnet (literal or FleetRouter alias)
    let remoteCIDR: String?      // remote's real subnet if aliased; nil if literal

    private var connFD: Int32 = -1   // daemon connection — closing it deletes the route
    private var utunFD: Int32 = -1
    private var forwarder: UtunForwarder?
    private var running = false

    init(host: RemoteHost, localCIDR: String, remoteCIDR: String? = nil) {
        self.host = host
        self.localCIDR = localCIDR
        self.remoteCIDR = remoteCIDR
    }

    /// Ensure the daemon is installed, ask it to create the utun + route, receive
    /// the utun fd, and start the userspace forwarder. Returns nil on success,
    /// or a user-facing reason (the app degrades to SOCKS) when the daemon
    /// isn't reachable/approved — callers surface it, never drop it.
    func start() -> String? {
        guard !running else { return nil }
        FatClientTunnelInstaller.ensureRegistered()
        let (fd, err) = Self.connectDaemon()
        guard fd >= 0 else {
            let why = FatClientTunnelDiagnosis.explainConnectFailure(
                errno: err, socket: FatClientTunnelDiagnosis.socketInfo(), myUID: getuid(),
                launchd: FatClientTunnelDiagnosis.launchdInfo(),
                registration: FatClientTunnelDiagnosis.registrationName(
                    SMAppService.daemon(plistName: FatClientTunnelInstaller.plistName).status))
            FatClientLog.log("tunnel: daemon not reachable — \(why)")
            return why
        }
        _ = "SETUP \(localCIDR)\n".withCString { Darwin.write(fd, $0, strlen($0)) }
        let reply = FatClientTunnelDaemon.recvFD(fd)
        guard let (msg, utun) = reply, msg.hasPrefix("OK "), utun >= 0 else {
            if let fdIn = reply?.fd, fdIn >= 0 { Darwin.close(fdIn) }
            Darwin.close(fd)
            let why = FatClientTunnelDiagnosis.explainSetupError(reply?.message, cidr: localCIDR)
            FatClientLog.log("tunnel: SETUP failed — \(reply?.message ?? "no reply")")
            return why
        }
        connFD = fd
        utunFD = utun
        running = true
        let fwd = UtunForwarder(utunFD: utun, host: host, localCIDR: localCIDR, remoteCIDR: remoteCIDR)
        forwarder = fwd
        Thread.detachNewThread { fwd.run() }
        FatClientLog.log("tunnel: up — \(localCIDR) → utun(fd \(utun)) → forward \(host.connectLabel)")
        return nil
    }

    func stop() {
        guard running else { return }
        running = false
        forwarder?.stop(); forwarder = nil
        if utunFD >= 0 { Darwin.close(utunFD); utunFD = -1 }
        if connFD >= 0 { Darwin.close(connFD); connFD = -1 }   // daemon deletes the route
    }

    /// The connected fd, or -1 and the connect errno.
    private static func connectDaemon() -> (fd: Int32, errno: Int32) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, errno) }
        // The helper may answer `ERR denied` and close before SETUP is written.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = FatClientTunnelDaemon.socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) } }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { let e = errno; Darwin.close(fd); return (-1, e) }
        return (fd, 0)
    }
}
