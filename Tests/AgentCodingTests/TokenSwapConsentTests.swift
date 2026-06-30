import Foundation
import Testing
@testable import bromure_ac

/// Regression coverage for the token-swap consent gating. The key invariant
/// (broken by an over-aggressive security change, restored here): an unscoped
/// (blank host filter) entry that the user did NOT flag for approval is swapped
/// **silently on any host** — it must never be routed through the consent
/// broker, which would block the request mid-flight and break the agent's
/// traffic (this is exactly what took down subscription mode). Consent is
/// consulted only for entries the user opted into (`consentCredentialID` set).
@Suite("Token swap consent gating")
struct TokenSwapConsentTests {

    private func request(host: String, token: String) -> Data {
        let s = "POST /v1/messages HTTP/1.1\r\n" +
                "host: \(host)\r\n" +
                "authorization: Bearer \(token)\r\n" +
                "content-length: 0\r\n\r\n"
        return Data(s.utf8)
    }

    @Test("Unscoped, unflagged entry swaps silently (no consent) on any host")
    func unscopedSwapsSilently() async {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        // host: nil (unscoped), consentCredentialID: nil (not flagged) — the
        // "inject everywhere, don't ask" config used by MCP bearers and
        // env-wide manual tokens. If this routed through consent the call would
        // block on a modal here.
        swapper.setMap(TokenMap(entries: [
            .init(fake: "FAKETOKEN123", real: "REALTOKEN999", host: nil,
                  consentCredentialID: nil)
        ]), for: pid)
        let result = await swapper.swap(
            rawRequest: request(host: "some-host.example.com", token: "FAKETOKEN123"),
            host: "some-host.example.com", profileID: pid)
        let modified = String(decoding: result.modified, as: UTF8.self)
        #expect(modified.contains("REALTOKEN999"))
        #expect(!modified.contains("FAKETOKEN123"))
        #expect(result.swaps.count == 1)
    }

    @Test("Scoped entry is left untouched on a non-matching host")
    func scopedSkipsWrongHost() async {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        swapper.setMap(TokenMap(entries: [
            .init(fake: "FAKEANT", real: "REALANT", host: "api.anthropic.com",
                  consentCredentialID: nil)
        ]), for: pid)
        let result = await swapper.swap(
            rawRequest: request(host: "evil.example.com", token: "FAKEANT"),
            host: "evil.example.com", profileID: pid)
        let modified = String(decoding: result.modified, as: UTF8.self)
        #expect(modified.contains("FAKEANT"))      // real value not leaked
        #expect(!modified.contains("REALANT"))
        #expect(result.swaps.isEmpty)
    }

    @Test("Scoped, unflagged entry swaps on its matching host")
    func scopedSwapsOnHost() async {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        swapper.setMap(TokenMap(entries: [
            .init(fake: "FAKEANT", real: "REALANT", host: "api.anthropic.com",
                  consentCredentialID: nil)
        ]), for: pid)
        let result = await swapper.swap(
            rawRequest: request(host: "api.anthropic.com", token: "FAKEANT"),
            host: "api.anthropic.com", profileID: pid)
        let modified = String(decoding: result.modified, as: UTF8.self)
        #expect(modified.contains("REALANT"))
        #expect(result.swaps.count == 1)
    }
}
