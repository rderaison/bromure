import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Privileged setup for the system-wide subnet tunnel

/// The root-only operations behind `FatClientTunnel`: open a utun, assign it an
/// address, route the remote subnet to it, and install a `pf` rdr rule that
/// redirects that subnet's TCP to the local forwarder port. Creating a utun
/// (SYSPROTO_CONTROL), `route`, and `pfctl` all require root — so in production
/// these run inside a launchd privileged helper (SMAppService/SMJobBless),
/// installed with user consent on first use. Here the operations are implemented
/// directly; they no-op gracefully (return nil / false) when not privileged, so
/// the app degrades to the SOCKS/PAC browser path.
///
/// Gate this behind the plan's spike (`scripts/utun-spike.py`) before enabling.
final class FatClientTunnelHelper: @unchecked Sendable {
    static let shared = FatClientTunnelHelper()
    private init() {}

    private let lock = NSLock()
    /// Open utun fds, kept alive per interface (closing the fd destroys the utun).
    private var utunFDs: [String: Int32] = [:]
    /// A distinct 10.98.<n>.0/30 link net per utun so several can coexist.
    private var nextLinkOctet = 1

    private let pfAnchor = "io.bromure.fatclient"

    /// Create utun + route `cidr` to it + pf rdr `cidr` tcp → 127.0.0.1:port.
    /// Returns the utun name, or nil if any privileged step failed.
    func setup(cidr: String, redirectPort: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let (fd, name) = Self.openUtun() else { return nil }
        let link = nextLinkOctet; nextLinkOctet += 1
        let addr = "10.98.\(link).1", peer = "10.98.\(link).2"
        guard Self.run("/sbin/ifconfig", [name, addr, peer, "up"]),
              Self.run("/sbin/route", ["-n", "add", "-net", cidr, "-interface", name]),
              installPFRedirect(utun: name, cidr: cidr, port: redirectPort) else {
            Darwin.close(fd)
            return nil
        }
        utunFDs[name] = fd
        return name
    }

    /// Remove the route, the pf rule, and the utun for `cidr`/`utun`.
    func teardown(cidr: String, utun: String) {
        lock.lock(); defer { lock.unlock() }
        _ = Self.run("/sbin/route", ["-n", "delete", "-net", cidr])
        _ = Self.run("/sbin/pfctl", ["-a", pfAnchor, "-F", "nat"])
        if let fd = utunFDs.removeValue(forKey: utun) { Darwin.close(fd) }   // destroys the utun
    }

    /// Load the rdr rule into our pf anchor and ensure pf is enabled. The anchor
    /// keeps our rule isolated from the system ruleset.
    private func installPFRedirect(utun: String, cidr: String, port: Int) -> Bool {
        let rule = "rdr on \(utun) inet proto tcp to \(cidr) -> 127.0.0.1 port \(port)\n"
        let tmp = NSTemporaryDirectory() + "bromure-pf-\(utun).conf"
        guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // -e may report "already enabled" (exit 1) — that's fine; the anchor load
        // is what must succeed.
        _ = Self.run("/sbin/pfctl", ["-e"])
        return Self.run("/sbin/pfctl", ["-a", pfAnchor, "-f", tmp])
    }

    /// `_IOWR('N', 3, struct ctl_info)` — not surfaced by Swift's Darwin module.
    private static let CTLIOCGINFO: UInt = 0xC064_4E03

    /// Open a utun control socket and return its fd + interface name (root-only).
    private static func openUtun() -> (fd: Int32, name: String)? {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { return nil }
        // struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; }
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { raw in
            let n = "com.apple.net.utun_control"
            for (i, b) in n.utf8.enumerated() where i < 96 { raw[i] = b }
        }
        guard ioctl(fd, CTLIOCGINFO, &info) == 0 else { Darwin.close(fd); return nil }
        var sc = sockaddr_ctl()
        sc.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        sc.sc_family = UInt8(AF_SYSTEM)
        sc.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        sc.sc_id = info.ctl_id
        sc.sc_unit = 0   // pick a free utun
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

    /// Run a command; true on exit 0. Returns false if it couldn't launch (e.g.
    /// not privileged) — the caller then degrades to SOCKS/PAC.
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
}
