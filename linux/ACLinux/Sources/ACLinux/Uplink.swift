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
    /// Inbound frames go to `r` as they are read, instead of `inbound`: the
    /// uplink never stops reading. Used by the switch, which routes each
    /// frame and drops at the destination VM's port when that port is full.
    /// (passt in particular must never see its tap writes stall: it then
    /// loses a flow's ACKs for good; linux/PASST_STALL_REPORT.md.)
    func setReceiver(_ r: (@Sendable (Data) -> Void)?)
    func close() async
}

// @port-skip linux-only: NetworkUplink protocol stand-in
extension TapUplink: Uplink {
    // @port-skip linux-only: tap uplink
    public func setReceiver(_ r: (@Sendable (Data) -> Void)?) { core.setReceiver(r) }
    // @port-skip linux-only: tap uplink
    public var gatewayMAC: String? { hostMAC }
    /// The tap's own MTU (the host routes it like any interface).
    // @port-skip linux-only: tap uplink
    public var mtu: Int {
        Int((try? String(contentsOfFile: "/sys/class/net/\(name)/mtu", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1500
    }
}
