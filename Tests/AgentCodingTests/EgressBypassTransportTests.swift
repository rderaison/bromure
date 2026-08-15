import Foundation
import Testing
@testable import SandboxEngine

/// H3: on an inspected VM, the transports that would skip the IPv4/TCP MiTM +
/// firewall are dropped — QUIC (UDP :443) and any IP fragment.
@Suite("Egress bypass-transport classifier (H3)")
struct EgressBypassTransportTests {

    @Test("QUIC (UDP :443) is a bypass; other UDP is not")
    func quic() {
        #expect(VMNetSwitch.isEgressBypassTransport(fragmented: false, ipProto: 17, dport: 443))
        // DNS, NTP, WireGuard, IKE, a random high UDP port — all fine.
        for p: UInt16 in [53, 123, 500, 4500, 51820, 8443, 80] {
            #expect(!VMNetSwitch.isEgressBypassTransport(fragmented: false, ipProto: 17, dport: p),
                    "UDP :\(p) should not be a bypass")
        }
    }

    @Test("TCP is never classified as a bypass (it's what the MiTM inspects)")
    func tcp() {
        for p: UInt16 in [80, 443, 8443, 22, 3000] {
            #expect(!VMNetSwitch.isEgressBypassTransport(fragmented: false, ipProto: 6, dport: p))
        }
    }

    @Test("Any fragment is a bypass, regardless of protocol/port")
    func fragments() {
        #expect(VMNetSwitch.isEgressBypassTransport(fragmented: true, ipProto: 6, dport: 443))
        #expect(VMNetSwitch.isEgressBypassTransport(fragmented: true, ipProto: 17, dport: 53))
        #expect(VMNetSwitch.isEgressBypassTransport(fragmented: true, ipProto: 1, dport: 0))
    }

    @Test("Non-TCP/UDP, non-fragmented protocols are out of scope (not dropped here)")
    func otherProtos() {
        for proto: UInt8 in [1 /*ICMP*/, 47 /*GRE*/, 132 /*SCTP*/, 41 /*6in4*/, 50 /*ESP*/] {
            #expect(!VMNetSwitch.isEgressBypassTransport(fragmented: false, ipProto: proto, dport: 0))
        }
    }
}
