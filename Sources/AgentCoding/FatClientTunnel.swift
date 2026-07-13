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
        guard let dev = FatClientTunnelHelper.shared.setup(cidr: localCIDR, redirectPort: p) else {
            FatClientLog.log("tunnel: privileged setup failed (helper installed? run scripts/utun-spike.py)")
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
                guard let (ip, port) = OriginalDestination.lookup(fd: cfd) else {
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

// MARK: - Original destination recovery (pf DIOCNATLOOK)

/// Recovers the pre-redirect destination of a `pf`-rdr'd TCP connection via
/// `DIOCNATLOOK` on `/dev/pf` (macOS has no `SO_ORIGINAL_DST`). Requires root, so
/// this runs inside the privileged helper alongside the forwarder.
enum OriginalDestination {
    // struct pfioc_natlook — 4× pf_addr(16B) + 4× u16 + af/proto/variant/dir.
    private struct pfioc_natlook {
        var saddr = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var daddr = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var rsaddr = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var rdaddr = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var sport: UInt16 = 0
        var dport: UInt16 = 0
        var rsport: UInt16 = 0
        var rdport: UInt16 = 0
        var af: UInt8 = 0
        var proto: UInt8 = 0
        var proto_variant: UInt8 = 0
        var direction: UInt8 = 0
    }

    /// `(ip, port)` the connection was originally headed to, or nil.
    static func lookup(fd: Int32) -> (ip: String, port: Int)? {
        // Local (redirected) and peer addresses of the accepted socket.
        var local = sockaddr_in(), peer = sockaddr_in()
        var ll = socklen_t(MemoryLayout<sockaddr_in>.size)
        var pl = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &local, { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &ll) } }) == 0,
              withUnsafeMutablePointer(to: &peer, { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &pl) } }) == 0
        else { return nil }

        let pf = open("/dev/pf", O_RDWR)
        guard pf >= 0 else { return nil }
        defer { close(pf) }

        var nl = pfioc_natlook()
        nl.af = UInt8(AF_INET)
        nl.proto = UInt8(IPPROTO_TCP)
        nl.direction = 2   // PF_OUT
        // saddr/sport = the connection's source (our peer); daddr/dport = the
        // redirected local socket; pf maps them back to the original dst.
        withUnsafeBytes(of: peer.sin_addr) { src in
            withUnsafeMutableBytes(of: &nl.saddr) { $0.copyBytes(from: src.prefix(4)) }
        }
        withUnsafeBytes(of: local.sin_addr) { dst in
            withUnsafeMutableBytes(of: &nl.daddr) { $0.copyBytes(from: dst.prefix(4)) }
        }
        nl.sport = peer.sin_port
        nl.dport = local.sin_port

        let sz = MemoryLayout<pfioc_natlook>.size
        // DIOCNATLOOK = _IOWR('D', 23, struct pfioc_natlook)
        let req = UInt(0xC000_0000) | (UInt(sz & 0x1FFF) << 16) | (UInt(UInt8(ascii: "D")) << 8) | 23
        let rc = withUnsafeMutablePointer(to: &nl) { ioctl(pf, req, $0) }
        guard rc == 0 else { return nil }
        let ip = withUnsafeBytes(of: nl.rdaddr) { "\($0[0]).\($0[1]).\($0[2]).\($0[3])" }
        return (ip, Int(UInt16(bigEndian: nl.rdport)))
    }
}
