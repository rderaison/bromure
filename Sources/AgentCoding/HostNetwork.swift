import Foundation

enum HostNetwork {
    /// The Mac's primary LAN IPv4 — the address a remote client on the same
    /// network would use to reach a service bound to 0.0.0.0. Skips loopback and
    /// link-local (169.254.x); prefers en0 (the built-in Wi-Fi/Ethernet), else
    /// the first global IPv4 found. nil if the Mac has no routable IPv4.
    static func primaryIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }

        var fallback: String?
        var ptr = addrs
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") { continue }

            if String(cString: p.pointee.ifa_name) == "en0" { return ip }  // primary NIC
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
