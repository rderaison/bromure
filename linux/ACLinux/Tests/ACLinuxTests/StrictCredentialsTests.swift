import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// Strict credential mode on the Linux proxy (macOS: HTTPProxy's
/// UnmanagedCredentialGuard step): a credential Bromure didn't issue never
/// leaves the VM; Bromure's stand-ins, tokens the site issued the guest and
/// session approvals do.
@Suite("Strict credentials", .serialized)
struct StrictCredentialsTests {
    static let real = "ghp_" + String(repeating: "A1b2C3d4E5", count: 4).prefix(36)

    static func strict(_ rig: ProxyEgressPolicyTests.Rig, _ on: Bool) {
        var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
        cfg.strictCredentials = on
        rig.proxy.setGuardrailsConfig(cfg, for: rig.pid)
    }

    @Test func aCredentialBromureDidntIssueIsRefusedAndRaised() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { up.stop() }
        let raised = NIOLockedValueBox<[CompromiseEvent]>([])
        rig.proxy.swapper.setCompromiseHandler { e in raised.withLockedValue { $0.append(e) } }
        let h = "\(ip):\(up.port)"
        let req = "GET http://\(h)/x HTTP/1.1\r\nHost: \(h)\r\nAuthorization: Bearer \(Self.real)\r\n\r\n"
        // Off: through.
        Self.strict(rig, false)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 200"))
        let n0 = up.received.withLockedValue { $0.count }
        // On: refused, nothing upstream, raised with its fingerprint.
        Self.strict(rig, true)
        let out = try PipelineTests.talk(rig.path(), req)
        #expect(out.hasPrefix("HTTP/1.1 451") && out.contains("strict credential mode") && !out.contains(Self.real), "\(out.prefix(160))")
        #expect(up.received.withLockedValue { $0.count } == n0, "nothing went upstream")
        let fps = raised.withLockedValue { $0 }.last?.unmanagedFingerprints ?? []
        #expect(!fps.isEmpty, "raised as a compromise, with the credential's fingerprint")
        // Approved for the session: through.
        UnmanagedCredentialGuard.shared.allowForSession(fps, profileID: rig.pid)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 200"))
        // The workspace's policies cleared (its VM stopped): off, approvals forgotten.
        rig.proxy.clearGuardrailsConfig(for: rig.pid)
        Self.strict(rig, true)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 451"), "the approval ended with the session")
        rig.proxy.clearGuardrailsConfig(for: rig.pid)
    }

    @Test func aStandInAndATokenTheSiteIssuedGoThrough() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        Self.strict(rig, true)
        // The site issues the guest a token (a login inside the VM).
        let body = #"{"access_token":"\#(Self.real)"}"#
        let login = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        defer { login.stop() }
        let h = "\(ip):\(login.port)"
        _ = try PipelineTests.talk(rig.path(), "POST http://\(h)/login HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n")
        let api = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { api.stop() }
        let h2 = "\(ip):\(api.port)"
        #expect(try PipelineTests.talk(rig.path(), "GET http://\(h2)/me HTTP/1.1\r\nHost: \(h2)\r\nAuthorization: Bearer \(Self.real)\r\n\r\n")
                    .hasPrefix("HTTP/1.1 200"), "a token this site issued the guest goes back to it")
        // A Bromure stand-in (in the swap map): through.
        let fake = "ghp_" + String(repeating: "Zz9Yy8Xx7W", count: 4).prefix(36)
        rig.proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: String(fake), real: "unused", host: ip)]), for: rig.pid)
        #expect(try PipelineTests.talk(rig.path(), "GET http://\(h2)/s HTTP/1.1\r\nHost: \(h2)\r\nAuthorization: Bearer \(fake)\r\n\r\n")
                    .hasPrefix("HTTP/1.1 200"), "a stand-in isn't unmanaged")
        rig.proxy.swapper.clearMap(for: rig.pid)
    }
}
