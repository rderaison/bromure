import Foundation
import Testing
@testable import bromure_ac

// Claude with its account features: the machine holds an OAuth stand-in
// (never the real login), the proxy recognises it for its own workspace.

@Suite("Claude OAuth stand-in", .serialized)
struct ClaudeStandInTests {

    @Test("stable per workspace, shaped like Claude's tokens, marked")
    func mint() {
        let a = UUID(), b = UUID()
        let t = ClaudeStandIn.mint(profileID: a)
        #expect(t == ClaudeStandIn.mint(profileID: a))
        #expect(t != ClaudeStandIn.mint(profileID: b))
        #expect(t.access.hasPrefix("sk-ant-oat01-") && ClaudeStandIn.isAccess(t.access))
        #expect(t.refresh.hasPrefix("sk-ant-ort01-") && ClaudeStandIn.isRefresh(t.refresh))
        #expect(!ClaudeStandIn.isAccess("sk-ant-oat01-realrealrealreal"))
    }

    @Test("the credentials file Claude Code reads, marked as the host's")
    func credentialsFile() throws {
        let t = ClaudeStandIn.mint(profileID: UUID())
        let obj = try #require(try JSONSerialization.jsonObject(with: ClaudeStandIn.credentialsJSON(t)) as? [String: Any])
        #expect(obj["_bromureManaged"] as? Bool == true)
        let oauth = try #require(obj["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == t.access)
        #expect(oauth["refreshToken"] as? String == t.refresh)
        let expiresAt = try #require(oauth["expiresAt"] as? Int64)
        #expect(Double(expiresAt) / 1000 > Date().addingTimeInterval(365 * 24 * 3600).timeIntervalSince1970)
        #expect((oauth["scopes"] as? [String])?.contains("user:inference") == true)
        let answer = ClaudeStandIn.refreshAnswer(t)
        #expect(answer["access_token"] as? String == t.access)
        #expect(answer["refresh_token"] as? String == t.refresh)
    }

    @Test("the proxy takes it for its own workspace's login only, on Claude's hosts")
    func recognised() throws {
        let store = ClaudeSubscriptionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString).enc"))
        let withLogin = UUID(), without = UUID()
        try store.setOverride(ClaudeSubscriptionRecord(accessToken: "sk-ant-oat01-real", refreshToken: "sk-ant-ort01-real",
                                                       expiresAt: Date().addingTimeInterval(3600), savedAt: Date()),
                              for: withLogin)
        let refresher = ClaudeSubscriptionRefresher(store: store)
        let saved = HTTPMitmConnection.claudeSubscriptionProvider
        HTTPMitmConnection.claudeSubscriptionProvider = { (store, refresher) }
        defer { HTTPMitmConnection.claudeSubscriptionProvider = saved }

        let standIn = ClaudeStandIn.mint(profileID: withLogin).access
        #expect(HTTPMitmConnection.isClaudeStandIn(standIn, profileID: withLogin))
        #expect(!HTTPMitmConnection.isClaudeStandIn(standIn, profileID: without))
        #expect(!HTTPMitmConnection.isClaudeStandIn("sk-ant-oat01-real", profileID: withLogin))
        for h in ["api.anthropic.com", "claude.ai", "platform.claude.com", "console.anthropic.com"] {
            #expect(HTTPMitmConnection.isClaudeHost(h))
        }
        #expect(!HTTPMitmConnection.isClaudeHost("example.com"))
        #expect(!HTTPMitmConnection.isClaudeHost("notclaude.ai"))
    }
}
