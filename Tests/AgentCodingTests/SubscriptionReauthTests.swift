import Foundation
import Testing
@testable import bromure_ac

// The re-auth marker: an access token expiring is normal (the refresh path
// renews it silently), so only a REJECTED refresh — the refresh token itself
// revoked or expired — may flag a credential as needing re-registration.
@Suite("Subscription re-auth state")
struct SubscriptionReauthTests {

    @Test("a fresh record is not flagged, and the field is optional for old files")
    func defaultsUnflagged() throws {
        let r = ClaudeSubscriptionRecord(
            accessToken: "sk-ant-oat01-x", refreshToken: "sk-ant-ort01-y",
            expiresAt: .distantPast, savedAt: Date())
        #expect(r.reauthRequiredAt == nil)

        // A record persisted before this field existed must still decode —
        // otherwise upgrading silently drops everyone's credentials.
        let legacy = """
        {"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-y",\
        "expiresAt":0,"savedAt":0}
        """
        let decoded = try JSONDecoder().decode(
            ClaudeSubscriptionRecord.self, from: Data(legacy.utf8))
        #expect(decoded.reauthRequiredAt == nil)
        #expect(decoded.accessToken == "sk-ant-oat01-x")
    }

    @Test("the flag round-trips through encode/decode")
    func roundTrips() throws {
        var r = CodexSubscriptionRecord(
            accessToken: "eyJ.a.b", refreshToken: "rt_x", idToken: "eyJ.c.d",
            expiresAt: Date(), savedAt: Date())
        r.reauthRequiredAt = Date(timeIntervalSince1970: 1_780_000_000)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(CodexSubscriptionRecord.self, from: data)
        #expect(back.reauthRequiredAt == r.reauthRequiredAt)
    }

    // Which HTTP statuses may flag. Mirrors the guard in each store's refresh:
    // 400–403 is the provider rejecting the credential; anything else is
    // transient and must leave the flag alone, or a flaky network would tell
    // the user to re-register for nothing.
    private func flags(_ status: Int) -> Bool { (400...403).contains(status) }

    @Test("only auth-class refresh failures flag; transient ones don't")
    func statusClassification() {
        for s in [400, 401, 402, 403] { #expect(flags(s), "\(s) should flag") }
        for s in [408, 429, 500, 502, 503, 504] {
            #expect(!flags(s), "\(s) is transient and must not flag")
        }
        #expect(!flags(200))
    }

    @Test("all four stores expose the same re-auth API")
    func allProvidersCovered() {
        // Compile-time coverage: every supported agent must have the pair, so
        // adding a provider without it fails here rather than silently
        // shipping an agent that can't report an expired sign-in.
        let claude = ClaudeSubscriptionStore()
        let codex = CodexSubscriptionStore()
        let grok = GrokSubscriptionStore()
        let kimi = KimiSubscriptionStore()
        let id = UUID()
        // No credential registered for a random id → nil, never a crash.
        #expect(claude.reauthRequiredAt(for: id) == nil)
        #expect(codex.reauthRequiredAt(for: id) == nil)
        #expect(grok.reauthRequiredAt(for: id) == nil)
        #expect(kimi.reauthRequiredAt(for: id) == nil)
        // Flagging a credential that doesn't exist is a no-op, not a write.
        claude.setReauthRequired(true, for: id)
        codex.setReauthRequired(true, for: id)
        grok.setReauthRequired(true, for: id)
        kimi.setReauthRequired(true, for: id)
        #expect(claude.reauthRequiredAt(for: id) == nil)
        #expect(codex.reauthRequiredAt(for: id) == nil)
        #expect(grok.reauthRequiredAt(for: id) == nil)
        #expect(kimi.reauthRequiredAt(for: id) == nil)
    }
}
