import Foundation
import ServiceManagement
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Privileged daemon install (SMAppService)

/// Registers the root tunnel daemon as a launchd daemon via SMAppService. The
/// first registration surfaces an approval toggle in System Settings > Login
/// Items; the app can't grant it. Callers fall back to SOCKS/PAC until enabled.
enum FatClientTunnelInstaller {
    static let plistName = "io.bromure.fatclient-tunnel.plist"

    /// True once the daemon is registered AND enabled (running). Attempts a
    /// registration if it's never been done; otherwise reports the current state.
    @discardableResult
    static func ensureRegistered() -> Bool {
        let svc = SMAppService.daemon(plistName: plistName)
        switch svc.status {
        case .enabled:
            return true
        case .requiresApproval:
            FatClientLog.log("tunnel: daemon needs approval — System Settings › General › Login Items")
            return false
        default:
            do {
                try svc.register()
                FatClientLog.log("tunnel: daemon register requested (status=\(svc.status.rawValue))")
            } catch {
                FatClientLog.log("tunnel: SMAppService register failed: \(error)")
            }
            return svc.status == .enabled
        }
    }
}

// MARK: - App-side client for the privileged tunnel daemon

/// The app talks to the root `FatClientTunnelDaemon` over its owner-only Unix
/// socket to set up / tear down the utun+route+pf and to recover the original
/// destination of a redirected connection (all root-only). The forwarder itself
/// stays in the app (`FatClientTunnel`) so `forwardDial` uses the user's SSH
/// identity, not root's. If the daemon isn't installed/reachable, every call
/// fails and the tunnel degrades to the SOCKS/PAC browser path.
final class FatClientTunnelHelper: @unchecked Sendable {
    static let shared = FatClientTunnelHelper()
    private init() {}

    func setup(cidr: String, redirectPort: Int) -> String? {
        guard let r = request("SETUP \(cidr) \(redirectPort)"), r.hasPrefix("OK ") else { return nil }
        return String(r.dropFirst(3))
    }

    func teardown(cidr: String, utun: String) {
        _ = request("TEARDOWN \(cidr) \(utun)")
    }

    /// Original (pre-rdr) destination of a redirected connection, via the daemon's
    /// DIOCNATLOOK. `srcIP/srcPort` = the connection's source (our peer);
    /// `dstIP/dstPort` = the redirected local socket.
    func lookup(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) -> (ip: String, port: Int)? {
        guard let r = request("LOOKUP \(srcIP) \(srcPort) \(dstIP) \(dstPort)"), r.hasPrefix("OK ") else { return nil }
        let f = r.dropFirst(3).split(separator: " ")
        guard f.count == 2, let port = Int(f[1]) else { return nil }
        return (String(f[0]), port)
    }

