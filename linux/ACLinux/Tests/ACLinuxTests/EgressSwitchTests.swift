import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux
import SandboxEngine

// MARK: - Frames

/// Ethernet + IPv4 + TCP/UDP frames as a guest sends them.
enum TestFrames {
    static let guest: [UInt8] = [0x52, 0x54, 0x00, 0x00, 0x00, 0x0a]
    static let gateway: [UInt8] = [0x9a, 0x55, 0x9a, 0x55, 0x9a, 0x55]
    static let guestIP: UInt32 = 0xC0A8_400A          // 192.168.64.10

    static func ip(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// A TCP segment (flags: 0x02 SYN, 0x10 ACK…) from the guest to `dst:dport`.
    static func tcp(to dst: UInt32, port dport: UInt16, flags: UInt8, seq: UInt32 = 1000, ack: UInt32 = 0,
                    sport: UInt16 = 40000, fragment: UInt16 = 0) -> Data {
        var ipH: [UInt8] = [0x45, 0, 0, 40, 0, 1] + be16(fragment) + [64, 6, 0, 0] + be32(guestIP) + be32(dst)
        ipH[2] = 0; ipH[3] = 40
        let tcpH: [UInt8] = be16(sport) + be16(dport) + be32(seq) + be32(ack) + [0x50, flags] + be16(65535) + [0, 0, 0, 0]
        return Data(gateway + guest + [0x08, 0x00] + ipH + tcpH)
    }

    /// A UDP datagram from the guest.
    static func udp(to dst: UInt32, port dport: UInt16, sport: UInt16 = 50000, payload: [UInt8] = [1, 2, 3, 4]) -> Data {
        let len = UInt16(28 + payload.count)
        let ipH: [UInt8] = [0x45, 0] + be16(len) + [0, 1, 0, 0, 64, 17, 0, 0] + be32(guestIP) + be32(dst)
        let udpH: [UInt8] = be16(sport) + be16(dport) + be16(UInt16(8 + payload.count)) + [0, 0]
        return Data(gateway + guest + [0x08, 0x00] + ipH + udpH + payload)
    }

    /// An IPv6 frame to `dst` (16 bytes).
    static func ipv6(to dst: [UInt8]) -> Data {
        let h: [UInt8] = [0x60, 0, 0, 0, 0, 8, 17, 64] + [UInt8](repeating: 0, count: 15) + [1] + dst
        return Data(gateway + guest + [0x86, 0xDD] + h + [0, 1, 0, 2, 0, 8, 0, 0])
    }

    /// A DNS answer (UDP from :53) toward the guest: `name` is at `addr`.
    static func dnsAnswer(name: String, addr: UInt32, ttl: UInt32 = 300) -> Data {
        var q: [UInt8] = []
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q.append(0)
        let dns: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0] + q + [0, 1, 0, 1]
            + [0xC0, 0x0C, 0, 1, 0, 1] + be32(ttl) + [0, 4] + be32(addr)
        let len = UInt16(28 + dns.count)
        let ipH: [UInt8] = [0x45, 0] + be16(len) + [0, 1, 0, 0, 64, 17, 0, 0] + be32(ip("192.168.64.1")) + be32(guestIP)
        let udpH: [UInt8] = be16(53) + be16(50000) + be16(UInt16(8 + dns.count)) + [0, 0]
        return Data(guest + gateway + [0x08, 0x00] + ipH + udpH + dns)
    }
}

/// A firewall, the packets it injected toward each VM, and the events it reported.
final class FirewallRig: @unchecked Sendable {
    let injected = NIOLockedValueBox<[(mac: MAC, ip: [UInt8])]>([])
    let events = NIOLockedValueBox<[VMNetSwitch.EgressEvent]>([])
    let fw: SwitchEgressFirewall
    let a = MAC(TestFrames.guest)
    let pid = UUID()

    /// Addresses leased to VMs (peers).
    let leases = NIOLockedValueBox<Set<UInt32>>([])

