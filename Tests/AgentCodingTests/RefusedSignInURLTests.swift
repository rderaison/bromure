import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-459): "Refused remote sign-in URL leaves registration in
/// flight for about four minutes". The gate refused a local/private sign-in
/// URL and only logged it: the guest's outbox file was already gone, the
/// registration stayed set (a retry read "Another sign-in is already in
/// progress") and the credential poll ran its 240 s before timing out.
@Suite("Refused sign-in URL ends the sign-in")
struct RefusedSignInURLTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("registration: one gate before the fat-client hand-off and the local open, ending the sign-in")
    func registration() throws {
        let r = try Self.src("Sources/AgentCoding/ClaudeRegistrationCoordinator.swift")
        let closure = try #require(r.range(of: "sandbox.onURLOpen = { [weak self, weak sandbox] url in"))
        let body = r[closure.upperBound...]
        let gate = try #require(body.range(of: "guard ACAppDelegate.opensInRealBrowser(url) else {"))
        let remote = try #require(body.range(of: "if RemoteRegistrationBroker.shared.pending != nil {"))
        let open = try #require(body.range(of: "ACAppDelegate.openGuestRelayedURL(url)"))
        #expect(gate.lowerBound < remote.lowerBound && remote.lowerBound < open.lowerBound)
        let refusal = body[gate.upperBound..<remote.lowerBound]
        #expect(refusal.contains("self.failClaudeRegistration(NSLocalizedString("))
        // The port-ownership refusal ends it the same way.
        #expect(body[..<open.lowerBound].contains("self.failClaudeRegistration(refused)"))
        // …which delivers the reason and tears down (relay, poll, scratch VM).
        let fail = try #require(r.range(of: "func failClaudeRegistration(_ message: String) {"))
        let failBody = r[fail.upperBound...].prefix(400)
        #expect(failBody.contains("ev(.finished(success: false, message: message))"))
        #expect(failBody.contains("teardownClaudeRegistration(reason: .failure, message: message)"))
        let teardown = try #require(r.range(of: "func teardownClaudeRegistration(reason: ClaudeRegistrationTeardownReason, message: String? = nil) {"))
        let td = r[teardown.upperBound...].prefix(1200)
        #expect(td.contains("RemoteRegistrationBroker.shared.finish(success: reason == .success, message: message)") && td.contains("state.pollTask?.cancel()"))
    }

    @Test("a workspace sign-in card waiting on a refused page ends instead of timing out")
    func workspaceSignIn() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let card = try #require(ac.range(of: "// A sign-in card is waiting on this very page."))
        let after = ac[card.upperBound...].prefix(1200)
        let gate = try #require(after.range(of: "guard Self.opensInRealBrowser(url) else {"))
        let ended = try #require(after.range(of: "self.endProxySignIn(signIn, success: false, message: NSLocalizedString("))
        let status = try #require(after.range(of: "Finish signing in in your browser…"))
        #expect(gate.lowerBound < ended.lowerBound && ended.lowerBound < status.lowerBound)
    }

    @Test("the refusal is in every locale")
    func localized() throws {
        for loc in ["en", "fr", "de", "es", "pt", "ja", "zh-Hans", "zh-Hant"] {
            let s = try Self.src("Sources/AgentCoding/\(loc).lproj/Localizable.strings")
            #expect(s.contains("\n\"The sign-in page the agent opened points at this Mac or its local network, so Bromure didn't open it.\" = "), "\(loc)")
        }
    }
}
