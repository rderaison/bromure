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

    @Test("`.hybrid` is left untouched even with no local-auth tool")
    func hybridUntouched() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.modelRouting = .hybrid
        #expect(p.effectiveModelRouting == .hybrid)
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

    @Test("Mixed profile: cloud claude + local codex — only codex's hosts")
    func mixedClaudeCloudCodexLocal() {
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m")]
        let hosts = p.localProviderCloudHosts
        #expect(hosts == ["openai.com", "chatgpt.com"])
        #expect(!hosts.contains("anthropic.com"))   // subscription/token Claude reaches cloud
    }
}
