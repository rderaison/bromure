import Foundation
import Testing
@testable import bromure_ac

// Codex's stand-in credentials: recognised by their marks (not only by an
// in-memory registry a restart empties), and a stand-in refresh gets fresh
// stand-ins rather than OpenAI's "log out and sign in again".

@Suite("Codex stand-ins", .serialized)
struct CodexStandInTests {

    private static func jwt(_ claims: [String: Any]) -> String {
        func seg(_ o: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return seg(["alg": "RS256", "typ": "JWT"]) + "." + seg(claims) + ".c2lnbmF0dXJlLXJlYWw"
    }

    private static func record() -> CodexSubscriptionRecord {
        CodexSubscriptionRecord(
            accessToken: jwt(["exp": 2_000_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct"]]),
            refreshToken: "rt_real_refresh_token_value",
            idToken: jwt(["exp": 2_000_000_000, "email": "you@example.com"]),
            expiresAt: Date().addingTimeInterval(3600), savedAt: Date())
    }

    @Test("minted stand-ins carry Bromure's marks; the refresh answer is well formed")
    func mint() throws {
        let t = try #require(CodexStandIn.mint(Self.record(), profileID: UUID()))
        #expect(SubscriptionFakeMint.isJWTFake(t.access))
        #expect(SubscriptionFakeMint.isJWTFake(t.id))
        #expect(SubscriptionFakeMint.isCodexRefreshFake(t.refresh))
        #expect(!SubscriptionFakeMint.isJWTFake(Self.record().accessToken))
        let answer = CodexStandIn.refreshAnswer(t)
        #expect(answer["access_token"] as? String == t.access)
        #expect(answer["refresh_token"] as? String == t.refresh)
        #expect(answer["id_token"] as? String == t.id)
    }

    @Test("a stand-in is recognised after a restart emptied the registry — for its own workspace only")
    func recognisedWithoutRegistry() throws {
        let store = CodexSubscriptionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString).enc"))
        let withLogin = UUID(), without = UUID()
        try store.setOverride(Self.record(), for: withLogin)
        let refresher = CodexSubscriptionRefresher(store: store)
        let saved = HTTPMitmConnection.codexSubscriptionProvider
        HTTPMitmConnection.codexSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.codexSubscriptionProvider = saved }

        // Minted before a "restart": never registered in this store.
        let old = try #require(CodexStandIn.mint(Self.record(), profileID: withLogin)).access
        #expect(store.profileForBogusKey(old) == nil)
        #expect(HTTPMitmConnection.isCodexStandIn(old, profileID: withLogin))
        // No login in that workspace: nothing to swap it for.
        #expect(!HTTPMitmConnection.isCodexStandIn(old, profileID: without))
        // A real (unmarked) token is never taken for a stand-in.
        #expect(!HTTPMitmConnection.isCodexStandIn(Self.record().accessToken, profileID: withLogin))
    }
}
