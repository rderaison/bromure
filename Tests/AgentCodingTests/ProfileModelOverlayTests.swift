import Foundation
import Testing
@testable import bromure_ac

@Suite("Global model overlay onto a launch profile")
struct ProfileModelOverlayTests {

    @Test("Empty settings leave the profile unchanged") func noop() {
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "orig")
        let out = p.overlaidWithGlobalModels(ModelSettings())
        #expect(out.apiKey == "orig")
        #expect(out.authMode == .token)
    }

    @Test("Cloud provider projects its key onto the native agent") func cloudKey() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "global-ant")]
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "stale")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.authMode == .token)
        #expect(out.apiKey == "global-ant")
    }

    @Test("Subscription provider → subscription auth, no key") func subscription() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, useSubscription: true)]
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "stale")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.authMode == .subscription)
        #expect(out.apiKey == nil)
    }

    @Test("An unregistered provider leaves that agent's auth untouched") func unregisteredUntouched() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .openai, apiKey: "oai")]
        // Claude's provider (anthropic) isn't registered → keep its own key.
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "own-ant")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.apiKey == "own-ant")
    }

    @Test("Local server tier makes every agent local + seeds the engine URL") func localServer() {
        var s = ModelSettings()
        s.localServer = LocalServer(baseURL: "http://box:8000/v1", apiKey: "tok")
        s.tiers[.medium] = ModelRef(source: .localServer, modelID: "qwen3-coder")
        var p = Profile(name: "t", tool: .claude, authMode: .subscription)
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .token, apiKey: "x")]
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.modelRouting == .local)
        #expect(out.authMode == .local)
        #expect(out.activeModelID == "qwen3-coder")
        #expect(out.localEngineURL == "http://box:8000/v1")
        #expect(out.localEngineAPIKey == "tok")
        #expect(out.additionalTools.first?.authMode == .local)
        #expect(out.additionalTools.first?.localModelID == "qwen3-coder")
    }

    @Test("On-device tier → local, built-in engine (no URL)") func onDevice() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .localRun(catalogID: "qwen-mlx"), modelID: "qwen-mlx")
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "x")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.modelRouting == .local)
        #expect(out.authMode == .local)
        #expect(out.activeModelID == "qwen-mlx")
        #expect(out.localEngineURL == nil)
    }

    @Test("omp draws the key of its configured provider globally") func ompProvider() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .zai, apiKey: "zai-global")]
        var p = Profile(name: "t", tool: .omp, authMode: .token, apiKey: "stale")
        p.ompProvider = .zai
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.apiKey == "zai-global")
    }

    @Test("Per-agent: Claude local + Codex cloud in one profile") func perAgentMix() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .openai, apiKey: "oai-key")]
        s.localServer = LocalServer(baseURL: "http://box:8000/v1")
        // Default = local qwen; Codex overrides to cloud OpenAI.
        s.tiers[.medium] = ModelRef(source: .localServer, modelID: "qwen")
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openai), modelID: "gpt-5")]

        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "x")
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .token, apiKey: "y")]
        let out = p.overlaidWithGlobalModels(s)

        // Claude follows the local default.
        #expect(out.authMode == .local)
        #expect(out.activeModelID == "qwen")
        #expect(out.localEngineURL == "http://box:8000/v1")
        #expect(out.modelRouting == .local)
        // Codex overrides to cloud OpenAI with the global key.
        let codex = out.additionalTools.first { $0.tool == .codex }
        #expect(codex?.authMode == .token)
        #expect(codex?.apiKey == "oai-key")
    }

    @Test("A cloud primary tier sets the cloud route") func cloudRoute() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "k")]
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-4-5")
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "k")
        p.modelRouting = .local   // stale
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.modelRouting == .cloud)
    }

    /// The staging scripts only emit credentials for tools in `allToolSpecs`
    /// ("enabled"). A workspace whose primary is Codex has no Claude spec, so
    /// even with an Anthropic login the guest got no ANTHROPIC_API_KEY and
    /// Claude asked you to register. The overlay must enable every agent.
    @Test("Every agent is enabled so a non-primary agent's credentials propagate")
    func enablesAllAgents() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-5")
        let salt = Data(repeating: 1, count: 32)

        // Codex-primary workspace; Claude isn't in the profile at all.
        let p = Profile(name: "t", tool: .codex, authMode: .token, apiKey: "oai")
        #expect(!p.allToolSpecs.contains { $0.tool == .claude })
        // The bug: not enabled → the token plan mints no bogus Claude key.
        let before = p.makeTokenPlan(salt: salt, claudeSubscriptionAvailable: true)
        #expect(before.claudeSubscriptionBogusKey == nil)

        let out = p.overlaidWithGlobalModels(s, subscribed: [.anthropic])
        // Every agent is now present (enabled), primary untouched…
        #expect(out.tool == .codex)
        for tool in Profile.Tool.allCases {
            #expect(out.allToolSpecs.contains { $0.tool == tool })
        }
        // …Claude is in subscription mode via the real host-side login…
        #expect(out.allToolSpecs.first { $0.tool == .claude }?.authMode == .subscription)
        // …so the token plan mints the bogus ANTHROPIC_API_KEY the guest needs.
        let after = out.makeTokenPlan(salt: salt, claudeSubscriptionAvailable: true)
        #expect(after.claudeSubscriptionBogusKey != nil)
    }

    /// The new-session screen's "Ready" label must follow the global Models
    /// settings, not only the workspace's saved tool list: a Claude-only
    /// workspace still starts omp on the global z.ai key and Codex on a
    /// host-side ChatGPT login.
    @Test("Agents are ready when the global settings can credential them")
    func readyFollowsGlobalSettings() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .zai, apiKey: "zai-global")]
        s.localServer = LocalServer(baseURL: "http://box:8000/v1")
        s.agentTiers[.kimi] = [.medium: ModelRef(source: .localServer, modelID: "qwen")]

        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "own")
        p.ompProvider = .zai
        let ready = p.agentsReadyToStart(s, subscribed: [.openai])
        #expect(ready.contains(.claude))   // the workspace's own tool
        #expect(ready.contains(.omp))      // global z.ai key
        #expect(ready.contains(.codex))    // host-side ChatGPT login
        #expect(ready.contains(.kimi))     // local tier
        #expect(!ready.contains(.grok))    // nothing for xAI anywhere

        // Nothing global, nothing signed in: only the saved tool list counts.
        #expect(p.agentsReadyToStart(ModelSettings()) == [.claude])
    }

    /// A local model can take minutes to emit its first token; omp's default
    /// first-event timeout would abort the stream. Local omp must export a
    /// 30-minute PI_STREAM_FIRST_EVENT_TIMEOUT_MS alongside its dummy key.
    @Test("Local omp env exports a 30-minute first-event timeout")
    func ompLocalStreamTimeout() {
        let env = Profile.Tool.omp.localEnvExports(model: "qwen3-coder", key: "dummy")
        let timeout = env.first { $0.name == "PI_STREAM_FIRST_EVENT_TIMEOUT_MS" }
        #expect(timeout?.value == "1800000")
        #expect(env.contains { $0.name == "OPENAI_API_KEY" })   // still exports the dummy key
    }
}
