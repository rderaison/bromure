import Foundation
import SystemConfiguration

/// Snapshot of the host Mac's primary network configuration.
public struct HostNetworkInfo {
    public let gateway: UInt32
    public let subnetMask: UInt32
    public let subnet: UInt32       // gateway & subnetMask
    public let dnsServers: [UInt32]

    /// Detect the current host network configuration.
    /// Returns nil if no active network interface is found.
    public static func detect() -> HostNetworkInfo? {
        guard let store = SCDynamicStoreCreate(nil, "Bromure" as CFString, nil, nil) else { return nil }

        // Get primary interface and router from global IPv4 state
        guard let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let routerString = globalDict["Router"] as? String,
              let gateway = parseIPv4(routerString),
              let primaryInterface = globalDict["PrimaryInterface"] as? String else {
            return nil
        }

        // Get interface subnet mask via getifaddrs
        var subnetMask: UInt32 = 0xFFFFFF00  // default /24
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            defer { freeifaddrs(ifaddr) }
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let name = String(cString: ptr.pointee.ifa_name)
                guard name == primaryInterface,
                      ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                      let maskAddr = ptr.pointee.ifa_netmask else { continue }
                maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    subnetMask = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
                }
                break
            }
        }

        // Get DNS servers
        var dnsServers: [UInt32] = []
        if let dnsDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let servers = dnsDict["ServerAddresses"] as? [String] {
            dnsServers = servers.compactMap { parseIPv4($0) }
        }

        let subnet = gateway & subnetMask

        return HostNetworkInfo(
            gateway: gateway,
            subnetMask: subnetMask,
            subnet: subnet,
            dnsServers: dnsServers
        )
    }

    /// Third octets of every local IPv4 interface that sits inside
    /// `192.168.0.0/16`. Lets a NAT subnet picker steer clear of any
    /// `192.168.x.0/24` the host is genuinely on (Wi-Fi, Ethernet, other
    /// vmnet/bridge interfaces, VPNs, etc.) — not just the primary one.
    public static func localPrivateClassCOctets() -> Set<UInt8> {
        var octets: Set<UInt8> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return octets }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if (ip & 0xFFFF_0000) == 0xC0A8_0000 {   // 192.168.0.0/16
                octets.insert(UInt8((ip >> 8) & 0xFF))
            }
        }
        return octets
    }

    /// The `/24` network addresses (low byte 0) of every local IPv4 interface
    /// inside `172.16.0.0/12`. Lets AC's random-172 subnet picker steer clear of
    /// any `172.x.y.0/24` the host is genuinely on — most importantly Docker's
    /// `172.17.0.0/16` bridge and any compose networks — so a randomly chosen
    /// workspace subnet never shadows one.
    public static func localPrivate172Slash24s() -> Set<UInt32> {
        var nets: Set<UInt32> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nets }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if (ip & 0xFFF0_0000) == 0xAC10_0000 {   // 172.16.0.0/12
                nets.insert(ip & 0xFFFF_FF00)         // the /24 network address
            }
        }
        return nets
    }

    /// Parse a dotted-decimal IPv4 string into a host-byte-order UInt32.
    static func parseIPv4(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4,
              parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// Format a host-byte-order UInt32 as dotted-decimal.
    static func formatIPv4(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }
}
