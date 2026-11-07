import Foundation
import SandboxEngine
import NIOConcurrencyHelpers

/// STAND-IN for the shared switch. The real one is VMNetSwitch (MAC learning,
/// its own DHCP, DNS snoop, the MITM interceptor hook), which arrives on Linux
/// through the ACCore carve-out. Until then this does just enough L2/L3 to put
/// VMs behind one uplink:
/// - VM -> uplink as is, except DHCP, which is answered here (a lease per MAC);
/// - uplink -> VM by destination IP (passt keeps a single guest MAC), ARP by
///   target IP, broadcast to every port.
/// Backpressure (FramePort): a VM's reader waits for room on the uplink
/// (`sendWaiting`: the pressure goes back to that VM alone); the uplink is
/// never paused: its reader hands each frame to the switch's receiver, which
/// `send`s, so a slow VM drops at its own port's limit, counted in that
/// port's `stats.dropped`, without slowing the others or passt.
/// VM-to-VM (macOS AC's VMNetSwitch with bridgePeers = true): source MACs
/// are learned per port, known unicast goes to the learned port, broadcast
/// and unknown unicast are flooded to the peers and the uplink. Ports are
/// one daemon's, so this never crosses users. One passt-specific deviation:
/// an ARP request for a peer's leased address isn't sent to passt, which
/// would answer for any address and draw the peer's traffic to the uplink;
/// and a frame to the gateway's MAC whose IPv4 destination is a peer's
/// lease (a guest that cached passt's answer) is delivered to the peer.
/// Egress: every off-subnet frame from a session VM goes through its
/// workspace's firewall (SwitchEgressFirewall, macOS's handleEgress), and
/// the guests' DNS answers are snooped for its hostname rules.
/// No CDP pairing gate. Don't build on it.
// @port-skip linux-only: interim stand-in for VMNetSwitch until ACCore ships it
public final class InterimSwitch: Sendable {
    public let dhcp: InterimDHCP
    public let uplink: any Uplink
    private let ports: NIOLockedValueBox<[(mac: MAC, port: any FramePort, task: Task<Void, Never>)]>
    /// The egress firewall (and, once set, the transparent interception).
    let egress: SwitchEgressFirewall
    /// Source MAC → the attached port (its MAC) it came from.
    private let learned = NIOLockedValueBox<[MAC: MAC]>([:])
    /// The uplink's (passt's) MAC: frames to it go to the uplink only.
    private let gatewayMAC: MAC
    /// IPv4 destinations a guest may not send to (multi-user: the host's
    /// own addresses); their frames are dropped before the uplink.
    public let blockedDestination = NIOLockedValueBox<(@Sendable (UInt32) -> Bool)?>(nil)
    /// Cluster nodes' ports: their cluster and its allocated LoadBalancer
    /// range (MetalLB on the node answers ARP for those addresses), and
    /// which cluster holds each address claimed so far. Every cluster is
    /// allocated the same .230-.249 range (KubeClusterEngine), so an address
    /// is the first claiming cluster's until its last node goes: one
    /// cluster's node can't answer for another's.
    let reservedClaims = NIOLockedValueBox<(nodes: [MAC: (cluster: String, range: ClosedRange<UInt32>)],
                                            owners: [UInt32: String])>(([:], [:]))

