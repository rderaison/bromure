import Foundation
import Glibc
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux
import SandboxEngine

/// Binary identity on intercepted flows (macOS: MitmEngine.acceptTransparentFlow's
/// identity step): under a strict policy's `binaries`, a transparent flow is
/// decided for the program the guest's attestor names for its source port.
/// The allowed program gets through; another, or none (no attestor answer),
/// is refused (closed), with the program on the deny event.
@Suite("Transparent flows: binary identity", .serialized)
struct TransparentIdentityTests {
    final class Asked: @unchecked Sendable {
        let calls = NIOLockedValueBox<[(UInt16, String, UInt16)]>([])
    }

    static func rig(answer exe: String?) throws -> (TransparentInterceptionTests.Rig, Asked) {
        let rig = try TransparentInterceptionTests.Rig()
        let yaml = """
        version: 1
        network_policies:
          web:
            endpoints: [{ host: "\(rig.ip)", port: 80, allowed_ips: ["\(rig.ip)/32"] }]
            binaries: [{ path: /usr/bin/curl }]
        """
        var policy = EgressPolicy(openShell: try OpenShellPolicy.parse(yaml))
        policy.enforceBinaries = true
        rig.proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [], egressPolicy: policy), for: rig.pid)
        let asked = Asked()
        rig.proxy.identityLookup = { _, sport, dst, dport in
            asked.calls.withLockedValue { $0.append((sport, dst, dport)) }
            return exe.map { .init(exe: $0, sha256: "h-" + $0, ancestors: []) }
        }
        return (rig, asked)
    }

    func flow(_ rig: TransparentInterceptionTests.Rig, srcPort: Int) throws -> String {
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        GuestEnd.send(guest, "GET /x HTTP/1.1\r\nHost: \(rig.ip)\r\n\r\n")
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: rig.ip, destPort: 80, srcPort: srcPort)
        return GuestEnd.readAll(guest) ?? "TIMEOUT"
    }

    @Test func theAllowedProgramGetsThrough() throws {
        let (rig, asked) = try Self.rig(answer: "/usr/bin/curl"); defer { rig.stop() }
        let out = try flow(rig, srcPort: 40123)
        #expect(out.hasSuffix("upstream ok"), "\(out)")
        #expect(rig.upstream.requests.withLockedValue { $0 }.count == 1)
        let c = asked.calls.withLockedValue { $0 }
        #expect(c.count == 1 && c[0].0 == 40123 && c[0].1 == rig.ip && c[0].2 == 80, "asked by the flow's source port")
    }

    @Test(arguments: ["/usr/bin/python3", nil] as [String?])
    func anotherProgramOrNoneIsRefused(exe: String?) async throws {
        let (rig, _) = try Self.rig(answer: exe); defer { rig.stop() }
        let out = try flow(rig, srcPort: 40124)
        #expect(out == "", "closed, never answered: \(out)")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
        guard let exe else { return }
        let pid = rig.pid
        var seen = false
        for _ in 0..<100 where !seen {
            seen = await MainActor.run {
                SecurityTimeline.shared.allEvents.contains { $0.profileID == pid && "\($0)".contains(exe) }
            }
            if !seen { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(seen, "the deny names the program")
    }

    /// No `binaries` enforcement: the attestor isn't asked.
    @Test func noEnforcementNoLookup() throws {
        let (rig, asked) = try Self.rig(answer: "/usr/bin/curl"); defer { rig.stop() }
        try rig.policy("default allow")
        let out = try flow(rig, srcPort: 40125)
        #expect(out.hasSuffix("upstream ok"), "\(out)")
        #expect(asked.calls.withLockedValue { $0 }.isEmpty)
    }
}
