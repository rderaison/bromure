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
        #expect(c.count == 2 && c.allSatisfy { $0.0 == 40123 && $0.1 == rig.ip && $0.2 == 80 },
                "asked by the flow's source port, on arrival and once it wrote")
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

    /// The attestor is asked as the flow arrives, before the guest has
    /// written anything (macOS's order), and again once it has: a socket
    /// that changed hands in between (a refused program connects, an allowed
    /// one it passed the descriptor to writes) is refused.
    @Test func theProgramIsAskedBeforeAnyDataAndMustNotChangeHands() throws {
        let rig = try TransparentInterceptionTests.Rig(); defer { rig.stop() }
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
        // The connecting program, then the one that writes.
        rig.proxy.identityLookup = { _, sport, dst, dport in
            let n = asked.calls.withLockedValue { $0.append((sport, dst, dport)); return $0.count }
            let exe = n == 1 ? "/usr/bin/python3" : "/usr/bin/curl"
            return .init(exe: exe, sha256: "h-" + exe, ancestors: [])
        }
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: rig.ip, destPort: 80, srcPort: 40200)
        var first = 0
        for _ in 0..<200 where first == 0 {
            first = asked.calls.withLockedValue { $0.count }
            if first == 0 { usleep(10_000) }
        }
        #expect(first == 1, "asked before the guest wrote anything")
        GuestEnd.send(guest, "GET /x HTTP/1.1\r\nHost: \(rig.ip)\r\n\r\n")
        #expect(GuestEnd.readAll(guest) == "", "refused: another program wrote")
        #expect(asked.calls.withLockedValue { $0.count } == 2)
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty)
    }

    /// At most maxIdentityLookups questions in flight per workspace: past
    /// it a flow is refused without asking (a stuck attestor can't pile up
    /// waiting flows).
    @Test func pastTheCapAFlowIsRefusedWithoutAsking() throws {
        let (rig, asked) = try Self.rig(answer: "/usr/bin/curl"); defer { rig.stop() }
        rig.proxy.identityLookupsInFlight.withLockedValue { $0[rig.pid] = MitmProxy.maxIdentityLookups }
        let out = try flow(rig, srcPort: 40201)
        #expect(out == "", "\(out)")
        #expect(asked.calls.withLockedValue { $0 }.isEmpty)
        rig.proxy.identityLookupsInFlight.withLockedValue { $0[rig.pid] = nil }
        #expect(try flow(rig, srcPort: 40202).hasSuffix("upstream ok"), "a slot again: asked and through")
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
