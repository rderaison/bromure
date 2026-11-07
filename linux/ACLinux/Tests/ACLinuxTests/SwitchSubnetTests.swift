import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux
import SandboxEngine

/// The closed subnet on a switch whose uplink NATs it (passt), end to end
/// through InterimSwitch: what a VM sends reaches the uplink only as the
/// firewall allows, a VM speaks as itself only, and DHCP leases only to
/// the asking port.
@Suite("Switch subnet and source pinning", .serialized)
struct SwitchSubnetTests {
    /// An uplink that keeps what the switch sends it.
    final class RecordingUplink: Uplink, @unchecked Sendable {
        let sent = NIOLockedValueBox<[Data]>([])
        let sink = RouteBench.SinkPort("up")
        var receiver: (@Sendable (inout Data) -> Void)?
        var batchEnd: (@Sendable () -> Void)?
        var name: String { "up" }
        var inbound: FrameSequence { sink.inbound }
        func send(_ f: Data) -> FrameSendResult { sent.withLockedValue { $0.append(f) }; return .queued }
        func sendWaiting(_ f: Data) async { sent.withLockedValue { $0.append(f) } }
        var isWritable: Bool { true }
        var stats: FramePortStats { sink.stats }
        var gatewayMAC: String? { "9a:55:9a:55:9a:55" }
        var mtu: Int { 65520 }
        func setReceiver(_ r: (@Sendable (inout Data) -> Void)?, batchEnd: (@Sendable () -> Void)?) {
            receiver = r; self.batchEnd = batchEnd
        }
        func close() async {}
    }

    static let gwMAC: [UInt8] = [0x9a, 0x55, 0x9a, 0x55, 0x9a, 0x55]
    static func ip(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }

