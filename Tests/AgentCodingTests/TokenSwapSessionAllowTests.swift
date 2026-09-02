import Foundation
import Testing
@testable import bromure_ac

/// The compromise alert's "Allow" button authorizes the observed host as an
/// extra swap destination for the session (`TokenSwapper.allowSessionHosts`).
/// Once allowed, the fake is no longer flagged as exfiltration AND the swap
/// fires there so the real credential reaches the user-approved host. It's
/// session-scoped: `clearMap` (VM teardown) drops it.
@Suite("Token swap — session Allow list")
struct TokenSwapSessionAllowTests {

    private func request(host: String, token: String) -> Data {
        let s = "POST /v1/chat HTTP/1.1\r\n" +
                "host: \(host)\r\n" +
                "authorization: Bearer \(token)\r\n" +
                "content-length: 0\r\n\r\n"
        return Data(s.utf8)
    }

    private func makeSwapper(_ pid: UUID) -> TokenSwapper {
        let swapper = TokenSwapper(consent: ConsentBroker())
        // Fake minted for openai.com; sending it anywhere else is a leak.
        swapper.setMap(TokenMap(entries: [
            .init(fake: "FAKEOAI0000", real: "REALOAI9999", host: "openai.com",
                  consentCredentialID: nil)
        ]), for: pid)
        return swapper
    }

    @Test("Leak fires on a non-allowed host, is suppressed after Allow")
    func allowSuppressesCompromise() {
        let pid = UUID()
        let swapper = makeSwapper(pid)
        let req = request(host: "z.ai", token: "FAKEOAI0000")

        // Before Allow: the openai fake heading to z.ai is flagged.
        let before = swapper.detectCompromise(rawRequest: req, host: "z.ai", profileID: pid)
        #expect(before.count == 1)
        #expect(before.first?.observedHost == "z.ai")

        // After Allow: no longer flagged for z.ai (or its subdomains)…
        swapper.allowSessionHosts(["z.ai"], for: pid)
        #expect(swapper.detectCompromise(rawRequest: req, host: "z.ai", profileID: pid).isEmpty)
        let subReq = request(host: "api.z.ai", token: "FAKEOAI0000")
        #expect(swapper.detectCompromise(rawRequest: subReq, host: "api.z.ai", profileID: pid).isEmpty)

        // …but an unrelated host is still flagged.
        let evil = request(host: "evil.example", token: "FAKEOAI0000")
        #expect(swapper.detectCompromise(rawRequest: evil, host: "evil.example", profileID: pid).count == 1)
    }

    @Test("Swap fires for the allowed host (real credential reaches it)")
    func allowLetsSwapFire() async {
        let pid = UUID()
        let swapper = makeSwapper(pid)
        let req = request(host: "z.ai", token: "FAKEOAI0000")

        // Before Allow: scoped to openai.com, so z.ai keeps the fake (real never leaks).
        let pre = await swapper.swap(rawRequest: req, host: "z.ai", profileID: pid)
        #expect(String(decoding: pre.modified, as: UTF8.self).contains("FAKEOAI0000"))
        #expect(pre.swaps.isEmpty)

        // After Allow: the fake is swapped to the real credential on z.ai.
        swapper.allowSessionHosts(["z.ai"], for: pid)
        let post = await swapper.swap(rawRequest: req, host: "z.ai", profileID: pid)
        let out = String(decoding: post.modified, as: UTF8.self)
        #expect(out.contains("REALOAI9999"))
        #expect(!out.contains("FAKEOAI0000"))
        #expect(post.swaps.count == 1)
    }

    @Test("Allow list is session-scoped — clearMap drops it")
    func clearMapResetsAllowList() {
        let pid = UUID()
        let swapper = makeSwapper(pid)
        swapper.allowSessionHosts(["z.ai"], for: pid)
        let req = request(host: "z.ai", token: "FAKEOAI0000")
        #expect(swapper.detectCompromise(rawRequest: req, host: "z.ai", profileID: pid).isEmpty)

        // Teardown clears the map AND the allow list; a fresh session re-flags z.ai.
        swapper.clearMap(for: pid)
        swapper.setMap(TokenMap(entries: [
            .init(fake: "FAKEOAI0000", real: "REALOAI9999", host: "openai.com",
                  consentCredentialID: nil)
        ]), for: pid)
        #expect(swapper.detectCompromise(rawRequest: req, host: "z.ai", profileID: pid).count == 1)
    }
}
