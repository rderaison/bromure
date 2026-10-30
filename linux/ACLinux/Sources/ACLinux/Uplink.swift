import Foundation

/// The switch's way out: frames to and from whatever routes the VM subnet
/// to the rest of the world. PasstUplink (default: rootless userspace NAT)
/// or TapUplink (a persistent tap the host routes and masquerades).
// @port-skip linux-only: NetworkUplink protocol stand-in (macOS: VMNetSwitch's vmnet interface)
public protocol Uplink: FramePort {
    /// The gateway's MAC as the VMs should see it (aa:bb:…), if known.
    var gatewayMAC: String? { get }
    /// The largest frame payload (L3 MTU) the uplink carries well; the
    /// switch's DHCP advertises at most this.
    var mtu: Int { get }
    func close() async
}

// @port-skip linux-only: NetworkUplink protocol stand-in
extension TapUplink: Uplink {
    // @port-skip linux-only: tap uplink
    public var gatewayMAC: String? { hostMAC }
    /// The tap's own MTU (the host routes it like any interface).
    // @port-skip linux-only: tap uplink
    public var mtu: Int {
        Int((try? String(contentsOfFile: "/sys/class/net/\(name)/mtu", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1500
    }
}
