import Foundation
import Testing
@testable import ACLinux
import SandboxEngine

/// Main's switch fixes on the Linux firewall: an always-blocked address is
/// never handed to the MiTM (the guest's connect() would have succeeded
/// before the MiTM dropped it, where OpenShell refuses it outright), and the
/// report table stays bounded under a flood of fresh destinations.
@Suite("Switch egress: deferral and bounds")
struct EgressBoundsTests {
    static let yaml = """
    version: 1
    network_policies:
      web:
        endpoints:
          - { host: allowed.example, port: 443 }
    """

    @Test func anAlwaysBlockedAddressIsNeverHandedToTheMITM() throws {
        let rig = FirewallRig()
        let mitm = RecordingInterceptor()
        rig.fw.setInterception(.init(interceptor: mitm, ports: [80, 443]))
        rig.fw.govern(rig.a, .init(profileID: rig.pid, policy: EgressPolicy(openShell: try OpenShellPolicy.parse(Self.yaml)),
                                   interceptDisabled: false))
        // An address the snooped DNS doesn't name: the MiTM decides by the SNI.
        #expect(rig.fw.handle(TestFrames.tcp(to: TestFrames.ip("198.51.100.9"), port: 443, flags: 0x02), from: rig.a) == .consumed)
        #expect(mitm.diverted.withLockedValue { $0.count } == 1)
        // The metadata address: refused here, with an RST, never diverted.
        let rstBefore = rig.injected.withLockedValue { $0.count }
        #expect(rig.fw.handle(TestFrames.tcp(to: TestFrames.ip("169.254.169.254"), port: 443, flags: 0x02), from: rig.a) == .consumed)
        #expect(mitm.diverted.withLockedValue { $0.count } == 1, "not handed over")
        #expect(rig.injected.withLockedValue { $0.count } == rstBefore + 1, "answered with an RST")
    }

    @Test func theReportTableStaysBounded() throws {
        let rig = FirewallRig()
        try rig.govern("default deny")
        for i in 0..<40_000 {
            let dst = TestFrames.ip("10.0.0.0") &+ UInt32(i)
            _ = rig.fw.handle(TestFrames.tcp(to: dst, port: 443, flags: 0x02), from: rig.a)
        }
        #expect(rig.fw.egressSeenCount <= SwitchEgressFirewall.egressSeenCap, "\(rig.fw.egressSeenCount)")
    }
}
