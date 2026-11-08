import Foundation
import Glibc
import NIOConcurrencyHelpers

/// A shared (multi-user) server's LAN address pools: which LAN addresses
/// each Bromure user's cluster load balancers may be published on. Granted
/// by the admin (`bromure-ac admin pool`), kept root-owned in
/// /etc/bromure-ac/lan-pools.json; bromure-lan publishes them (LANHelper),
/// and every daemon refuses its VMs every granted address of every user
/// (LANPools.shared.contains), published or not — so an address is blocked
/// before its first packet. macOS has no counterpart: a Mac has one user.
// @port-skip linux-only: multi-user LAN pools (macOS is single-user)
public struct LANPoolsFile: Codable, Equatable, Sendable {
    /// The LAN interface the pool addresses go on; nil: the default route's.
    public var interface: String?
    /// User → their ranges ("a-b", CIDR or single addresses).
    public var grants: [String: [String]]

    // @port-skip linux-only: multi-user LAN pools
    public init(interface: String? = nil, grants: [String: [String]] = [:]) {
        self.interface = interface
        self.grants = grants
    }

    // @port-skip linux-only: multi-user LAN pools
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["BROMURE_LAN_POOLS"] ?? "/etc/bromure-ac/lan-pools.json"
    }

    /// The file at `path`; empty when there is none, unless `requireFile`.
    /// Its interface must be a valid name, and (`requireInterface`) exist.
    // @port-skip linux-only: multi-user LAN pools
    public static func load(_ path: String = defaultPath, requireFile: Bool = false,
                            requireInterface: Bool = true) throws -> LANPoolsFile {
        guard let data = FileManager.default.contents(atPath: path) else {
            if requireFile { throw LANPoolsAdmin.Failure.message("\(path) is missing") }
            return LANPoolsFile()
        }
        let file = try JSONDecoder().decode(LANPoolsFile.self, from: data)
        if let i = file.interface {
            guard LANRoute.validInterfaceName(i) else { throw LANPoolsAdmin.Failure.message("'\(i)' isn't an interface name") }
            if requireInterface, !LANRoute.exists(i) { throw LANPoolsAdmin.Failure.message("there's no interface \(i)") }
        }
        return file
    }

    /// Every address of `user`'s grants (host order).
    // @port-skip linux-only: multi-user LAN pools
    public func addresses(of user: String) -> Set<UInt32> {
        Set((grants[user] ?? []).flatMap { LinuxKubeHost.parsePool($0) ?? [] })
    }

    /// The grant names that are `uid`'s account (resolved now, getpwnam_r):
    /// a caller is matched on its uid, never on a name looked up from it.
    // @port-skip linux-only: multi-user LAN pools
    public func users(ofUID uid: uid_t) -> [String] {
        grants.keys.filter { LANAccount.uid(of: $0) == uid }.sorted()
    }

    /// Every address granted to `uid`'s account.
    // @port-skip linux-only: multi-user LAN pools
    public func addresses(ofUID uid: uid_t) -> Set<UInt32> {
        users(ofUID: uid).reduce(into: Set<UInt32>()) { $0.formUnion(addresses(of: $1)) }
    }

    /// Every granted address, of every user.
    // @port-skip linux-only: multi-user LAN pools
    public var allAddresses: Set<UInt32> {
        grants.keys.reduce(into: Set<UInt32>()) { $0.formUnion(addresses(of: $1)) }
    }

    /// The interface the pools go on: the file's, else the default route's.
    // @port-skip linux-only: multi-user LAN pools
    public func resolvedInterface() -> String? {
        guard let i = interface ?? LANRoute.defaultRoute()?.interface, LANRoute.validInterfaceName(i), LANRoute.exists(i) else { return nil }
        return i
    }
}

/// Account lookups that are safe from any thread (the _r calls, a buffer
/// per call; getpwnam/getpwuid share one static buffer).
// @port-skip linux-only: multi-user LAN pools
public enum LANAccount {
    // @port-skip linux-only: multi-user LAN pools
    public static func uid(of name: String) -> uid_t? {
        lookup { pwd, buf, res in getpwnam_r(name, &pwd, buf.baseAddress!, buf.count, &res) }?.uid
    }

    // @port-skip linux-only: multi-user LAN pools
    public static func name(of uid: uid_t) -> String? {
        lookup { pwd, buf, res in getpwuid_r(uid, &pwd, buf.baseAddress!, buf.count, &res) }?.name
    }