    init(closesSubnet: Bool = true) {
        let injected = self.injected
        let leases = self.leases
        fw = SwitchEgressFirewall(gatewayIP: TestFrames.ip("192.168.64.1"),
                                  isLeased: { ip, _ in leases.withLockedValue { $0.contains(ip) } },
                                  isReserved: { ip in ip >= TestFrames.ip("192.168.64.230") && ip <= TestFrames.ip("192.168.64.249") },
                                  closesSubnet: closesSubnet) { mac, ip in
            injected.withLockedValue { $0.append((mac, ip)) }
        }
        let events = self.events
        fw.observer = { ev in events.withLockedValue { $0.append(ev) } }
    }

    func govern(_ rules: String?, interceptDisabled: Bool = false) throws {
        fw.govern(a, .init(profileID: pid, policy: try rules.map { try EgressPolicy.parse($0) },
                           interceptDisabled: interceptDisabled))
    }
}

/// A transparent interceptor that only records what the switch diverted.
final class RecordingInterceptor: VMNetTCPInterceptor, @unchecked Sendable {
    let diverted = NIOLockedValueBox<[(portID: Int, ip: [UInt8])]>([])
    let denied = NIOLockedValueBox<Int>(0)
    func handleDivertedPacket(portID: Int, profileID: UUID?, ipPacket: [UInt8]) {
        diverted.withLockedValue { $0.append((portID, ipPacket)) }
    }
    func portClosed(portID: Int) {}
    func flowDenied(portID: Int, ipPacket: [UInt8]) { denied.withLockedValue { $0 += 1 } }
}

@Suite("Switch egress firewall")
struct SwitchEgressFirewallTests {
    let evil = TestFrames.ip("203.0.113.7")
    let good = TestFrames.ip("198.51.100.9")