    // @port-skip linux-only: interim switch
    public init(uplink: any Uplink, gateway: String = "192.168.64.1", dns: String = "192.168.64.1",
                mtu: @escaping @Sendable ([UInt8]) -> Int? = { _ in nil }) {
        self.uplink = uplink
        let gwMAC = MAC(Self.mac(uplink.gatewayMAC ?? "9a:55:9a:55:9a:55"))
        gatewayMAC = gwMAC
        let ports = NIOLockedValueBox<[(mac: MAC, port: any FramePort, task: Task<Void, Never>)]>([])
        self.ports = ports
        // A packet the switch answers a VM with (a RST, an interceptor's
        // reply), framed from the gateway's MAC as macOS's injectIPToPort does.
        let dhcp = InterimDHCP(server: Self.ipv4(gateway), dns: Self.ipv4(dns),
                               serverMAC: Self.mac(uplink.gatewayMAC ?? "9a:55:9a:55:9a:55"), mtu: mtu)
        self.dhcp = dhcp
        // A peer: an address leased to another attached VM.
        egress = SwitchEgressFirewall(gatewayIP: InterimDHCP.u32(Self.ipv4(gateway)),
                                      isLeased: { ip, sender in
                                          guard let owner = dhcp.mac(forIP: ip), owner != sender else { return false }
                                          return ports.withLockedValue { $0.contains { $0.mac == owner } }
                                      },
                                      isReserved: { VMNetSwitch.shared.isReserved($0) },
                                      closesSubnet: uplink.natsSubnet) { mac, ip in
            guard let p = ports.withLockedValue({ $0.first(where: { $0.mac == mac }) }) else { return }
            var frame = Data(mac.bytes + gwMAC.bytes + [0x08, 0x00])
            frame.append(contentsOf: ip)
            _ = p.port.send(frame)
        }
        // The uplink calls this as it reads (no queue in between): it routes
        // and `send`s, which never waits, so the uplink never stops reading
        // and a full VM port drops (counted there) instead.
        uplink.setReceiver { [ports, dhcp, egress] (f: inout Data) in
            // The guests' DNS answers, for the firewall's hostname rules.
            egress.snoop(f)
            // Read the header in place: no copy for a frame that ends up
            // dropped at a full port (a paused VM's retransmit bursts).
            let (target, broadcast) = f.withUnsafeBytes { b -> (UInt32?, Bool) in
                guard b.count >= 14 else { return (nil, true) }
                let bcast = b[0] & 1 != 0
                if b[12] == 0x08, b[13] == 0x00, b.count >= 34 {
                    return (UInt32(b[30]) << 24 | UInt32(b[31]) << 16 | UInt32(b[32]) << 8 | UInt32(b[33]), bcast)
                }
                if b[12] == 0x08, b[13] == 0x06, b.count >= 42 {
                    return (UInt32(b[38]) << 24 | UInt32(b[39]) << 16 | UInt32(b[40]) << 8 | UInt32(b[41]), bcast)
                }
                return (nil, bcast)
            }
            guard f.count >= 14 else { return }
            let all = ports.withLockedValue { $0 }
            if let target, let mac = dhcp.mac(forIP: target), let p = all.first(where: { $0.mac == mac }) {
                guard p.port.isWritable else { p.port.sendDeferred(f); return }   // counted as that port's drop
                if broadcast { p.port.sendDeferred(f); return }
                // In place: the routing thread hands over the only reference,
                // so this doesn't copy the frame.
                f.withUnsafeMutableBytes { mac.write(to: $0) }
                p.port.sendDeferred(f)    // never waits: drops at that port's limit
            } else {
                for p in all { p.port.sendDeferred(f) }
            }
        } batchEnd: { [ports] in
            for p in ports.withLockedValue({ $0 }) { p.port.flush() }
        }
    }

    /// Plugs a VM's stream port in.
    // @port-skip linux-only: interim switch
    public func attach(_ port: any FramePort, mac: String) {
        let m = MAC(Self.mac(mac))
        let t = Task { [self, dhcp, uplink, blockedDestination, egress] in
            for await f in port.inbound {
                // A VM speaks as itself only: its own MAC, its own lease.
                guard self.speaksAsItself(f, from: m) else { continue }
                if let r = dhcp.handle(f, port: m.bytes) { port.send(r); continue }
                switch egress.handle(f, from: m) {
                case .consumed: continue
                case .peersOnly: _ = self.toPeers(f, from: m); continue
                case .pass: break
                }
                guard self.toPeers(f, from: m) else { continue }
                if let blocked = blockedDestination.withLockedValue({ $0 }), let dst = Self.ipv4Destination(f), blocked(dst) { continue }
                await uplink.sendWaiting(f)
            }
        }
        ports.withLockedValue { $0.append((m, port, t)) }
    }