    // @port-skip linux-only: multi-user LAN pools
    private static func lookup(_ call: (inout passwd, UnsafeMutableBufferPointer<CChar>, inout UnsafeMutablePointer<passwd>?) -> Int32)
        -> (uid: uid_t, name: String)? {
        var size = max(Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX))), 1024)
        while size <= 1 << 20 {
            var buf = [CChar](repeating: 0, count: size)
            // pw_name points into buf: copied while it's in scope.
            let (rc, found) = buf.withUnsafeMutableBufferPointer { b -> (Int32, (uid_t, String)?) in
                var pwd = passwd()
                var res: UnsafeMutablePointer<passwd>?
                let rc = call(&pwd, b, &res)
                return (rc, rc == 0 && res != nil ? (pwd.pw_uid, String(cString: pwd.pw_name)) : nil)
            }
            if rc == ERANGE { size *= 2; continue }
            return found.map { (uid: $0.0, name: $0.1) }
        }
        return nil
    }
}

/// The granted addresses, re-read when the file changes (checked at most
/// every 0.5 s): what a multi-user daemon's switch and proxy refuse. An
/// address taken out of the grants stays refused `grace` longer: the helper
/// withdraws its publication within ~0.5 s of the change, and until then
/// another user's VM mustn't reach it.
// @port-skip linux-only: multi-user LAN pools
public final class LANPools: Sendable {
    public static let shared = LANPools(path: LANPoolsFile.defaultPath)
    private let path: String
    private let uid: uid_t
    private let state = NIOLockedValueBox<(set: Set<UInt32>, mtime: timespec?, checked: ContinuousClock.Instant, loaded: Bool,
                                            leaving: [UInt32: ContinuousClock.Instant], own: Set<UInt32>,
                                            becameOwn: [UInt32: ContinuousClock.Instant])>(
        ([], nil, .now - .seconds(60), false, [:], [], [:]))
    static let grace: Duration = .seconds(3)

    // @port-skip linux-only: multi-user LAN pools
    init(path: String, uid: uid_t = getuid()) { self.path = path; self.uid = uid }

    // @port-skip linux-only: multi-user LAN pools
    public func contains(_ ip: UInt32) -> Bool {
        state.withLockedValue { s in
            if ContinuousClock.now - s.checked > .milliseconds(500) {
                s.checked = .now
                var st = stat()
                let m: timespec? = stat(path, &st) == 0 ? st.st_mtim : nil
                if m?.tv_sec != s.mtime?.tv_sec || m?.tv_nsec != s.mtime?.tv_nsec {
                    s.mtime = m
                    // A file that is missing or doesn't parse keeps the last
                    // good set (never "nothing blocked" because of a bad
                    // write or a deletion). The grants are blocked whatever
                    // the interface's state.
                    if m == nil {
                        if s.loaded { log("\(path) is missing; keeping the last LAN pools (\(s.set.count) addresses blocked)") }
                    } else {
                        do {
                            let file = try LANPoolsFile.load(path, requireInterface: false)
                            let next = file.allAddresses
                            let now = ContinuousClock.now
                            for ip in s.set.subtracting(next) { s.leaving[ip] = now }
                            // Moved from another account's grant to ours: that
                            // account's publication may outlive the change by
                            // ~0.5 s, so it stays refused `grace` longer.
                            let own = file.addresses(ofUID: uid)
                            for ip in own.subtracting(s.own) {
                                if s.set.contains(ip) { s.becameOwn[ip] = now }
                                // Moved in two writes (taken back, then granted
                                // to us): the leaving grace still running carries over.
                                else if let since = s.leaving[ip], now - since < Self.grace { s.becameOwn[ip] = since }
                            }
                            s.set = next
                            s.own = own
                            s.loaded = true
                        } catch {
                            log("\(path) doesn't read (\(error)); keeping the last LAN pools (\(s.set.count) addresses blocked)")
                        }
                    }
                }
            }
            if s.set.contains(ip) { return true }
            guard let since = s.leaving[ip] else { return false }
            if ContinuousClock.now - since < Self.grace { return true }
            s.leaving[ip] = nil
            return false
        }
    }

    /// Granted, or just taken back, but not to this account: what a
    /// single-user server's daemon refuses its VMs (another account's
    /// published addresses), its own cluster's addresses aside.
    // @port-skip linux-only: multi-user LAN pools
    public func containsOther(_ ip: UInt32) -> Bool {
        guard contains(ip) else { return false }
        return state.withLockedValue { s in
            guard s.own.contains(ip) else { return true }
            guard let since = s.becameOwn[ip] else { return false }
            if ContinuousClock.now - since < Self.grace { return true }
            s.becameOwn[ip] = nil
            return false
        }
    }