    @Test func aDeniedSYNIsAnsweredWithMacOSsRST() throws {
        let rig = FirewallRig()
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        let syn = TestFrames.tcp(to: evil, port: 443, flags: 0x02, seq: 7777)
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed)
        let expected: [UInt8] = syn.withUnsafeBytes { raw in
            VMNetSwitch.buildTCPReset(UnsafeMutablePointer(mutating: raw.baseAddress!.assumingMemoryBound(to: UInt8.self)), raw.count)
        }
        let got = rig.injected.withLockedValue { $0 }
        #expect(got.count == 1)
        #expect(got.first?.mac == rig.a)
        #expect(got.first?.ip == expected, "the shared builder's RST, byte for byte")
        #expect(got.first?.ip[33] == 0x14, "RST|ACK")
        #expect(Array(got.first!.ip[28..<32]) == TestFrames.be32(7778), "acks the guest's SYN")
        let ev = rig.events.withLockedValue { $0 }
        #expect(ev.count == 1 && ev[0].denied && ev[0].port == 443 && ev[0].profileID == rig.pid)
        #expect(ev[0].rule == "deny tcp 203.0.113.7")
    }

    @Test func anEstablishedFlowDeniedNowGetsTheEstablishedRST() throws {
        let rig = FirewallRig()
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        let ack = TestFrames.tcp(to: evil, port: 22, flags: 0x10, seq: 5, ack: 0xABCD_0001)
        #expect(rig.fw.handle(ack, from: rig.a) == .consumed)
        let rst = rig.injected.withLockedValue { $0 }.first?.ip
        #expect(rst?[33] == 0x04, "a bare RST")
        #expect(rst.map { Array($0[24..<28]) } == TestFrames.be32(0xABCD_0001), "at the guest's own ACK number")
        #expect(rig.events.withLockedValue { $0 }.first?.midFlow == true)
    }

    @Test func allowedAndNonSessionFramesPass() throws {
        let rig = FirewallRig()
        // Not a session port: never governed.
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) == .pass)
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        #expect(rig.fw.handle(TestFrames.tcp(to: good, port: 443, flags: 0x02), from: rig.a) == .pass)
        // Another VM's port isn't this workspace's.
        let other = MAC([0x52, 0x54, 0, 0, 0, 0x0b])
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: other) == .pass)
        #expect(rig.injected.withLockedValue { $0 }.isEmpty)
    }

    @Test func onTheSubnetOnlyPeersAndTheGatewaysDNSPass() throws {
        // passt NATs whatever reaches it into a host connect() on the
        // server's own network: the subnet isn't closed, as vmnet's is.
        let rig = FirewallRig()
        let gw = TestFrames.ip("192.168.64.1"), peer = TestFrames.ip("192.168.64.11"), unleased = TestFrames.ip("192.168.64.77")
        rig.leases.withLockedValue { $0 = [peer] }
        let other = MAC([0x52, 0x54, 0, 0, 0, 0x0b])
        for (who, port) in [("a session port", rig.a), ("an ungoverned port", other)] {
            if who == "a session port" { try rig.govern(nil) }
            #expect(rig.fw.handle(TestFrames.tcp(to: peer, port: 8080, flags: 0x02), from: port) == .peersOnly, "\(who): a peer, never the uplink")
            #expect(rig.fw.handle(TestFrames.tcp(to: TestFrames.ip("192.168.64.240"), port: 80, flags: 0x02), from: port) == .peersOnly,
                    "\(who): a cluster's LoadBalancer address, to the node that answers for it")
            #expect(rig.fw.handle(TestFrames.udp(to: gw, port: 53), from: port) == .pass, "\(who): DNS")
            #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 53, flags: 0x02), from: port) == .pass, "\(who): DNS over TCP")
            #expect(rig.fw.handle(TestFrames.udp(to: TestFrames.ip("192.168.64.255"), port: 9), from: port) == .peersOnly, "\(who): broadcast")
            let before = rig.injected.withLockedValue { $0.count }
            #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 9999, flags: 0x02), from: port) == .consumed, "\(who): the gateway's other ports")
            #expect(rig.fw.handle(TestFrames.tcp(to: unleased, port: 22, flags: 0x02), from: port) == .consumed, "\(who): an unleased address")
            #expect(rig.fw.handle(TestFrames.udp(to: unleased, port: 161), from: port) == .consumed, "\(who): UDP too")
            #expect(rig.injected.withLockedValue { $0.count } == before + 2, "\(who): a RST for each refused connect")
        }
        let ev = rig.events.withLockedValue { $0 }
        #expect(ev.count == 3 && ev.allSatisfy { $0.denied && !$0.byPolicy }, "reported for the session port only, not as a rule's")
    }

    @Test func aSubnetTheUplinkDoesntNATStaysOpen() throws {
        // A tap: the subnet is a real interface the host's kernel routes, as
        // vmnet's on macOS. The host pinging a guest gets its reply.
        let rig = FirewallRig(closesSubnet: false)
        try rig.govern(nil)
        let gw = TestFrames.ip("192.168.64.1")
        #expect(rig.fw.handle(TestFrames.tcp(to: gw, port: 9999, flags: 0x02), from: rig.a) == .pass)
        #expect(rig.fw.handle(TestFrames.udp(to: TestFrames.ip("192.168.64.77"), port: 161), from: rig.a) == .pass)
        #expect(rig.injected.withLockedValue { $0 }.isEmpty)
        // A tap says its subnet isn't NATed (passt keeps the default: it is).
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0, &fds) == 0)
        let tap = TapUplink(name: "fake-tap", fd: fds[0])
        #expect(!tap.natsSubnet)
        tap.close()
        close(fds[1])
    }

    @Test func aWorkspacesPolicyIsItsOwn() throws {
        // Two workspaces on one switch: A's rule never touches B's VM.
        let rig = FirewallRig()
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        let b = MAC([0x52, 0x54, 0, 0, 0, 0x0b])
        rig.fw.govern(b, .init(profileID: UUID(), policy: nil, interceptDisabled: false))
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: b) == .pass)
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) == .consumed)
        // A live edit of A's policy reaches A's port only.
        rig.fw.update(.init(profileID: rig.pid, policy: try EgressPolicy.parse("default allow"), interceptDisabled: false))
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) == .pass)
    }

    @Test func hostnameRulesMatchTheSnoopedAnswers() throws {
        let rig = FirewallRig()
        try rig.govern("deny tcp evil.example\ndefault allow")
        let syn = TestFrames.tcp(to: good, port: 443, flags: 0x02)
        #expect(rig.fw.handle(syn, from: rig.a) == .pass, "nothing says the address is evil.example yet")
        // The guest's own resolver answers: evil.example is at that address.
        rig.fw.snoop(TestFrames.dnsAnswer(name: "evil.example", addr: good))
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed)
        #expect(rig.events.withLockedValue { $0 }.last?.hostnames == ["evil.example"])
    }

    @Test func bypassTransportsAreDroppedOnInspectedVMsOnly() throws {
        let rig = FirewallRig()
        let quic = TestFrames.udp(to: good, port: 443)
        let frag = TestFrames.tcp(to: good, port: 443, flags: 0x02, fragment: 0x2000)  // MF
        let v6 = TestFrames.ipv6(to: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1])
        let linkLocal = TestFrames.ipv6(to: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1])
        // A session VM with no rules and no interception: not inspected.
        try rig.govern(nil)
        for f in [quic, frag, v6] { #expect(rig.fw.handle(f, from: rig.a) == .pass) }
        // An active policy makes it inspected.
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        for f in [quic, frag, v6] { #expect(rig.fw.handle(f, from: rig.a) == .consumed) }
        #expect(rig.fw.handle(linkLocal, from: rig.a) == .pass, "ND / RA still work")
        #expect(rig.fw.handle(TestFrames.udp(to: good, port: 53), from: rig.a) == .pass, "other UDP is the L4 rules'")
        #expect(rig.events.withLockedValue { $0 }.filter(\.denied).allSatisfy { !$0.byPolicy }, "transport drops aren't a rule's")
        // So does interception, policy or not.
        rig.fw.setInterception(.init(interceptor: RecordingInterceptor(), ports: [80, 443]))
        try rig.govern(nil)
        #expect(rig.fw.handle(quic, from: rig.a) == .consumed)
        try rig.govern(nil, interceptDisabled: true)
        #expect(rig.fw.handle(quic, from: rig.a) == .pass, "a workspace that opted out")
    }

    @Test func interceptedPortsAreDivertedAndAHostnameDenyDefersToTheMITM() throws {
        let rig = FirewallRig()
        let mitm = RecordingInterceptor()
        rig.fw.setInterception(.init(interceptor: mitm, ports: [80, 443]))
        try rig.govern(nil)
        #expect(rig.fw.handle(TestFrames.tcp(to: good, port: 443, flags: 0x02), from: rig.a) == .consumed)
        #expect(rig.fw.handle(TestFrames.tcp(to: good, port: 22, flags: 0x02), from: rig.a) == .pass)
        #expect(mitm.diverted.withLockedValue { $0.count } == 1)
        #expect(mitm.diverted.withLockedValue { $0 }.first?.ip.count == 40, "IP header onward")
        // An IP rule decides here; the MITM never sees the flow.
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) == .consumed)
        #expect(mitm.diverted.withLockedValue { $0.count } == 1)
        #expect(rig.injected.withLockedValue { $0.count } == 1, "RST")
        // A rule the switch can't judge without the name: a deny an OpenShell
        // policy keys by hostname goes to the MITM, which reads the SNI. (An
        // address-keyed pf rule doesn't defer: checked by the shared
        // EgressPolicy.defersToInterception.)
        // An established flow denied now: RST, and the MITM drops its half.
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x10, ack: 9), from: rig.a) == .consumed)
        #expect(mitm.denied.withLockedValue { $0 } == 1)
    }

    /// The agent watchdog's quarantine (macOS: handleEgress's first check):
    /// no IP leaves the port, on or off the subnet, governed or not; ARP
    /// still goes. A release lets it out again, a detach forgets it.
    @Test func aQuarantinedPortSendsNoIP() throws {
        let rig = FirewallRig()
        try rig.govern(nil)
        let gw = TestFrames.ip("192.168.64.1")
        let arp = Data(TestFrames.gateway + TestFrames.guest + [0x08, 0x06] + [UInt8](repeating: 0, count: 28))
        rig.fw.setQuarantined(true, for: rig.a)
        for (what, f) in [("off-subnet", TestFrames.tcp(to: good, port: 443, flags: 0x02)),
                          ("the gateway's DNS", TestFrames.udp(to: gw, port: 53)),
                          ("a broadcast", TestFrames.udp(to: TestFrames.ip("192.168.64.255"), port: 9)),
                          ("the limited broadcast", TestFrames.udp(to: 0xFFFF_FFFF, port: 67)),
                          ("IPv6", TestFrames.ipv6(to: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]))] {
            #expect(rig.fw.handle(f, from: rig.a) == .consumed, "\(what)")
        }
        #expect(rig.fw.handle(arp, from: rig.a) == .pass, "ARP keeps the link up for a release")
        #expect(rig.fw.egressByteCount(for: rig.a) == 0, "nothing left, nothing counted")
        // An ungoverned port is cut off just the same.
        let other = MAC([0x52, 0x54, 0, 0, 0, 0x0b])
        rig.fw.setQuarantined(true, for: other)
        #expect(rig.fw.handle(TestFrames.udp(to: gw, port: 53), from: other) == .consumed)
        rig.fw.setQuarantined(false, for: rig.a)
        #expect(rig.fw.handle(TestFrames.tcp(to: good, port: 443, flags: 0x02), from: rig.a) == .pass)
        rig.fw.setQuarantined(true, for: rig.a)
        rig.fw.portClosed(rig.a)
        try rig.govern(nil)
        #expect(rig.fw.handle(TestFrames.tcp(to: good, port: 443, flags: 0x02), from: rig.a) == .pass, "a detach drops the quarantine")
    }

    /// The watchdog's volume signal reads the switch's own count: a session
    /// port's off-subnet frames, whole (not on-subnet ones, not an
    /// ungoverned port's); a detach starts it over.
    @Test func offSubnetBytesAreCountedPerSessionPort() throws {
        let rig = FirewallRig()
        let syn = TestFrames.tcp(to: good, port: 443, flags: 0x02)
        _ = rig.fw.handle(syn, from: rig.a)
        #expect(rig.fw.egressByteCount(for: rig.a) == 0, "not a session port yet")
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        _ = rig.fw.handle(syn, from: rig.a)
        _ = rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a)
        _ = rig.fw.handle(TestFrames.udp(to: TestFrames.ip("192.168.64.1"), port: 53), from: rig.a)
        #expect(rig.fw.egressByteCount(for: rig.a) == UInt64(2 * syn.count), "both off-subnet frames, denied or not; DNS isn't")
        rig.fw.portClosed(rig.a)
        #expect(rig.fw.egressByteCount(for: rig.a) == 0)
    }

    /// Binary identity (macOS: handleEgress's identityGate step): a new
    /// connection under a policy's `binaries` waits for the attestor's
    /// answer (its SYN held), is refused for a program the policy doesn't
    /// name (a RST, the program in the report), or allowed and remembered
    /// for its later segments, until a policy change has it asked again.
    /// No gate: refused.
    @Test func binaryIdentityAsksTheGate() throws {
        let rig = FirewallRig()
        var policy = try EgressPolicy.parse("default allow")
        policy.enforceBinaries = true
        rig.fw.govern(rig.a, .init(profileID: rig.pid, policy: policy, interceptDisabled: true))
        let syn = TestFrames.tcp(to: good, port: 22, flags: 0x02), ack = TestFrames.tcp(to: good, port: 22, flags: 0x10)
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed, "no gate: refused")
        let answer = NIOLockedValueBox<(verdict: EgressPolicy.Verdict, exe: String?)?>(nil)
        let asked = NIOLockedValueBox(0)
        rig.fw.identityGate = { _, _, _, _, _, _, _ in asked.withLockedValue { $0 += 1 }; return answer.withLockedValue { $0 } }
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed, "held while the attestor answers")
        let before = rig.injected.withLockedValue { $0.count }
        answer.withLockedValue { $0 = (.deny, "/usr/bin/curl") }
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed)
        #expect(rig.injected.withLockedValue { $0.count } == before + 1, "a RST for the refused connect")
        #expect(rig.events.withLockedValue { $0 }.contains { $0.denied && $0.exe == "/usr/bin/curl" }, "the program reported")
        answer.withLockedValue { $0 = (.allow, "/usr/bin/gh") }
        #expect(rig.fw.handle(syn, from: rig.a) == .pass, "allowed for its program")
        let n = asked.withLockedValue { $0 }
        #expect(rig.fw.handle(ack, from: rig.a) == .pass && asked.withLockedValue { $0 } == n, "later segments pass on the remembered decision")
        rig.fw.update(.init(profileID: rig.pid, policy: policy, interceptDisabled: true))
        #expect(rig.fw.handle(ack, from: rig.a) == .pass && asked.withLockedValue { $0 } == n + 1, "a policy change asks again")
    }

    /// A new SYN on a tuple is another connection: the allow remembered
    /// for the earlier one there is dropped before the gate is asked
    /// (macOS: handleEgress's forgetAttested).
    @Test func aNewSYNDropsTheRememberedAllow() throws {
        let rig = FirewallRig()
        var policy = try EgressPolicy.parse("default deny")
        policy.enforceBinaries = true
        rig.fw.govern(rig.a, .init(profileID: rig.pid, policy: policy, interceptDisabled: true))
        let syn = TestFrames.tcp(to: good, port: 22, flags: 0x02), ack = TestFrames.tcp(to: good, port: 22, flags: 0x10)
        let answer = NIOLockedValueBox<(verdict: EgressPolicy.Verdict, exe: String?)?>((.allow, "/usr/bin/gh"))
        rig.fw.identityGate = { _, _, _, _, _, _, _ in answer.withLockedValue { $0 } }
        #expect(rig.fw.handle(syn, from: rig.a) == .pass)
        #expect(rig.fw.handle(ack, from: rig.a) == .pass, "remembered")
        answer.withLockedValue { $0 = nil }
        #expect(rig.fw.handle(syn, from: rig.a) == .consumed, "the new SYN is held")
        #expect(rig.fw.handle(ack, from: rig.a) == .consumed, "and the old allow no longer carries its segments")
    }

    /// A policy change re-decides an open flow under the ISN it was allowed
    /// with, never under a key every re-decision of the tuple would share.
    @Test func aReDecisionAsksUnderTheFlowsISN() throws {
        let rig = FirewallRig()
        var policy = try EgressPolicy.parse("default deny")
        policy.enforceBinaries = true
        rig.fw.govern(rig.a, .init(profileID: rig.pid, policy: policy, interceptDisabled: true))
        let syn = TestFrames.tcp(to: good, port: 22, flags: 0x02), ack = TestFrames.tcp(to: good, port: 22, flags: 0x10)
        let isns = NIOLockedValueBox<[UInt32?]>([])
        rig.fw.identityGate = { _, _, _, _, isn, _, _ in isns.withLockedValue { $0.append(isn) }; return (.allow, "/usr/bin/gh") }
        #expect(rig.fw.handle(syn, from: rig.a) == .pass)
        rig.fw.update(.init(profileID: rig.pid, policy: policy, interceptDisabled: true))
        #expect(rig.fw.handle(ack, from: rig.a) == .pass)
        let seen = isns.withLockedValue { $0 }
        #expect(seen.count == 2 && seen[0] != nil && seen[1] == seen[0], "\(seen)")
    }

    @Test func aDetachedPortIsNoLongerGoverned() throws {
        let rig = FirewallRig()
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        rig.fw.portClosed(rig.a)
        #expect(rig.fw.governance(of: rig.a) == nil)
        #expect(rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) == .pass)
    }

    @Test func reportsAreDedupedPerDestinationAndDecision() throws {
        let rig = FirewallRig()
        try rig.govern("deny tcp 203.0.113.7\ndefault allow")
        for _ in 0..<5 { _ = rig.fw.handle(TestFrames.tcp(to: evil, port: 443, flags: 0x02), from: rig.a) }
        #expect(rig.events.withLockedValue { $0.count } == 1)
        #expect(rig.injected.withLockedValue { $0.count } == 5, "every SYN is refused")
    }
}