    /// A frame from the VM on port `from`, switched among the peers as
    /// macOS's VMNetSwitch does: learn its source; a known peer's unicast is
    /// delivered there (never waits: drops at that port's limit); broadcast
    /// and unknown unicast are flooded to the other ports. True: it goes to
    /// the uplink too.
    // @port-skip linux-only: the bridgePeers half of VMNetSwitch's port read loop
    func toPeers(_ f: Data, from: MAC) -> Bool {
        var f = f
        guard f.count >= 14 else { return true }
        // Read in place: no allocation on this per-frame path.
        let (dst, src) = f.withUnsafeBytes { b -> (MAC, MAC) in
            var d: UInt64 = 0, s: UInt64 = 0
            for i in 0..<6 { d = d << 8 | UInt64(b[i]); s = s << 8 | UInt64(b[6 + i]) }
            return (MAC(raw: d), MAC(raw: s))
        }
        learned.withLockedValue { if $0[src] != from { $0[src] = from } }
        if dst == gatewayMAC {
            // A peer's address behind the gateway's MAC: the guest learned it
            // when passt answered ARP for it (before the peer existed, or
            // before this switch bridged peers). Delivered to the peer, its
            // MAC written in place, as the frame would have been addressed.
            guard let ip = Self.ipv4Destination(f), let peer = dhcp.mac(forIP: ip), peer != from,
                  let p = ports.withLockedValue({ $0.first(where: { $0.mac == peer }) }) else { return true }
            f.withUnsafeMutableBytes { peer.write(to: $0) }
            _ = p.port.send(f)
            return false
        }
        let all = ports.withLockedValue { $0 }
        let multicast = f[f.startIndex] & 1 != 0
        if !multicast, let owner = learned.withLockedValue({ $0[dst] }) {
            if owner != from, let p = all.first(where: { $0.mac == owner }) { _ = p.port.send(f) }
            return false
        }
        for p in all where p.mac != from { _ = p.port.send(f) }
        // An ARP request for a peer's lease: the peer answers; passt would too.
        // So for a reserved LoadBalancer address (a cluster node answers),
        // where the uplink would take the traffic onto the server's network.
        if let target = Self.arpRequestTarget(f) {
            if dhcp.mac(forIP: target).map({ $0 != from }) == true { return false }
            if uplink.natsSubnet, VMNetSwitch.shared.isReserved(target) { return false }
        }
        // A node's announcement of a LoadBalancer address: the peers' business only.
        if uplink.natsSubnet, let sender = Self.arpSender(f), VMNetSwitch.shared.isReserved(sender) { return false }
        return true
    }

    /// The sender IP (big-endian u32) of an ARP frame; nil for anything else.
    // @port-skip linux-only: interim switch
    static func arpSender(_ f: Data) -> UInt32? {
        f.withUnsafeBytes { b in
            guard b.count >= 42, b[12] == 0x08, b[13] == 0x06 else { return nil }
            return UInt32(b[28]) << 24 | UInt32(b[29]) << 16 | UInt32(b[30]) << 8 | UInt32(b[31])
        }
    }

    /// Whether a frame from the VM on `m` speaks as itself: its Ethernet
    /// source is the port's MAC, and an IPv4 source or ARP sender address is
    /// the port's lease (the unspecified address before it has one: DHCP,
    /// ARP probes) or, for a cluster node's port, one of the reserved
    /// LoadBalancer addresses. A guest can't claim the gateway, a peer, or
    /// another VM's MAC, and so can't draw their traffic (their DNS).
    // @port-skip linux-only: the Linux switch's source pinning (vmnet does its own on macOS)
    func speaksAsItself(_ f: Data, from m: MAC) -> Bool {
        f.withUnsafeBytes { b -> Bool in
            guard b.count >= 14 else { return false }
            var s: UInt64 = 0
            for i in 0..<6 { s = s << 8 | UInt64(b[6 + i]) }
            guard MAC(raw: s) == m else { return false }
            let addr: UInt32
            func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
            switch (b[12], b[13]) {
            case (0x08, 0x00): guard b.count >= 34 else { return false }; addr = u32(26)
            case (0x08, 0x06): guard b.count >= 42 else { return false }; addr = u32(28)
            default: return true                     // IPv6 (the firewall's), others
            }
            if addr == 0 { return true }
            if dhcp.leaseAddress(for: m) == addr { return true }
            guard VMNetSwitch.shared.isReserved(addr) else { return false }
            return reservedClaims.withLockedValue { c in
                guard let node = c.nodes[m], node.range.contains(addr) else { return false }
                if let owner = c.owners[addr] { return owner == node.cluster }
                c.owners[addr] = node.cluster
                return true
            }
        }
    }

