import Foundation
import Testing
@testable import bromure_ac

/// A captured sign-in's token reply the host doesn't keep (its sign-in ended
/// as the exchange landed, the store write failed, a reply it couldn't read)
/// carried the real credential on to the guest: `reply ?? upstream`. Seen on
/// the Linux server's proxy, whose relay didn't decode a compressed reply;
/// the macOS path had the same fall-through.
@Suite("A sign-in's token reply the host didn't keep never reaches the guest")
struct SignInCaptureFailClosedTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("an unkept 200 is refused; only a non-200 passes through")
    func unkeptTokenReplyRefused() throws {
        let p = try Self.src("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        let start = try #require(p.range(of: "var reply = await capture.handle(status, body)"))
        let block = p[start.upperBound...].prefix(1200)
        let guardRange = try #require(block.range(of: "if reply == nil, status == 200 {"))
        let write = try #require(block.range(of: "try tls.write(reply ?? upstream)"))
        #expect(guardRange.lowerBound < write.lowerBound)
        #expect(block.contains("reply = SignInCapture.notKeptReply"))
    }

    @Test("an ended sign-in leaves a spent marker: its late exchange is refused before the provider, then it expires")
    func spentMarker() throws {
        let pid = UUID(), t0 = Date()
        let reg = SignInCaptureRegistry()
        reg.arm(.spentMarker(profileID: pid, hosts: ["platform.claude.com"], pathPrefix: "/v1/oauth/token", now: t0))
        let c = try #require(reg.capture(for: pid, now: t0.addingTimeInterval(60)))
        #expect(c.spent)
        #expect(c.matches(host: "platform.claude.com", method: "POST", path: "/v1/oauth/token",
                          body: Data(#"{"grant_type":"authorization_code","code":"x"}"#.utf8)))
        #expect(reg.capture(for: pid, now: t0.addingTimeInterval(SignInCapture.spentFor + 1)) == nil)
        // The proxy turns a spent capture away before any upstream request.
        let p = try Self.src("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        let spent = try #require(p.range(of: "capture.refusesExchange(host: host, method: reqMethod, path: reqPath,"))
        let relay = try #require(p.range(of: "upstream = try await relayUpstreamCollecting("))
        #expect(spent.lowerBound < relay.lowerBound)
        // And every end leaves one.
        let ss = try Self.src("Sources/AgentCoding/SessionSignIn.swift")
        let end = try #require(ss.range(of: "func endProxySignIn(_ s: ProxySignIn, success: Bool, message: String?) {"))
        #expect(ss[end.upperBound...].prefix(1400).contains("signInCaptures.arm(.spentMarker("))
    }

    @Test("another agent's sign-in doesn't lift a spent marker; a retry of the same one does")
    func spentSurvivesOtherSignIns() throws {
        let pid = UUID(), t0 = Date()
        let reg = SignInCaptureRegistry()
        let claudeBody = Data(#"{"grant_type":"authorization_code","code":"late"}"#.utf8)
        reg.arm(.spentMarker(profileID: pid, hosts: ["platform.claude.com"], pathPrefix: "/v1/oauth/token", now: t0))
        // A Codex sign-in arms its live capture in the same workspace.
        reg.arm(SignInCapture(profileID: pid, hosts: ["auth.openai.com"], pathPrefix: "/oauth/token",
                              handle: { _, _ in nil }))
        let c = try #require(reg.capture(for: pid, now: t0.addingTimeInterval(60)))
        #expect(!c.spent)
        #expect(c.refusesExchange(host: "platform.claude.com", method: "POST", path: "/v1/oauth/token", body: claudeBody))
        #expect(!c.refusesExchange(host: "auth.openai.com", method: "POST", path: "/oauth/token", body: Data("grant_type=authorization_code".utf8)))
        // A new Claude sign-in (the retry) lifts the Claude marker.
        reg.arm(SignInCapture(profileID: pid, hosts: ["platform.claude.com"], pathPrefix: "/v1/oauth/token",
                              handle: { _, _ in nil }))
        let retry = try #require(reg.capture(for: pid, now: t0.addingTimeInterval(61)))
        #expect(!retry.refusesExchange(host: "platform.claude.com", method: "POST", path: "/v1/oauth/token", body: claudeBody))
        // Disarming the live one leaves no capture (no marker left).
        reg.disarm(profileID: pid)
        #expect(reg.capture(for: pid, now: t0.addingTimeInterval(62)) == nil)
    }
}