    static func ipv4(src: [UInt8], dst: [UInt8], from smac: [UInt8], to dmac: [UInt8], dport: UInt16 = 8080) -> Data {
        let ipH: [UInt8] = [0x45, 0, 0, 40, 0, 1, 0, 0, 64, 6, 0, 0] + src + dst
        let tcp: [UInt8] = [0x9c, 0x40, UInt8(dport >> 8), UInt8(dport & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
        return Data(dmac + smac + [0x08, 0x00] + ipH + tcp)
    }

    /// An ARP request (op 1) or reply (op 2) from `smac`, as `senderIP`.
    static func arp(op: UInt8, from smac: [UInt8], senderIP: [UInt8], target: [UInt8], to dmac: [UInt8] = [UInt8](repeating: 0xff, count: 6)) -> Data {
        let body: [UInt8] = [0, 1, 0x08, 0x00, 6, 4, 0, op] + smac + senderIP + [UInt8](repeating: 0, count: 6) + target
        return Data(dmac + smac + [0x08, 0x06] + body)
    }

    final class Rig {
        let up = RecordingUplink()
        let sw: InterimSwitch
        let a = RouteBench.SinkPort("a"), b = RouteBench.SinkPort("b"), c = RouteBench.SinkPort("c")
        let ma: [UInt8] = [0x52, 0x54, 0, 0, 0, 0x0a], mb: [UInt8] = [0x52, 0x54, 0, 0, 0, 0x0b], mc: [UInt8] = [0x52, 0x54, 0, 0, 0, 0x0c]
        var ipA: [UInt8] = [], ipB: [UInt8] = [], ipC: [UInt8] = []
        init() throws {
            sw = InterimSwitch(uplink: up)
            sw.attach(a, mac: "52:54:00:00:00:0a"); sw.attach(b, mac: "52:54:00:00:00:0b"); sw.attach(c, mac: "52:54:00:00:00:0c")
            ipA = try #require(sw.dhcp.lease(for: ma)); ipB = try #require(sw.dhcp.lease(for: mb)); ipC = try #require(sw.dhcp.lease(for: mc))
        }
        func delivered(_ p: RouteBench.SinkPort) -> Int { p.stats.queued + p.stats.sent }
        /// Feed a frame as the VM on `port` sent it, then let the switch's task run.
        func send(_ f: Data, on port: RouteBench.SinkPort) async {
            _ = await port.core.deliver(f)
            try? await Task.sleep(for: .milliseconds(40))
        }
        func stop() { sw.stop() }
    }

    @Test func aPeerFrameNeverReachesTheUplink() async throws {
        let rig = try Rig(); defer { rig.stop() }
        // (a) To B's address under the broadcast MAC: flooded to the peers, not passt.
        await rig.send(Self.ipv4(src: rig.ipA, dst: rig.ipB, from: rig.ma, to: [UInt8](repeating: 0xff, count: 6)), on: rig.a)
        #expect(rig.delivered(rig.b) >= 1, "B gets it")
        // (b) To A's own address through the gateway's MAC.
        await rig.send(Self.ipv4(src: rig.ipA, dst: rig.ipA, from: rig.ma, to: Self.gwMAC), on: rig.a)
        // To an unknown MAC, B's address: flooded, never the uplink.
        await rig.send(Self.ipv4(src: rig.ipA, dst: rig.ipB, from: rig.ma, to: [0x02, 1, 2, 3, 4, 5]), on: rig.a)
        #expect(rig.up.sent.withLockedValue { $0 }.isEmpty, "nothing to passt")
        // The gateway's DNS still goes to the uplink.
        await rig.send(Self.ipv4(src: rig.ipA, dst: Self.ip("192.168.64.1"), from: rig.ma, to: Self.gwMAC, dport: 53), on: rig.a)
        #expect(rig.up.sent.withLockedValue { $0.count } == 1)
    }

    @Test func aVMSpeaksAsItselfOnly() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let toDNS = { (src: [UInt8], mac: [UInt8]) in Self.ipv4(src: src, dst: Self.ip("192.168.64.1"), from: mac, to: Self.gwMAC, dport: 53) }
        await rig.send(toDNS(rig.ipA, rig.mb), on: rig.a)                    // B's MAC
        await rig.send(toDNS(Self.ip("192.168.64.1"), rig.ma), on: rig.a)     // the gateway's address
        await rig.send(toDNS(rig.ipB, rig.ma), on: rig.a)                     // B's address
        #expect(rig.up.sent.withLockedValue { $0 }.isEmpty, "none of the forged frames left")
        // An ARP reply claiming the gateway (to capture the peers' DNS): dropped.
        let before = rig.delivered(rig.b)
        await rig.send(Self.arp(op: 2, from: rig.ma, senderIP: Self.ip("192.168.64.1"), target: rig.ipB), on: rig.a)
        #expect(rig.delivered(rig.b) == before, "B never hears it")
        // As itself: through. A probe from the unspecified address too.
        await rig.send(toDNS(rig.ipA, rig.ma), on: rig.a)
        await rig.send(Self.arp(op: 1, from: rig.ma, senderIP: [0, 0, 0, 0], target: rig.ipA), on: rig.a)
        #expect(rig.up.sent.withLockedValue { $0.count } >= 1)
    }

    @Test func dhcpLeasesOnlyForTheAskingPort() throws {
        let rig = try Rig(); defer { rig.stop() }
        func discover(chaddr: [UInt8], src: [UInt8]) -> Data {
            var bootp = [UInt8](repeating: 0, count: 240)
            bootp[0] = 1; bootp[1] = 1; bootp[2] = 6
            for i in 0..<6 { bootp[28 + i] = chaddr[i] }
            bootp[236] = 99; bootp[237] = 130; bootp[238] = 83; bootp[239] = 99
            let opts: [UInt8] = [53, 1, 1, 255]
            let udpLen = 8 + bootp.count + opts.count
            let ipH: [UInt8] = [0x45, 0, UInt8((20 + udpLen) >> 8), UInt8((20 + udpLen) & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255]
            let udp: [UInt8] = [0, 68, 0, 67, UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]
            return Data([UInt8](repeating: 0xff, count: 6) + src + [0x08, 0x00] + ipH + udp + bootp + opts)
        }
        let other: [UInt8] = [0x52, 0x54, 0, 0, 0, 0x7e]
        #expect(rig.sw.dhcp.handle(discover(chaddr: other, src: rig.ma), port: rig.ma) == nil, "another hardware address")
        #expect(rig.sw.dhcp.handle(discover(chaddr: other, src: other), port: rig.ma) == nil, "another source MAC")
        #expect(rig.sw.dhcp.mac(forIP: InterimDHCP.u32(rig.ipA)) == MAC(rig.ma))
        #expect(rig.sw.dhcp.handle(discover(chaddr: rig.ma, src: rig.ma), port: rig.ma) != nil, "its own")
    }

    @Test func aClustersNodeAnswersOnlyForItsClustersAddresses() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let lb = Self.ip("192.168.64.240"), lbU = InterimDHCP.u32(lb)
        let range = InterimDHCP.u32(Self.ip("192.168.64.230"))...InterimDHCP.u32(Self.ip("192.168.64.249"))
        VMNetSwitch.shared.reserveIPs(Set(range))
        defer { VMNetSwitch.shared.unreserveIPs(Set(range)) }
        rig.sw.allowReservedClaims(mac: "52:54:00:00:00:0a", cluster: "cluster-1", range: range)
        rig.sw.allowReservedClaims(mac: "52:54:00:00:00:0b", cluster: "cluster-2", range: range)
        // A (cluster 1's node) announces .240: the peers hear it.
        let cBefore = rig.delivered(rig.c)
        await rig.send(Self.arp(op: 2, from: rig.ma, senderIP: lb, target: lb), on: rig.a)
        #expect(rig.delivered(rig.c) > cBefore, "announced to the peers")
        // B (cluster 2's) can't take it over, and C (a session VM) can't claim it at all.
        let aBefore = rig.delivered(rig.a)
        await rig.send(Self.arp(op: 2, from: rig.mb, senderIP: lb, target: lb), on: rig.b)
        await rig.send(Self.arp(op: 2, from: rig.mc, senderIP: lb, target: lb), on: rig.c)
        #expect(rig.delivered(rig.a) == aBefore, "neither claim is heard")
        // C reaches .240 at the node that answers for it, never through passt.
        await rig.send(Self.arp(op: 1, from: rig.mc, senderIP: rig.ipC, target: lb), on: rig.c)
        await rig.send(Self.ipv4(src: rig.ipC, dst: lb, from: rig.mc, to: rig.ma, dport: 80), on: rig.c)
        #expect(rig.delivered(rig.a) > aBefore, "to cluster 1's node")
        #expect(rig.up.sent.withLockedValue { $0 }.isEmpty, "neither the ARP nor the frame reached passt")
        // Cluster 1's last node goes: the address is free for cluster 2.
        rig.sw.detach(mac: "52:54:00:00:00:0a")
        #expect(rig.sw.speaksAsItself(Self.arp(op: 2, from: rig.mb, senderIP: lb, target: lb), from: MAC(rig.mb)))
        _ = lbU
    }

    /// UDP to `dst` from the VM on `smac` as `src`.
    static func udp(src: [UInt8], dst: [UInt8], from smac: [UInt8], to dmac: [UInt8], dport: UInt16 = 5353) -> Data {
        let ipH: [UInt8] = [0x45, 0, 0, 28, 0, 1, 0, 0, 64, 17, 0, 0] + src + dst
        let u: [UInt8] = [0x14, 0xe9, UInt8(dport >> 8), UInt8(dport & 0xFF), 0, 8, 0, 0]
        return Data(dmac + smac + [0x08, 0x00] + ipH + u)
    }

    /// An IPv6 frame from `smac` as `src` (16 bytes): a Neighbor
    /// Advertisement for `target` when given, else an empty UDP datagram.
    static func ipv6(src: [UInt8], from smac: [UInt8], na target: [UInt8]? = nil) -> Data {
        let dst: [UInt8] = [0xff, 0x02] + [UInt8](repeating: 0, count: 13) + [1]
        var payload: [UInt8]
        var next: UInt8
        if let target { next = 58; payload = [136, 0, 0, 0, 0x20, 0, 0, 0] + target } else { next = 17; payload = [0, 1, 0, 2, 0, 8, 0, 0] }
        let ipH: [UInt8] = [0x60, 0, 0, 0, 0, UInt8(payload.count), next, 255] + src + dst
        return Data([0x33, 0x33, 0, 0, 0, 1] + smac + [0x86, 0xDD] + ipH + payload)
    }

    @Test func aGovernedPortsUnreadableFramesAreDropped() async throws {
        let rig = try Rig(); defer { rig.stop() }
        var p = Profile(name: "g", tool: .claude, authMode: .token)
        p.egressRules = "default allow"
        rig.sw.egress.govern(MAC(rig.ma), .init(p))
        let good = Self.ipv4(src: rig.ipA, dst: Self.ip("1.1.1.1"), from: rig.ma, to: Self.gwMAC, dport: 8080)
        var ihl4 = good; ihl4[14] = 0x44                                    // IHL 4 (16 bytes)
        var long = good; long[16] = 0x05; long[17] = 0xdc                   // total length 1500, frame 54
        var notV4 = good; notV4[14] = 0x65                                   // version 6 under 0x0800
        let vlan = Data(Self.gwMAC + rig.ma + [0x81, 0x00, 0, 5, 0x08, 0x00]) + good.dropFirst(14)
        let short = good.prefix(30)
        for f in [ihl4, long, notV4, vlan, short] { await rig.send(f, on: rig.a) }
        #expect(rig.up.sent.withLockedValue { $0 }.isEmpty, "none of them reached passt")
        await rig.send(good, on: rig.a)
        #expect(rig.up.sent.withLockedValue { $0.count } == 1, "a well-formed one does")
        // A VLAN tag from an ungoverned port (a cluster node's) too: no port's to send.
        await rig.send(Data(Self.gwMAC + rig.mb + [0x81, 0x00, 0, 5, 0x08, 0x00]) + good.dropFirst(14), on: rig.b)
        #expect(rig.up.sent.withLockedValue { $0.count } == 1)
        #expect(!rig.sw.speaksAsItself(Data(Self.gwMAC + rig.mb + [0x88, 0xA8, 0, 5, 0x08, 0x00]) + good.dropFirst(14), from: MAC(rig.mb)))
    }

    @Test func multicastAndTheLimitedBroadcastReachThePeersOnly() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let bcast = [UInt8](repeating: 0xff, count: 6)
        let b0 = rig.delivered(rig.b)
        await rig.send(Self.udp(src: rig.ipA, dst: Self.ip("224.0.0.251"), from: rig.ma, to: [0x01, 0, 0x5e, 0, 0, 0xfb]), on: rig.a)
        await rig.send(Self.udp(src: rig.ipA, dst: Self.ip("255.255.255.255"), from: rig.ma, to: bcast, dport: 9), on: rig.a)
        await rig.send(Self.udp(src: rig.ipA, dst: Self.ip("239.1.2.3"), from: rig.ma, to: [0x01, 0, 0x5e, 1, 2, 3]), on: rig.a)
        #expect(rig.delivered(rig.b) >= b0 + 3, "the peers hear them")
        #expect(rig.up.sent.withLockedValue { $0 }.isEmpty, "passt (the server's network) doesn't")
    }

