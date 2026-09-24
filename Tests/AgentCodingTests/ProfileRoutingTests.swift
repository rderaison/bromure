import Foundation
import Testing
@testable import bromure_ac

/// Profile-level routing computed properties (distinct from LLMRouting.decide,
/// covered in InferenceRoutingTests). `effectiveModelRouting` downgrades a
/// pointless pure-`.local` route to `.cloud`; `localProviderCloudHosts` tells
/// the proxy which provider hosts belong to a genuinely-local agent so a mixed
/// profile stays per-agent.
@Suite("Profile.effectiveModelRouting")
struct ProfileEffectiveRoutingTests {

    @Test("`.local` with NO local-auth tool downgrades to `.cloud`")
    func localNoToolDowngrades() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.modelRouting = .local
        // Subscription Claude with a model selected but no `.local` agent.
        #expect(p.effectiveModelRouting == .cloud)
    }

    @Test("`.local` with a local primary stays `.local`")
    func localPrimaryStays() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.modelRouting = .local
        #expect(p.effectiveModelRouting == .local)
    }

    @Test("`.local` with a local *additional* tool stays `.local`")
    func localAdditionalStays() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.modelRouting = .local
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m")]
        #expect(p.effectiveModelRouting == .local)
    }

    @Test("`.cloud` stays `.cloud`")
    func cloudStays() {
        let p = Profile(name: "t", tool: .claude, authMode: .token)
        #expect(p.effectiveModelRouting == .cloud)
    }
}

@Suite("Profile.localProviderCloudHosts")
struct ProfileLocalHostsTests {

    @Test("Local codex maps to openai.com + chatgpt.com (no anthropic)")
    func codexLocal() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m")]
        let hosts = p.localProviderCloudHosts
        #expect(hosts == ["openai.com", "chatgpt.com"])
        #expect(!hosts.contains("anthropic.com"))
    }

    @Test("Local claude maps to anthropic.com")
    func claudeLocal() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "m"
        #expect(p.localProviderCloudHosts == ["anthropic.com"])
    }

    @Test("Subscription claude contributes NO host (not local auth)")
    func subscriptionClaudeNoHost() {
        let p = Profile(name: "t", tool: .claude, authMode: .subscription)
        #expect(p.localProviderCloudHosts.isEmpty)
        #expect(!p.localProviderCloudHosts.contains("anthropic.com"))
    }

    @Test("Token claude contributes NO host")
    func tokenClaudeNoHost() {
        let p = Profile(name: "t", tool: .claude, authMode: .token)
        #expect(p.localProviderCloudHosts.isEmpty)
    }

    @Test("Mixed profile: local claude + local grok unions both providers")
    func mixedLocal() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "m"
        p.additionalTools = [Profile.ToolSpec(tool: .grok, authMode: .local, localModelID: "m")]
        #expect(p.localProviderCloudHosts == ["anthropic.com", "x.ai", "grok.com"])
    }

    @Test("Cloud claude + local omp (private server): anthropic.com stays cloud")
    func cloudClaudeLocalOmp() {
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p.additionalTools = [Profile.ToolSpec(tool: .omp, authMode: .local, localModelID: "deepseek-v4-flash")]
        #expect(!p.localProviderCloudHosts.contains("anthropic.com"))
        #expect(p.localProviderCloudHosts.isEmpty)
    }

    @Test("A host a cloud agent speaks to is never local, even when a local agent shares it")
    func cloudAgentWinsSharedHost() {
        var p = Profile(name: "t", tool: .codex, authMode: .token, apiKey: "sk-x")
        p.additionalTools = [Profile.ToolSpec(tool: .claude, authMode: .local, localModelID: "m"),
                             Profile.ToolSpec(tool: .omp, authMode: .token, ompProvider: .anthropic)]
        #expect(!p.localProviderCloudHosts.contains("anthropic.com"))
        #expect(!p.localProviderCloudHosts.contains("openai.com"))
    }

    @Test("The launch overlay's shape: cloud claude, every other agent local, only their hosts")
    func overlayShape() {
        var p = Profile(name: "t", tool: .claude, authMode: .subscription)
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m"),
                             Profile.ToolSpec(tool: .grok, authMode: .local, localModelID: "m"),
                             Profile.ToolSpec(tool: .kimi, authMode: .local, localModelID: "m"),
                             Profile.ToolSpec(tool: .omp, authMode: .local, localModelID: "m")]
        let hosts = p.localProviderCloudHosts
        #expect(!hosts.contains("anthropic.com"))
        #expect(hosts.isSuperset(of: ["openai.com", "x.ai", "moonshot.ai"]))
    }

    @Test("Mixed profile: cloud claude + local codex — only codex's hosts")
    func mixedClaudeCloudCodexLocal() {
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m")]
        let hosts = p.localProviderCloudHosts
        #expect(hosts == ["openai.com", "chatgpt.com"])
        #expect(!hosts.contains("anthropic.com"))   // subscription/token Claude reaches cloud
    }
}

@Suite("Profile routing decode")
struct ProfileRoutingDecodeTests {
    private func roundTrip(routing: String?) throws -> Profile {
        let base = Profile(name: "Legacy", tool: .claude, authMode: .token)
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        obj["modelRouting"] = routing
        obj["activeModelID"] = "some-model"
        return try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    @Test("a workspace saved with the dropped \"hybrid\" routing still loads, as cloud")
    func legacyHybridReadsAsCloud() throws {
        let p = try roundTrip(routing: "hybrid")
        #expect(p.modelRouting == .cloud)
        #expect(p.name == "Legacy")
        #expect(p.activeModelID == "some-model")   // the rest of the workspace survives
    }

    @Test("known routings decode as themselves; unknown or missing reads as cloud")
    func routingValues() throws {
        #expect(try roundTrip(routing: "local").modelRouting == .local)
        #expect(try roundTrip(routing: "cloud").modelRouting == .cloud)
        #expect(try roundTrip(routing: "quantum").modelRouting == .cloud)
        #expect(try roundTrip(routing: nil).modelRouting == .cloud)
    }
}
