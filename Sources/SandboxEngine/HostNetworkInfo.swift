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