    @Test func anARPSenderMACIsThePortsOwn() async throws {
        let rig = try Rig(); defer { rig.stop() }
        // A's port, A's address, but B's MAC as the ARP sender hardware address.
        var forged = [UInt8](Self.arp(op: 2, from: rig.ma, senderIP: rig.ipA, target: rig.ipC))
        for i in 0..<6 { forged[22 + i] = rig.mb[i] }
        let c0 = rig.delivered(rig.c)
        await rig.send(Data(forged), on: rig.a)
        #expect(rig.delivered(rig.c) == c0, "dropped")
        await rig.send(Self.arp(op: 2, from: rig.ma, senderIP: rig.ipA, target: rig.ipC), on: rig.a)
        #expect(rig.delivered(rig.c) > c0, "as itself: through")
    }

    @Test func anIPv6AddressBelongsToTheFirstPortThatSpeaksAsIt() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let ll: [UInt8] = [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [0x0a]
        let c0 = rig.delivered(rig.c)
        await rig.send(Self.ipv6(src: ll, from: rig.ma), on: rig.a)
        #expect(rig.delivered(rig.c) > c0, "A claims it")
        let c1 = rig.delivered(rig.c)
        await rig.send(Self.ipv6(src: ll, from: rig.mb), on: rig.b)
        await rig.send(Self.ipv6(src: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [0x0b], from: rig.mb, na: ll), on: rig.b)
        #expect(rig.delivered(rig.c) == c1, "B can't speak as A's address, nor advertise it")
        await rig.send(Self.ipv6(src: [UInt8](repeating: 0, count: 16), from: rig.mb), on: rig.b)
        #expect(rig.delivered(rig.c) > c1, "the unspecified source is anyone's (DAD)")
        // A goes: the address is free.
        rig.sw.detach(mac: "52:54:00:00:00:0a")
        #expect(rig.sw.speaksAsItself(Self.ipv6(src: ll, from: rig.mb), from: MAC(rig.mb)))
    }

