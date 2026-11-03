import Foundation

/// The part of macOS's vmnet switch that shared code reads on Linux: the
/// guest subnet a fat client's `forward` may reach. The daemon's interim
/// switch (InterimSwitch) sets it; there is no vmnet here.
// @port-skip linux-only: stand-in for the vmnet switch (VMNetSwitch.swift is vmnet + Virtualization)
public final class VMNetSwitch: @unchecked Sendable {
    public static let shared = VMNetSwitch()
    private let lock = NSLock()
    private var _subnet: VmnetSubnet?

    // @port-skip linux-only: stand-in
    public var subnet: VmnetSubnet? {
        get { lock.lock(); defer { lock.unlock() }; return _subnet }
        set { lock.lock(); _subnet = newValue; lock.unlock() }
    }

    /// Addresses the DHCP allocator must never hand out (a cluster's MetalLB
    /// range); the interim switch's DHCP reads isReserved.
    private var reservedIPs: Set<UInt32> = []

    /// Keep `ips` (host-order IPv4) out of the DHCP pool from now on.
    // @port VMNetSwitch.reserveIPs(_: Set<UInt32>) h=60c570edf1dedfcc @5626da88
    public func reserveIPs(_ ips: Set<UInt32>) {
        lock.lock(); defer { lock.unlock() }
        reservedIPs.formUnion(ips)
    }

    // @port VMNetSwitch.unreserveIPs(_: Set<UInt32>) h=97bf7f126806d9ca @5626da88
    public func unreserveIPs(_ ips: Set<UInt32>) {
        lock.lock(); defer { lock.unlock() }
        reservedIPs.subtract(ips)
    }

    // @port-skip linux-only: read side for the interim switch's DHCP
    public func isReserved(_ ip: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return reservedIPs.contains(ip)
    }

    /// Parse a dotted quad into host-order IPv4.
    // @port VMNetSwitch.static parseIPv4(_: String) h=eb06af77b3bf4952 @5626da88
    public static func parseIPv4(_ string: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, string, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    /// Dotted quad of a host-order IPv4.
    // @port VMNetSwitch.static ipString(_: UInt32) h=f6f260cc82bacc3b @5626da88
    public static func ipString(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}