    /// The VM on `mac` is a node of `cluster`, which was allocated `range`
    /// (big-endian u32s): it may speak as those addresses (see speaksAsItself).
    // @port-skip linux-only: the Linux switch's source pinning
    public func allowReservedClaims(mac: String, cluster: String, range: ClosedRange<UInt32>) {
        let m = MAC(Self.mac(mac))
        reservedClaims.withLockedValue { $0.nodes[m] = (cluster, range) }
    }

    /// The VM on `mac` may no longer speak as reserved addresses (its
    /// cluster has no range any more).
    // @port-skip linux-only: the Linux switch's source pinning
    public func withdrawReservedClaims(mac: String) {
        let m = MAC(Self.mac(mac))
        reservedClaims.withLockedValue { c in
            guard let gone = c.nodes.removeValue(forKey: m) else { return }
            if !c.nodes.values.contains(where: { $0.cluster == gone.cluster }) {
                c.owners = c.owners.filter { $0.value != gone.cluster }
            }
        }
    }

    /// The target IP (big-endian u32) of an ARP request; nil for anything else.
    // @port-skip linux-only: interim switch
    static func arpRequestTarget(_ f: Data) -> UInt32? {
        f.withUnsafeBytes { b in
            guard b.count >= 42, b[12] == 0x08, b[13] == 0x06, b[20] == 0, b[21] == 1 else { return nil }
            return UInt32(b[38]) << 24 | UInt32(b[39]) << 16 | UInt32(b[40]) << 8 | UInt32(b[41])
        }
    }

    // @port-skip linux-only: interim switch
    public func detach(mac: String) {
        let m = MAC(Self.mac(mac))
        ports.withLockedValue { ps in
            for p in ps where p.mac == m { p.task.cancel() }
            ps.removeAll { $0.mac == m }
        }
        learned.withLockedValue { l in l = l.filter { $0.value != m } }
        reservedClaims.withLockedValue { c in
            guard let gone = c.nodes.removeValue(forKey: m) else { return }
            // Its cluster's last node: the addresses it held are free again.
            if !c.nodes.values.contains(where: { $0.cluster == gone.cluster }) {
                c.owners = c.owners.filter { $0.value != gone.cluster }
            }
        }
        egress.portClosed(m)
    }

    /// The attached port for `mac`'s counters (`dropped` = frames toward that
    /// VM refused at its queue limit).
    // @port-skip linux-only: interim switch
    public func portStats(mac: String) -> FramePortStats? {
        let m = MAC(Self.mac(mac))
        return ports.withLockedValue { $0.first { $0.mac == m }?.port.stats }
    }

    // @port-skip linux-only: interim switch
    public func stop() {
        uplink.setReceiver(nil, batchEnd: nil)
        ports.withLockedValue { ps in for p in ps { p.task.cancel() } }
    }

    /// An IPv4 frame's destination address (big-endian u32).
    // @port-skip linux-only: interim switch
    static func ipv4Destination(_ f: Data) -> UInt32? {
        f.withUnsafeBytes { b in
            guard b.count >= 34, b[12] == 0x08, b[13] == 0x00 else { return nil }
            return UInt32(b[30]) << 24 | UInt32(b[31]) << 16 | UInt32(b[32]) << 8 | UInt32(b[33])
        }
    }

    // @port-skip linux-only: interim switch
    static func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").compactMap { UInt8($0) } }
    // @port-skip linux-only: interim switch
    static func mac(_ s: String) -> [UInt8] { s.split(separator: ":").compactMap { UInt8($0, radix: 16) } }
}

/// The interim switch's DHCP server: a lease per client MAC (.2, .3, …),
/// broadcast replies, router = the gateway, a DNS server, an optional MTU.
// @port-skip linux-only: interim stand-in for VMNetSwitch's DHCP
public final class InterimDHCP: Sendable {
    let server: [UInt8], dns: [UInt8], serverMAC: [UInt8]
    let mtu: @Sendable ([UInt8]) -> Int?
    /// MAC -> IP, and the reverse index IP (big-endian u32) -> MAC that the
    /// per-frame uplink lookup uses; both kept in lease() and release().
    private let leases = NIOLockedValueBox<(byMAC: [[UInt8]: [UInt8]], byIP: [UInt32: MAC])>(([:], [:]))
    private let acked = NIOLockedValueBox<[[UInt8]: ContinuousClock.Instant]>([:])