    /// Send one request line to the daemon, read one reply line.
    private func request(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = FatClientTunnelDaemon.socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) }
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        var out = Data((line + "\n").utf8)
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        var data = Data(); var b = [UInt8](repeating: 0, count: 256)
        while data.count < 1024 {
            let n = read(fd, &b, b.count)
            if n <= 0 { break }
            data.append(contentsOf: b[0..<n])
            if data.last == 0x0A { break }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Root-only operations (run inside the daemon)

/// The privileged operations: open a utun, route a subnet to it, install a `pf`
/// rdr rule, and `DIOCNATLOOK`. All require root — invoked only by
/// `FatClientTunnelDaemon`. See `scripts/utun-spike.py` (validated: PASS) for the
/// utun+route mechanism these build on.
enum TunnelPrivilegedOps {
    private static let pfAnchor = "io.bromure.fatclient"
    private static let lock = NSLock()
    private static var utunFDs: [String: Int32] = [:]
    private static var nextLinkOctet = 1

    static func setup(cidr: String, redirectPort: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let (fd, name) = openUtun() else { return nil }
        let link = nextLinkOctet; nextLinkOctet += 1
        let addr = "10.98.\(link).1", peer = "10.98.\(link).2"
        guard run("/sbin/ifconfig", [name, addr, peer, "up"]),
              run("/sbin/route", ["-n", "add", "-net", cidr, "-interface", name]),
              installPFRedirect(utun: name, cidr: cidr, port: redirectPort) else {
            Darwin.close(fd); return nil
        }
        utunFDs[name] = fd
        return name
    }

    static func teardown(cidr: String, utun: String) {
        lock.lock(); defer { lock.unlock() }
        _ = run("/sbin/route", ["-n", "delete", "-net", cidr])
        _ = run("/sbin/pfctl", ["-a", pfAnchor, "-F", "nat"])
        if let fd = utunFDs.removeValue(forKey: utun) { Darwin.close(fd) }   // destroys the utun
    }

    private static func installPFRedirect(utun: String, cidr: String, port: Int) -> Bool {
        let rule = "rdr on \(utun) inet proto tcp to \(cidr) -> 127.0.0.1 port \(port)\n"
        let tmp = NSTemporaryDirectory() + "bromure-pf-\(utun).conf"
        guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        _ = run("/sbin/pfctl", ["-e"])   // may already be enabled (that's fine)
        return run("/sbin/pfctl", ["-a", pfAnchor, "-f", tmp])
    }

    /// `_IOWR('N', 3, struct ctl_info)` — not surfaced by Swift's Darwin module.
    private static let CTLIOCGINFO: UInt = 0xC064_4E03

    private static func openUtun() -> (fd: Int32, name: String)? {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { return nil }
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { raw in
            for (i, b) in "com.apple.net.utun_control".utf8.enumerated() where i < 96 { raw[i] = b }
        }
        guard ioctl(fd, CTLIOCGINFO, &info) == 0 else { Darwin.close(fd); return nil }
        var sc = sockaddr_ctl()
        sc.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        sc.sc_family = UInt8(AF_SYSTEM)
        sc.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        sc.sc_id = info.ctl_id
        sc.sc_unit = 0
        let ok = withUnsafePointer(to: &sc) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        var nameBuf = [CChar](repeating: 0, count: 64)
        var len = socklen_t(nameBuf.count)
        guard getsockopt(fd, SYSPROTO_CONTROL, 2 /*UTUN_OPT_IFNAME*/, &nameBuf, &len) == 0 else {
            Darwin.close(fd); return nil
        }
        return (fd, String(cString: nameBuf))
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// DIOCNATLOOK: given a redirected connection's source + redirected-local
    /// address, return the ORIGINAL destination pf mapped it from. The C struct
    /// `pfioc_natlook` is 76 bytes: 4× pf_addr(16) + 4× u16 + af/proto/variant/dir;
    /// we lay it out by hand so the size (→ the ioctl request number) matches the
    /// kernel exactly regardless of Swift's struct padding.
    static func natLook(srcIP: String, srcPort: UInt16, dstIP: String, dstPort: UInt16) -> (ip: String, port: Int)? {
        let pf = open("/dev/pf", O_RDWR)
        guard pf >= 0 else { return nil }
        defer { close(pf) }
        var s = in_addr(), d = in_addr()
        guard inet_pton(AF_INET, srcIP, &s) == 1, inet_pton(AF_INET, dstIP, &d) == 1 else { return nil }

        let sz = 76
        var buf = [UInt8](repeating: 0, count: sz)
        withUnsafeBytes(of: s.s_addr) { for i in 0..<4 { buf[i] = $0[i] } }        // saddr @0
        withUnsafeBytes(of: d.s_addr) { for i in 0..<4 { buf[16 + i] = $0[i] } }   // daddr @16
        withUnsafeBytes(of: srcPort.bigEndian) { buf[64] = $0[0]; buf[65] = $0[1] } // sport @64
        withUnsafeBytes(of: dstPort.bigEndian) { buf[66] = $0[0]; buf[67] = $0[1] } // dport @66
        buf[72] = UInt8(AF_INET)      // af @72
        buf[73] = UInt8(IPPROTO_TCP)  // proto @73
        buf[75] = 2                   // direction = PF_OUT @75

        // DIOCNATLOOK = _IOWR('D', 23, struct pfioc_natlook)
        let req = UInt(0xC000_0000) | (UInt(sz & 0x1FFF) << 16) | (UInt(UInt8(ascii: "D")) << 8) | 23
        let rc = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            ioctl(pf, req, bp.baseAddress!)
        }
        guard rc == 0 else { return nil }
        // rdaddr is the 4th pf_addr (offset 48); rdport at offset 70.
        let ip = "\(buf[48]).\(buf[49]).\(buf[50]).\(buf[51])"
        let rdport = (UInt16(buf[70]) << 8) | UInt16(buf[71])
        return (ip, Int(rdport))
    }
}
