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
}
