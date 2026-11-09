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

    // MARK: - The workspace subnet (macOS: VMNetSwitch.swift's subnet selection)

    /// UserDefaults key holding AC's chosen `/24` network address (a `UInt32`
    /// stored as `Int`): the daemon's own defaults (per user on a multi-user
    /// server).
    public static let subnetBase172DefaultsKey = "vmnet.switch.subnetBase172"

    /// 172.16/12 second octets we'll pick from — 16, then 21…31, skipping
    /// Docker's default bridge range (172.17–172.20).
    private static let allowed172SecondOctets: [UInt32] = [16] + Array(21...31)

    /// The persisted random `/24` in `172.16.0.0/12`, chosen once and reused,
    /// re-rolled only if the host has since joined it. Persists the choice
    /// on first pick.
    // @port VMNetSwitch.static persistedRandom172Base(hostUsed: Set<UInt32>) h=0217cebe43d3992f @49959cbb
    public static func persistedRandom172Base(hostUsed: Set<UInt32>, defaults d: UserDefaults = .standard) -> UInt32 {
        if d.object(forKey: subnetBase172DefaultsKey) != nil {
            let saved = UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: subnetBase172DefaultsKey)))
            if isEligible172(saved, hostUsed: hostUsed) { return saved }
        }
        let chosen = randomEligible172(hostUsed: hostUsed)
        d.set(Int(chosen), forKey: subnetBase172DefaultsKey)
        return chosen
    }

    /// Pick (and persist, on first call) the random 172.16/12 `/24`, the
    /// host's own `/24`s skipped.
    // @port VMNetSwitch.static ensureRandom172Base() h=74f5b39e5647f450 @49959cbb
    @discardableResult
    public static func ensureRandom172Base() -> UInt32 {
        persistedRandom172Base(hostUsed: HostNetworkInfo.localPrivate172Slash24s())
    }

    /// The persisted `/24` network base as dotted-decimal, or nil if none
    /// has been chosen yet.
    // @port VMNetSwitch.static savedRandom172BaseString() h=1c3d2cb206072374 @49959cbb
    public static func savedRandom172BaseString() -> String? {
        let d = UserDefaults.standard
        guard d.object(forKey: subnetBase172DefaultsKey) != nil else { return nil }
        let base = UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: subnetBase172DefaultsKey)))
        return ipString(base)
    }

    // @port VMNetSwitch.static randomEligible172(hostUsed: Set<UInt32>) h=5d14fd786a4098eb @49959cbb
    static func randomEligible172(hostUsed: Set<UInt32>) -> UInt32 {
        for _ in 0..<4096 {
            let b2 = allowed172SecondOctets.randomElement()!
            let b3 = UInt32.random(in: 0...255)
            let base = 0xAC10_0000 | ((b2 & 0x0F) << 16) | (b3 << 8)   // 172.<b2>.<b3>.0
            if isEligible172(base, hostUsed: hostUsed) { return base }
        }
        return 0xAC10_0000   // 172.16.0.0/24 last resort
    }

    /// A `/24` (low byte 0) inside 172.16/12, outside Docker's 172.17–172.20,
    /// and not one the host currently occupies.
    // @port VMNetSwitch.static isEligible172(_: UInt32, hostUsed: Set<UInt32>) h=dea0c6e12f62238d @49959cbb
    static func isEligible172(_ base: UInt32, hostUsed: Set<UInt32>) -> Bool {
        let b2 = (base >> 16) & 0xFF
        return (base & 0x0000_00FF) == 0
            && (base & 0xFFF0_0000) == 0xAC10_0000
            && allowed172SecondOctets.contains(b2)
            && !hostUsed.contains(base)
    }

}
