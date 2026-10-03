import Foundation
import Testing
@testable import bromure_ac
import SandboxEngine

@Suite("Container traffic exempt from the MiTM", .serialized)
struct ContainerTrafficTests {
    /// A minimal IPv4 header with a correct checksum.
    static func header(tos: UInt8) -> [UInt8] {
        var h: [UInt8] = [0x45, tos, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0, 0,
                          0xac, 0x1b, 0x66, 0x02, 0x01, 0x01, 0x01, 0x01]
        let c = checksum(h); h[10] = UInt8(c >> 8); h[11] = UInt8(c & 0xff)
        return h
    }
    static func checksum(_ h: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: h.count, by: 2) where i != 10 { sum += UInt32(h[i]) << 8 | UInt32(h[i + 1]) }
        while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    @Test("The mark is read, stripped (ECN kept) and the checksum stays valid; other DSCPs are untouched")
    func strip() {
        for ecn: UInt8 in [0, 1, 2, 3] {
            var h = Self.header(tos: VMNetSwitch.containerDSCP << 2 | ecn)
            let took = h.withUnsafeMutableBufferPointer { VMNetSwitch.takeContainerMark($0.baseAddress!, ip: 0) }
            #expect(took)
            #expect(h[1] == ecn)
            #expect(UInt16(h[10]) << 8 | UInt16(h[11]) == Self.checksum(h))
        }
        var voip = Self.header(tos: 46 << 2)          // EF, a legitimate DSCP
        let took = voip.withUnsafeMutableBufferPointer { VMNetSwitch.takeContainerMark($0.baseAddress!, ip: 0) }
        #expect(!took && voip[1] == 46 << 2)
    }

    @Test("The switch honours the mark only while the sentry stamps it and the workspace allows it")
    func gating() {
        let pid = UUID()
        let svc = KernelSentryService.shared
        let old = svc.containerDirectProvider
        defer { svc.containerDirectProvider = old; svc.noteContainerMark(profileID: pid, active: false) }
        svc.containerDirectProvider = { $0 == pid }
        #expect(!VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))   // no sentry yet
        svc.noteContainerMark(profileID: pid, active: true)
        #expect(VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
        svc.noteContainerMark(profileID: pid, active: false)                    // sentry gone → fail closed
        #expect(!VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
        svc.noteContainerMark(profileID: pid, active: true)
        svc.containerDirectProvider = { _ in false }                            // option turned off
        svc.refreshContainerDirect(profileID: pid)
        #expect(!VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
    }

    @Test("A tc change after boot revokes the exemption until the next boot; reconnects don't re-arm it")
    func tcRevokes() {
        let pid = UUID()
        let svc = KernelSentryService.shared
        let old = svc.containerDirectProvider
        defer { svc.containerDirectProvider = old; svc.rearmContainerMark(profileID: pid)
                svc.noteContainerMark(profileID: pid, active: false) }
        svc.containerDirectProvider = { $0 == pid }
        svc.noteContainerMark(profileID: pid, active: true)
        #expect(VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
        #expect(svc.revokeContainerMark(profileID: pid))            // first revocation alarms
        #expect(!svc.revokeContainerMark(profileID: pid))           // later ones don't re-alarm
        #expect(!VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
        svc.noteContainerMark(profileID: pid, active: true)         // a reconnect in the same boot
        #expect(!VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
        svc.rearmContainerMark(profileID: pid)                      // a new boot's hello
        svc.noteContainerMark(profileID: pid, active: true)
        #expect(VMNetSwitch.shared.isContainerTrafficDirect(profileID: pid))
    }

    @Test("Not applied without the sentry, or under a policy with request-level rules")
    func effective() {
        var p = bromure_ac.Profile(name: "c", tool: .claude, authMode: .token)
        p.containerTrafficDirect = true
        #expect(!p.effectiveContainerTrafficDirect)                             // sentry off
        p.kernelSentry = .bestEffort
        #expect(p.effectiveContainerTrafficDirect)
        p.networkPolicy = """
        version: 1
        network_policies:
          gh:
            endpoints:
              - host: api.github.com
                port: 443
                protocol: rest
                rules:
                  - allow: { method: GET, path: "/**" }
            binaries: [{ path: /usr/bin/curl }]
        """
        #expect(!p.resolvedEgressPolicy.inspectedPorts.isEmpty)
        #expect(!p.effectiveContainerTrafficDirect)
    }
}