    // @port-skip linux-only: multi-user LAN pools
    private func log(_ s: String) { FileHandle.standardError.write(Data("bromure-ac: \(s)\n".utf8)) }
}

/// The host's default route and an interface's IPv4 subnet.
// @port-skip linux-only: multi-user LAN pools
public enum LANRoute {
    /// The default route's interface and gateway, from /proc/net/route.
    // @port-skip linux-only: multi-user LAN pools
    public static func defaultRoute() -> (interface: String, gateway: UInt32)? {
        guard let text = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count > 2, f[1] == "00000000", let gw = UInt32(f[2], radix: 16) else { continue }
            return (String(f[0]), UInt32(bigEndian: gw))   // the file is little-endian network order
        }
        return nil
    }

    /// A Linux interface name: [A-Za-z0-9_.:-], 1–15 characters, no
    /// leading '-' (it goes on `ip`'s command line and into sysctl paths).
    // @port-skip linux-only: multi-user LAN pools
    public static func validInterfaceName(_ s: String) -> Bool {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        return (1...15).contains(s.utf8.count) && !s.hasPrefix("-") && s != "." && s != ".." && s.allSatisfy { ok.contains($0) }
    }

    // @port-skip linux-only: multi-user LAN pools
    public static func exists(_ iface: String) -> Bool { if_nametoindex(iface) != 0 }

    /// `iface`'s IPv4 addresses with their prefix masks (host order).
    // @port-skip linux-only: multi-user LAN pools
    public static func subnets(of iface: String) -> [(address: UInt32, mask: UInt32)] {
        var out: [(UInt32, UInt32)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard String(cString: ifa.pointee.ifa_name) == iface, let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET), let nm = ifa.pointee.ifa_netmask else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard m != 0xFFFF_FFFF else { continue }   // a /32 (a pool address we put there): not a subnet
            out.append((a, m))
        }
        return out
    }
}

/// `bromure-ac admin pool`: the grants, validated and written (root only).
// @port-skip linux-only: multi-user LAN pools administration
public enum LANPoolsAdmin {
    public enum Failure: Error, CustomStringConvertible {
        case message(String)
        // @port-skip linux-only: multi-user LAN pools
        public var description: String { if case .message(let m) = self { return m }; return "" }
    }

    /// `grants` with `range` added for `user`, or why not: the range must
    /// parse, sit inside the interface's subnet, and hold none of the host's
    /// own addresses, its gateway, or another user's granted addresses.
    // @port-skip linux-only: multi-user LAN pools administration
    public static func adding(_ range: String, for user: String, to file: LANPoolsFile,
                              hostAddresses: Set<UInt32>, gateway: UInt32?,
                              subnets: [(address: UInt32, mask: UInt32)]) throws -> LANPoolsFile {
        guard let ips = LinuxKubeHost.parsePool(range) else {
            throw Failure.message("'\(range)' isn't a range (a.b.c.d-a.b.c.e, a CIDR or addresses; at most 1024 each)")
        }
        guard let net = subnets.first(where: { s in ips.allSatisfy { $0 & s.mask == s.address & s.mask } }) else {
            throw Failure.message("'\(range)' isn't inside the LAN interface's subnet")
        }
        for ip in ips {
            let text = VMNetSwitchText.ip(ip)
            if ip & ~net.mask == 0 || ip & ~net.mask == ~net.mask { throw Failure.message("\(text) is the subnet's network or broadcast address") }
            if hostAddresses.contains(ip) { throw Failure.message("\(text) is one of this server's own addresses") }
            if ip == gateway { throw Failure.message("\(text) is the LAN's gateway") }
        }
        for (other, _) in file.grants where other != user {
            if let clash = file.addresses(of: other).intersection(ips).min() {
                throw Failure.message("\(VMNetSwitchText.ip(clash)) is already granted to \(other)")
            }
        }
        var out = file
        out.grants[user, default: []].append(range)
        return out
    }

    /// Writes `file` to `path` (root-owned, 0644: every daemon reads it).
    // @port-skip linux-only: multi-user LAN pools administration
    public static func write(_ file: LANPoolsFile, to path: String = LANPoolsFile.defaultPath) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let tmp = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: try enc.encode(file),
                                             attributes: [.posixPermissions: 0o644]),
              rename(tmp, path) == 0 else {
            unlink(tmp)
            throw Failure.message("couldn't write \(path)")
        }
    }
}

/// Dotted quads (host order).
// @port-skip linux-only: multi-user LAN pools
enum VMNetSwitchText {
    // @port-skip linux-only: multi-user LAN pools
    static func ip(_ v: UInt32) -> String { "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)" }
}