    // @port-skip linux-only: interim DHCP
    init(server: [UInt8], dns: [UInt8], serverMAC: [UInt8], mtu: @escaping @Sendable ([UInt8]) -> Int?) {
        self.server = server; self.dns = dns; self.serverMAC = serverMAC; self.mtu = mtu
    }

    /// The lease for `mac`, assigned on first sight; nil when every address
    /// (.2–.254) is leased or reserved (macOS's leaseIP answers none then).
    /// `preferring`: the address it held last (its VM record's), taken when
    /// it's still free, as macOS's leaseIP prefers its lease store's: a
    /// cluster's nodes keep their addresses across cold starts (a moved
    /// control plane leaves k3s's certificates and node objects behind).
    // @port-skip linux-only: interim DHCP
    public func lease(for mac: [UInt8], preferring: [UInt8]? = nil) -> [UInt8]? {
        leases.withLockedValue { l in
            if let ip = l.byMAC[mac] { return ip }
            let used = Set(l.byMAC.values.map { $0[3] })
            // Never an address reserved for a cluster's MetalLB range
            // (VMNetSwitch.reserveIPs, as macOS's allocator skips them).
            let base = Array(server[0..<3])
            if let p = preferring, p.count == 4, Array(p[0..<3]) == base, (2...254).contains(p[3]),
               !used.contains(p[3]), !VMNetSwitch.shared.isReserved(Self.u32(p)) {
                l.byMAC[mac] = p
                l.byIP[Self.u32(p)] = MAC(mac)
                return p
            }
            var host: UInt8 = 2
            while host <= 254, used.contains(host) || VMNetSwitch.shared.isReserved(Self.u32(base + [host])) {
                if host == 254 { return nil }
                host += 1
            }
            let ip = base + [host]
            l.byMAC[mac] = ip
            l.byIP[Self.u32(ip)] = MAC(mac)
            return ip
        }
    }

    /// The lease for `mac` as a dotted quad, if one was handed out.
    // @port-skip linux-only: interim DHCP
    public func leasedIP(for mac: String) -> String? {
        leases.withLockedValue { $0.byMAC[InterimSwitch.mac(mac)] }.map { $0.map(String.init).joined(separator: ".") }
    }

    /// Hands `mac` the address it had (a re-adopted VM keeps its lease).
    // @port-skip linux-only: interim DHCP
    public func assign(mac: [UInt8], ip: [UInt8]) {
        guard ip.count == 4 else { return }
        leases.withLockedValue { l in
            if let old = l.byMAC[mac] { l.byIP.removeValue(forKey: Self.u32(old)) }
            l.byMAC[mac] = ip
            l.byIP[Self.u32(ip)] = MAC(mac)
        }
    }

    // @port-skip linux-only: interim DHCP
    public func release(mac: String) {
        leases.withLockedValue { l in
            if let ip = l.byMAC.removeValue(forKey: InterimSwitch.mac(mac)) { l.byIP.removeValue(forKey: Self.u32(ip)) }
        }
    }

    // @port-skip linux-only: interim DHCP
    static func u32(_ ip: [UInt8]) -> UInt32 {
        UInt32(ip[0]) << 24 | UInt32(ip[1]) << 16 | UInt32(ip[2]) << 8 | UInt32(ip[3])
    }

    // @port-skip linux-only: interim DHCP
    func mac(for ip: [UInt8]) -> [UInt8]? { ip.count == 4 ? mac(forIP: Self.u32(ip))?.bytes : nil }

    /// The MAC holding `ip` (big-endian u32), from the reverse index: one
    /// dictionary lookup per frame.
    // @port-skip linux-only: interim DHCP
    func mac(forIP ip: UInt32) -> MAC? { leases.withLockedValue { $0.byIP[ip] } }

    // @port-skip linux-only: interim DHCP
    public func ackedAt(_ mac: [UInt8]) -> ContinuousClock.Instant? { acked.withLockedValue { $0[mac] } }

    /// The address leased to `mac` (big-endian u32), if any.
    // @port-skip linux-only: interim DHCP
    func leaseAddress(for mac: MAC) -> UInt32? {
        leases.withLockedValue { $0.byMAC[mac.bytes].map { Self.u32($0) } }
    }