    @Test func aPortsIPv6ClaimsAreCappedAndMadeOnlyForFramesThatPass() async throws {
        let rig = try Rig(); defer { rig.stop() }
        func addr(_ last: UInt8, global: Bool = false) -> [UInt8] {
            (global ? [0x20, 0x01, 0x0d, 0xb8] : [0xfe, 0x80, 0, 0]) + [UInt8](repeating: 0, count: 11) + [last]
        }
        // 20 random sources from A: it holds its own link-local and 15 more.
        for i in 1...20 { await rig.send(Self.ipv6(src: addr(UInt8(i)), from: rig.ma), on: rig.a) }
        let held = rig.sw.v6Owners.withLockedValue { $0.count[MAC(rig.ma)] ?? 0 }
        #expect(held == InterimSwitch.v6PerPort, "capped: \(held)")
        #expect(rig.sw.v6Owners.withLockedValue { $0.owners.count } <= InterimSwitch.v6PerPort + 3 + 1,
                "the map holds the cap and the reserved link-locals, no more")
        // A frame the firewall drops claims nothing: B is governed and
        // inspected, and global IPv6 from it is dropped.
        var p = Profile(name: "g", tool: .claude, authMode: .token)
        p.egressRules = "default allow"
        rig.sw.egress.govern(MAC(rig.mb), .init(p))
        let g = addr(0x77, global: true)
        var out = [UInt8](Self.ipv6(src: g, from: rig.mb))
        for (i, x) in addr(0x01, global: true).enumerated() { out[38 + i] = x }   // to a global address
        for i in 0..<6 { out[i] = Self.gwMAC[i] }
        await rig.send(Data(out), on: rig.b)
        #expect(rig.sw.v6Owners.withLockedValue { $0.owners[g] } == nil, "a dropped frame claims nothing")
    }

    @Test func linkLocalsAreReservedAndRouterAdvertisementsRefused() async throws {
        let rig = try Rig(); defer { rig.stop() }
        // B's EUI-64 link-local is B's from attach: A can't speak as it, nor advertise it.
        let llB = InterimSwitch.linkLocal(MAC(rig.mb))
        #expect(!rig.sw.speaksAsItself(Self.ipv6(src: llB, from: rig.ma), from: MAC(rig.ma)))
        #expect(!rig.sw.speaksAsItself(Self.ipv6(src: InterimSwitch.linkLocal(MAC(rig.ma)), from: rig.ma, na: llB), from: MAC(rig.ma)))
        #expect(rig.sw.speaksAsItself(Self.ipv6(src: InterimSwitch.linkLocal(MAC(rig.ma)), from: rig.ma), from: MAC(rig.ma)),
                "its own is its")
        // The gateway's (passt's) link-local is nobody's.
        let gw = InterimSwitch.linkLocal(MAC(Self.gwMAC))
        #expect(!rig.sw.speaksAsItself(Self.ipv6(src: gw, from: rig.ma), from: MAC(rig.ma)))
        // A router advertisement from a VM: refused.
        var ra = [UInt8](Self.ipv6(src: InterimSwitch.linkLocal(MAC(rig.ma)), from: rig.ma, na: [UInt8](repeating: 0, count: 16)))
        ra[54] = 134
        #expect(!rig.sw.speaksAsItself(Data(ra), from: MAC(rig.ma)))
    }

    /// A raw IPv6 frame from `smac`: `next` after the fixed header, then `body`.
    static func rawV6(src: [UInt8], from smac: [UInt8], next: UInt8, body: [UInt8]) -> Data {
        let dst: [UInt8] = [0xff, 0x02] + [UInt8](repeating: 0, count: 13) + [1]
        let ipH: [UInt8] = [0x60, 0, 0, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF), next, 255] + src + dst
        return Data([0x33, 0x33, 0, 0, 0, 1] + smac + [0x86, 0xDD] + ipH + body)
    }

    @Test func nothingHidesBehindAnExtensionHeader() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let ll = InterimSwitch.linkLocal(MAC(rig.ma))
        func speaks(_ f: Data) -> Bool { rig.sw.speaksAsItself(f, from: MAC(rig.ma)) }
        let ra: [UInt8] = [134, 0, 0, 0] + [UInt8](repeating: 0, count: 12)
        // An RA behind hop-by-hop (0) and behind destination options (60): refused,
        // as is the bare one.
        let ext: [UInt8] = [58, 0, 1, 4, 0, 0, 0, 0]          // next: ICMPv6; 8 bytes; a PadN
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 0, body: ext + ra)))
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 60, body: ext + ra)))
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 58, body: ra)))
        // A fragment (44), a routing header (43): refused.
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 44, body: [58, 0, 0, 1, 0, 0, 0, 1] + ra)))
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 43, body: ext + ra)))
        // A DHCPv6 server's reply (UDP from 547) and a multicast source: refused.
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 17, body: [0x02, 0x23, 0x02, 0x22, 0, 8, 0, 0])))
        #expect(!speaks(Self.rawV6(src: [0xff, 0x02] + [UInt8](repeating: 0, count: 13) + [1], from: rig.ma, next: 17, body: [0, 1, 0, 2, 0, 8, 0, 0])))
        // An ICMPv6 frame of exactly 54 bytes (no ICMPv6 header): refused, nothing read past its end.
        #expect(!speaks(Self.rawV6(src: ll, from: rig.ma, next: 58, body: [])))
        // An echo request, plain: through.
        #expect(speaks(Self.rawV6(src: ll, from: rig.ma, next: 58, body: [128, 0, 0, 0, 0, 1, 0, 1])))
    }

    @Test func aPeersSLAACAddressIsThePeersAndALostRaceDropsTheFrame() async throws {
        let rig = try Rig(); defer { rig.stop() }
        // B's interface id under a global prefix (its SLAAC address): not A's to speak as.
        let iidB = Array(InterimSwitch.linkLocal(MAC(rig.mb))[8..<16])
        let slaacB: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0] + iidB
        #expect(!rig.sw.speaksAsItself(Self.ipv6(src: slaacB, from: rig.ma), from: MAC(rig.ma)))
        #expect(rig.sw.speaksAsItself(Self.ipv6(src: slaacB, from: rig.mb), from: MAC(rig.mb)), "B's own")
        // Two ports racing for one address: the loser's frame is dropped.
        let x: [UInt8] = [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [0x42]
        #expect(rig.sw.claimV6(Self.ipv6(src: x, from: rig.ma), MAC(rig.ma)))
        #expect(!rig.sw.claimV6(Self.ipv6(src: x, from: rig.mb), MAC(rig.mb)), "B lost it: dropped")
    }

    @Test func whatAPeerTookBeforeAPortAttachedIsThePortsAndProbesAreChecked() async throws {
        let rig = try Rig(); defer { rig.stop() }
        // A port about to attach: its MAC is predictable, so A takes its
        // link-local and its SLAAC address first.
        let late: [UInt8] = [0x52, 0x54, 0, 0, 0, 0x0d]
        let ll = InterimSwitch.linkLocal(MAC(late))
        let slaac: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0] + Array(ll[8..<16])
        #expect(rig.sw.claimV6(Self.ipv6(src: ll, from: rig.ma), MAC(rig.ma)))
        #expect(rig.sw.claimV6(Self.ipv6(src: slaac, from: rig.ma), MAC(rig.ma)))
        let heldBefore = rig.sw.v6Owners.withLockedValue { $0.count[MAC(rig.ma)] ?? 0 }
        let d = RouteBench.SinkPort("d")
        rig.sw.attach(d, mac: "52:54:00:00:00:0d")
        #expect(rig.sw.speaksAsItself(Self.ipv6(src: ll, from: late), from: MAC(late)), "its link-local is its")
        #expect(rig.sw.speaksAsItself(Self.ipv6(src: slaac, from: late), from: MAC(late)), "and its SLAAC address")
        #expect(!rig.sw.speaksAsItself(Self.ipv6(src: ll, from: rig.ma), from: MAC(rig.ma)), "A lost them")
        #expect(rig.sw.v6Owners.withLockedValue { $0.count[MAC(rig.ma)] ?? 0 } == heldBefore - 2, "and A's count with them")
        // A duplicate address detection probe (from ::) for B's address: refused.
        var probe = [UInt8](Self.ipv6(src: [UInt8](repeating: 0, count: 16), from: rig.ma, na: InterimSwitch.linkLocal(MAC(rig.mb))))
        probe[54] = 135
        #expect(!rig.sw.speaksAsItself(Data(probe), from: MAC(rig.ma)))
        var own = [UInt8](Self.ipv6(src: [UInt8](repeating: 0, count: 16), from: rig.ma, na: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [0x99]))
        own[54] = 135
        #expect(rig.sw.speaksAsItself(Data(own), from: MAC(rig.ma)), "a probe for a free address: through")
        // ESP (a guest's IPsec): through.
        #expect(rig.sw.speaksAsItself(Self.rawV6(src: InterimSwitch.linkLocal(MAC(rig.ma)), from: rig.ma, next: 50, body: [0, 0, 1, 0, 0, 0, 0, 1]),
                                      from: MAC(rig.ma)))
        rig.sw.detach(mac: "52:54:00:00:00:0d")
    }

    @Test func twoPortsRacingForOneAddressLeaveOneWinner() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let sw = rig.sw, ma = rig.ma, mb = rig.mb
        for i in 0..<50 {
            let x: [UInt8] = [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [UInt8(0x50 + i)]
            let wins = NIOLockedValueBox(0)
            DispatchQueue.concurrentPerform(iterations: 2) { k in
                let mac = k == 0 ? ma : mb
                if sw.claimV6(Self.ipv6(src: x, from: mac), MAC(mac)) { wins.withLockedValue { $0 += 1 } }
            }
            #expect(wins.withLockedValue { $0 } == 1, "one winner for \(x.last!)")
            if wins.withLockedValue({ $0 }) != 1 { break }
            if i == 6 { break }    // within each port's cap
        }
    }
}
