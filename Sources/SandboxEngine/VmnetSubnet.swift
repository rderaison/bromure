import Foundation

/// A custom IPv4 subnet for a vmnet **shared mode** (NAT) interface.
///
/// Apple's `VZNATNetworkDeviceAttachment` and a default `vmnet` shared
/// interface both land on the single well-known `192.168.64.0/24` network.
/// When two *separate* host processes each stand up their own NAT context on
/// that subnet — e.g. Bromure Web (via `NetworkFilter`) and Bromure AC (via
/// `VZNATNetworkDeviceAttachment`) — their independent DHCP servers each start
/// handing out the low addresses, and the two guests end up with the same
/// RFC 1918 IP. One of them loses connectivity.
///
/// vmnet's `network_identifier` UUID does **not** fix this: per `vmnet.h` it
/// applies only to `VMNET_HOST_MODE` and provides *no DHCP*, so it can't carry
/// NAT'd internet traffic. The supported way to give a NAT network its own
/// address space is to pass an explicit start/end/mask triple in
/// `VMNET_SHARED_MODE` (macOS 10.15+). This value carries that triple plus the
/// host-order integers `NetworkFilter` needs for its packet-filtering rules.
public struct VmnetSubnet: Sendable, Equatable {
    /// Gateway / host address. vmnet uses the start address as the gateway.
    public let gateway: UInt32
    /// Network address (`gateway & mask`).
    public let network: UInt32
    /// Subnet mask.
    public let mask: UInt32
    /// Last address of the DHCP pool (`vmnet_end_address_key`).
    public let poolEnd: UInt32

    public init(gateway: UInt32, mask: UInt32, poolEnd: UInt32) {
        self.gateway = gateway
        self.mask = mask
        self.network = gateway & mask
        self.poolEnd = poolEnd
    }

    /// `vmnet_start_address_key` — the gateway address, also the network's first usable host.
    public var startAddressString: String { HostNetworkInfo.formatIPv4(gateway) }
    /// `vmnet_end_address_key` — the last DHCP-pool address.
    public var endAddressString: String { HostNetworkInfo.formatIPv4(poolEnd) }
    /// `vmnet_subnet_mask_key`.
    public var subnetMaskString: String { HostNetworkInfo.formatIPv4(mask) }

    /// A `192.168.<octet>.0/24` network: gateway `.1`, DHCP pool `.2`–`.254`.
    public static func classC(thirdOctet octet: UInt8) -> VmnetSubnet {
        let base: UInt32 = 0xC0A8_0000 | (UInt32(octet) << 8)   // 192.168.octet.0
        return VmnetSubnet(gateway: base | 1, mask: 0xFFFF_FF00, poolEnd: base | 254)
    }
}

/// Picks a stable, per-app vmnet subnet so this process's NAT network is
/// isolated from any other Bromure app sharing the host. The other app
/// (Bromure AC) uses the default `192.168.64.0/24` via
/// `VZNATNetworkDeviceAttachment`, so this app just needs a *different*
/// `192.168.x.0/24` that also avoids the host's own LAN.
///
/// The octet is derived from a per-app identity persisted under the app's
/// Application Support directory (the same directory family as
/// `MACAddressPool`). Persisting it keeps the subnet stable across launches —
/// predictable for debugging and bounded in vmnet's state — while two
/// *different* apps, with different Application Support roots, naturally get
/// different identities. Computed once per process.
enum NetworkIdentity {
    private static let lock = NSLock()
    private static var cached: VmnetSubnet?

    /// Apple's default shared vmnet subnet — used by plain
    /// `VZNATNetworkDeviceAttachment` consumers (e.g. Bromure AC). Never reused.
    private static let defaultOctet: UInt8 = 64

    /// The vmnet subnet for this process, kept clear of `hostInfo`'s LAN.
    /// Cached, so every `NetworkFilter` in this process agrees.
    static func subnet(avoiding hostInfo: HostNetworkInfo?) -> VmnetSubnet {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let subnet = VmnetSubnet.classC(thirdOctet: chooseOctet(avoiding: hostInfo))
        cached = subnet
        return subnet
    }

    /// Octets we must not use: the default vmnet network and the host's LAN
    /// (if it sits inside `192.168.0.0/16`, which would otherwise be shadowed).
    private static func reservedOctets(_ hostInfo: HostNetworkInfo?) -> Set<UInt8> {
        var reserved: Set<UInt8> = [defaultOctet]
        if let hostInfo, (hostInfo.subnet & 0xFFFF_0000) == 0xC0A8_0000 {
            reserved.insert(UInt8((hostInfo.subnet >> 8) & 0xFF))
        }
        return reserved
    }

    /// Map the persisted identity into the `65...126` band (within Apple's
    /// vmnet range and away from the common `192.168.0/1/2` home-LAN octets),
    /// then linear-probe past any reserved octet.
    private static func chooseOctet(avoiding hostInfo: HostNetworkInfo?) -> UInt8 {
        let reserved = reservedOctets(hostInfo)
        let span = 62   // 65...126 inclusive
        var hash: UInt32 = 2166136261
        for byte in identitySeed() {           // FNV-1a over the 16 identity bytes
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        var octet = UInt8(65 + Int(hash % UInt32(span)))
        var probes = 0
        while reserved.contains(octet) && probes < span {
            octet = octet == 126 ? 65 : octet + 1
            probes += 1
        }
        return octet
    }

    /// 16 stable identity bytes, minted from a random UUID on first use and
    /// persisted alongside the other local-only Bromure state.
    private static func identitySeed() -> [UInt8] {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bromure", isDirectory: true)
        let url = dir.appendingPathComponent("network-identity")
        if let data = try? Data(contentsOf: url), data.count == 16 {
            return Array(data)
        }
        let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(bytes).write(to: url, options: .atomic)
        // Local-only state — keep it out of Time Machine, like mac-pool.json.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
        return bytes
    }
}