    /// The reply to `frame` if it's a DHCP request from a client, else nil.
    /// `port`: the MAC of the port it came from; a request for any other
    /// hardware address (its chaddr or its Ethernet source) gets no lease,
    /// so a guest can't take the pool or another VM's address.
    // @port-skip linux-only: interim DHCP
    public func handle(_ f: Data, port: [UInt8]? = nil) -> Data? {
        let b = [UInt8](f)
        guard b.count >= 14 + 20 + 8 + 240, b[12] == 0x08, b[13] == 0x00, b[23] == 17 else { return nil }
        let udp = 14 + Int(b[14] & 0x0F) * 4
        guard b.count >= udp + 8 + 240, b[udp] == 0, b[udp + 1] == 68, b[udp + 2] == 0, b[udp + 3] == 67 else { return nil }
        let bootp = udp + 8
        guard b[bootp] == 1, Array(b[bootp + 236..<bootp + 240]) == [99, 130, 83, 99] else { return nil }
        var type: UInt8 = 0
        var i = bootp + 240
        while i + 1 < b.count, b[i] != 255 {
            if b[i] == 0 { i += 1; continue }
            if b[i] == 53, i + 2 < b.count { type = b[i + 2] }
            i += 2 + Int(b[i + 1])
        }
        let chaddr = Array(b[bootp + 28..<bootp + 34])
        if let port, chaddr != port || Array(b[6..<12]) != port { return nil }
        // No free address: no offer (the client keeps asking).
        guard let yiaddr = lease(for: chaddr) else { return nil }
        let reply: UInt8
        switch type {
        case 1: reply = 2                                     // DISCOVER -> OFFER
        case 3: reply = 5                                     // REQUEST -> ACK
            acked.withLockedValue { if $0[chaddr] == nil { $0[chaddr] = .now } }
        default: return nil
        }
        var p = [UInt8](repeating: 0, count: 236)
        p[0] = 2; p[1] = 1; p[2] = 6
        p[4..<8] = b[bootp + 4..<bootp + 8]
        p[10..<12] = b[bootp + 10..<bootp + 12]
        p[16..<20] = yiaddr[0..<4]
        p[20..<24] = server[0..<4]
        p[28..<44] = b[bootp + 28..<bootp + 44]
        p += [99, 130, 83, 99, 53, 1, reply, 54, 4] + server + [51, 4, 0, 0, 0x0E, 0x10,
              1, 4, 255, 255, 255, 0, 3, 4] + server + [6, 4] + dns
        if let m = mtu(chaddr) { p += [26, 2, UInt8(m >> 8), UInt8(m & 0xFF)] }
        p += [255]
        if p.count < 300 { p += [UInt8](repeating: 0, count: 300 - p.count) }
        let udpLen = 8 + p.count
        var ip: [UInt8] = [0x45, 0, UInt8((20 + udpLen) >> 8), UInt8((20 + udpLen) & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0]
            + server + [255, 255, 255, 255]
        var sum = 0
        for k in stride(from: 0, to: 20, by: 2) { sum += Int(ip[k]) << 8 | Int(ip[k + 1]) }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        ip[10] = UInt8((~sum >> 8) & 0xFF); ip[11] = UInt8(~sum & 0xFF)
        let u: [UInt8] = [0, 67, 0, 68, UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]
        return Data([255, 255, 255, 255, 255, 255] + serverMAC + [0x08, 0x00] + ip + u + p)
    }
}

/// A MAC address as a value (no heap array on the routing path).
// @port-skip linux-only: interim switch
struct MAC: Hashable, Sendable {
    let raw: UInt64
    // @port-skip linux-only: interim switch
    init(raw: UInt64) { self.raw = raw }
    // @port-skip linux-only: interim switch
    init(_ b: [UInt8]) {
        var r: UInt64 = 0
        for x in b.prefix(6) { r = r << 8 | UInt64(x) }
        raw = r
    }
    // @port-skip linux-only: interim switch
    var bytes: [UInt8] { (0..<6).map { UInt8(truncatingIfNeeded: raw >> (8 * (5 - UInt64($0)))) } }
    /// Writes the six bytes at the start of `b` (a frame's destination).
    // @port-skip linux-only: interim switch
    func write(to b: UnsafeMutableRawBufferPointer) {
        for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: raw >> (8 * UInt64(5 - i))) }
    }
}
