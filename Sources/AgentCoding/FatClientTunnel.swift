import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - System-wide subnet tunnel (utun + pf transparent proxy)

/// Makes a connected remote's workspace subnet reachable from ANY local process
/// at its literal address (`curl 192.168.64.5:3000`, a script, the host) — not
/// just a SOCKS-configured browser. This is the optional system-wide counterpart
/// to the browser pane's SOCKS/PAC path (which needs no privilege).
///
/// Design (macOS transparent proxy — reuses the KERNEL's TCP stack, so no
/// userspace TCP reimplementation):
///
///   route: 192.168.64.0/24 → utunN
///   pf:    rdr on utunN proto tcp to 192.168.64.0/24 -> 127.0.0.1 port <P>
///   app:   listen on 127.0.0.1:<P>; per accept, recover the ORIGINAL dst via
///          DIOCNATLOOK on /dev/pf, then RemoteTransport.forwardDial(ip,port) +
///          FatForward.splice — the exact byte pipe the SOCKS path already uses.
///
/// The utun open, the route, the pf rules, and `/dev/pf` all require root, so the
/// whole forwarder runs inside the privileged helper (see `FatClientTunnelHelper`).
/// Before shipping this, run `scripts/utun-spike.py` (plan spike #1) to confirm a
/// host utun route actually catches the subnet on this OS.
///
/// Fleet: overlapping subnets can't both route literally — `FleetRouter` assigns
/// a `100.64.<n>.0/24` alias on collision, and this tunnel routes the alias while
/// the `browser-mcp` relay remaps advertised addresses.
final class FatClientTunnel {
    let host: RemoteHost
    /// The subnet this tunnel routes locally (literal or FleetRouter alias).
    let localCIDR: String
    /// If aliased, the remote's real subnet (forwardDial targets get remapped
    /// back to it); nil for a literal route.
    let remoteCIDR: String?

    private var lfd: Int32 = -1
    private var port: Int = 0
    private var utun: String?
    private var running = false

    init(host: RemoteHost, localCIDR: String, remoteCIDR: String? = nil) {
        self.host = host
        self.localCIDR = localCIDR
        self.remoteCIDR = remoteCIDR
    }

    /// Bring the tunnel up: bind the local listener, then have the privileged
    /// helper create the utun + route + pf rdr pointing at it. Returns false if
    /// the listener couldn't bind or the privileged setup failed.
    @discardableResult
    func start() -> Bool {
        guard !running else { return true }
        let (fd, p) = FatForward.listenEphemeral(bindAll: false)   // 127.0.0.1:<P>
        guard fd >= 0 else {
            FatClientLog.log("tunnel: couldn't bind local listener"); return false
        }
        lfd = fd; port = p
        // Ensure the privileged daemon is installed (first use prompts approval
        // in System Settings); until enabled, setup fails and we stay on SOCKS.
        FatClientTunnelInstaller.ensureRegistered()
        guard let dev = FatClientTunnelHelper.shared.setup(cidr: localCIDR, redirectPort: p) else {
            FatClientLog.log("tunnel: privileged setup failed (daemon approved? see System Settings › Login Items)")
            Darwin.close(fd); lfd = -1; return false
        }
        utun = dev
        running = true
        FatClientLog.log("tunnel: \(localCIDR) → \(dev) → rdr 127.0.0.1:\(p) → forward \(host.connectLabel)")
        Thread.detachNewThread { [host, remoteCIDR] in
            FatClientTunnel.acceptLoop(lfd: fd, host: host, remoteCIDR: remoteCIDR)
        }
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        if let dev = utun { FatClientTunnelHelper.shared.teardown(cidr: localCIDR, utun: dev) }
        if lfd >= 0 { Darwin.close(lfd); lfd = -1 }   // breaks acceptLoop
        utun = nil
    }

    /// Map an aliased local address (`100.64.<n>.x`) back to the remote's real
    /// address (`<remote net>.x`), preserving the host octet. Identity for a
    /// literal route (`remoteCIDR == nil`).
    static func aliasToRemote(_ ip: String, remoteCIDR: String?) -> String {
        guard let rc = remoteCIDR, let (rNet, _) = FatClientPAC.parseCIDR(rc) else { return ip }
        let host = ip.split(separator: ".", omittingEmptySubsequences: false)
        let net = rNet.split(separator: ".")
        guard host.count == 4, net.count == 4 else { return ip }
        return "\(net[0]).\(net[1]).\(net[2]).\(host[3])"
    }

    /// Accept redirected connections; recover the original destination and splice
    /// it to a `forward` channel. Exits when `lfd` is closed.
    private static func acceptLoop(lfd: Int32, host: RemoteHost, remoteCIDR: String?) {
        while true {
            let cfd = Darwin.accept(lfd, nil, nil)
            if cfd < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread {
                // Recover addresses app-side (no root), then ask the daemon to
                // DIOCNATLOOK the pre-rdr destination.
                guard let (localIP, localPort) = Self.sockAddr(cfd, peer: false),
                      let (peerIP, peerPort) = Self.sockAddr(cfd, peer: true),
                      let (ip, port) = FatClientTunnelHelper.shared.lookup(
                        srcIP: peerIP, srcPort: peerPort, dstIP: localIP, dstPort: localPort) else {
                    Darwin.close(cfd); return
                }
                // Aliased route: `ip` is a 100.64.<n>.x alias the local process
                // connected to; translate it back to the remote's real address
                // (host octet preserved) before asking A to dial it. Literal
                // routes pass through unchanged.
                let target = aliasToRemote(ip, remoteCIDR: remoteCIDR)
                guard let rfd = RemoteTransport.forwardDial(host: host, ip: target, port: port), rfd >= 0 else {
                    Darwin.close(cfd); return
                }
                FatForward.splice(cfd, rfd)
            }
        }
    }
}

extension FatClientTunnel {
    /// The IPv4 address+port of an accepted socket's local (redirected) or peer
    /// end — needed to ask the daemon for the pre-rdr destination. No root.
    static func sockAddr(_ fd: Int32, peer: Bool) -> (ip: String, port: UInt16)? {
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &sa) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? getpeername(fd, $0, &len) : getsockname(fd, $0, &len)
            }
        }
        guard rc == 0 else { return nil }
        let a = sa.sin_addr.s_addr
        let ip = "\(a & 0xff).\((a >> 8) & 0xff).\((a >> 16) & 0xff).\((a >> 24) & 0xff)"
        return (ip, UInt16(bigEndian: sa.sin_port))
    }
}
