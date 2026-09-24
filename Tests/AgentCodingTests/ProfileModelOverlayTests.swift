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

    /// Amazon Bedrock is Claude Code's alternative route: a Bedrock ref for
    /// Claude sets `.bedrock` auth + the Bedrock env fields; only Claude can
    /// take it; the global Anthropic key no longer clobbers it.
    @Test("Bedrock ref → Claude authenticates through Bedrock")
    func bedrockRoute() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant"),
                       ProviderCredential(provider: .bedrock)]
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-5")
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.bedrock),
                                                   modelID: "us.anthropic.claude-sonnet-4-6-v1:0")]
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "stale")
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .token, apiKey: "y")]
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.authMode == .bedrock)
        #expect(out.apiKey == nil)
        #expect(out.bedrockEnabled)
        #expect(out.bedrockModelID == "us.anthropic.claude-sonnet-4-6-v1:0")
        #expect(out.modelRouting == .cloud)

        // Moving Claude back to Anthropic drops the Bedrock env again.
        s.agentTiers[.claude] = nil
        var was = p
        was.authMode = .bedrock
        was.bedrockEnabled = true
        let back = was.overlaidWithGlobalModels(s)
        #expect(back.authMode == .token)
        #expect(back.apiKey == "sk-ant")
        #expect(!back.bedrockEnabled)

        // Ready only with AWS credentials in the workspace (a workspace whose
        // own tool list doesn't already name Claude).
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.bedrock),
                                                   modelID: "us.anthropic.claude-sonnet-4-6-v1:0")]
        let codexWS = Profile(name: "c", tool: .codex, authMode: .token, apiKey: "oai")
        #expect(!codexWS.agentsReadyToStart(s).contains(.claude))
        var aws = codexWS
        aws.awsCredentials.authMode = .staticKeys
        aws.awsCredentials.accessKeyID = "AKIA"
        aws.awsCredentials.secretAccessKey = "secret"
        #expect(aws.agentsReadyToStart(s).contains(.claude))
    }

    /// Every other agent reaches Bedrock through the external-engine route:
    /// `.local` auth, the agent's own model id, the engine pointed at that
    /// region's bedrock-runtime OpenAI surface — keyed, or left to SigV4.
    @Test("Bedrock ref → Codex runs through Bedrock's OpenAI-compatible engine")
    func bedrockExternalRoute() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .bedrock, region: "eu-west-1")]
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.bedrock), modelID: "openai.gpt-oss-120b-1:0")]
        let p = Profile(name: "t", tool: .codex, authMode: .token, apiKey: "oai")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.authMode == .local)
        #expect(out.modelRouting == .local)
        #expect(out.activeModelID == "openai.gpt-oss-120b-1:0")
        #expect(out.localEngineURL == "https://bedrock-runtime.eu-west-1.amazonaws.com/openai")
        #expect(out.localEngineAPIKey == nil)          // SigV4 on the host
        #expect(out.usesBedrockRoute)
        #expect(!out.bedrockEnabled)                   // Claude's native mode untouched

        // With a Bedrock API key the engine gets it as a bearer, and the
        // region falls back to the workspace's AWS region.
        s.providers = [ProviderCredential(provider: .bedrock, apiKey: "ABSK-key")]
        var ws = p
        ws.awsCredentials.region = "us-west-2"
        let keyed = ws.overlaidWithGlobalModels(s)
        #expect(keyed.localEngineAPIKey == "ABSK-key")
        #expect(keyed.localEngineURL == "https://bedrock-runtime.us-west-2.amazonaws.com/openai")
        // Ready: a key needs no AWS credentials.
        #expect(p.agentsReadyToStart(s).contains(.codex))

        // Claude with a Bedrock key: native mode, key on the spec → the token
        // plan mints the AWS_BEARER_TOKEN_BEDROCK fake scoped to that host.
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.bedrock), modelID: "us.anthropic.claude-sonnet-4-6")]
        let claude = Profile(name: "c", tool: .claude, authMode: .token, apiKey: "stale")
            .overlaidWithGlobalModels(s)
        #expect(claude.authMode == .bedrock)
        #expect(claude.apiKey == "ABSK-key")
        #expect(claude.awsCredentials.region == Bedrock.defaultRegion)
        let plan = claude.makeTokenPlan(salt: Data(repeating: 2, count: 32))
        #expect(plan.fakeForBedrock()?.hasPrefix("bedrock-brm-") == true)
        #expect(plan.fakeForAnthropic() == nil)
    }

    /// OpenRouter: Claude Code goes direct to its Anthropic-compatible endpoint
    /// (base URL + bearer swapped on openrouter.ai, model ids pinned per tier);
    /// every other agent goes through the external-engine route with the key.
    @Test("OpenRouter: Claude direct via ANTHROPIC_BASE_URL, Codex through the engine route")
    func openRouterRoutes() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .openrouter, apiKey: "sk-or-v1-real"),
                       ProviderCredential(provider: .anthropic, apiKey: "sk-ant")]
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.openrouter), modelID: "anthropic/claude-sonnet-4.6"),
                                 .large:  ModelRef(source: .provider(.openrouter), modelID: "anthropic/claude-opus-4.8")]
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openrouter), modelID: "openai/gpt-5.2")]

        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "stale")
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.authMode == .token)
        #expect(out.apiKey == "sk-or-v1-real")
        #expect(out.claudeGatewayBaseURL == "https://openrouter.ai/api")
        #expect(out.claudeGatewayModels == ["medium": "anthropic/claude-sonnet-4.6",
                                            "large": "anthropic/claude-opus-4.8"])
        #expect(!out.bedrockEnabled)
        // The plan scopes Claude's key to the gateway, not anthropic.com.
        let plan = out.makeTokenPlan(salt: Data(repeating: 3, count: 32))
        #expect(plan.fakeForCloud(host: "openrouter.ai")?.hasPrefix("sk-or-v1-brm-") == true)
        #expect(plan.fakeForAnthropic() == nil)
        // Codex: external route at OpenRouter's root, keyed.
        let codex = out.additionalTools.first { $0.tool == .codex }
        #expect(codex?.authMode == .local)
        #expect(codex?.localModelID == "openai/gpt-5.2")
        #expect(out.localEngineURL == "https://openrouter.ai/api")
        #expect(out.localEngineAPIKey == "sk-or-v1-real")
        // Both count as ready on the key alone.
        let ready = p.agentsReadyToStart(s)
        #expect(ready.contains(.claude) && ready.contains(.codex))

        // Back to Anthropic: the gateway fields clear.
        s.agentTiers[.claude] = nil
        let back = out.overlaidWithGlobalModels(s)
        #expect(back.claudeGatewayBaseURL == nil)
        #expect(back.claudeGatewayModels.isEmpty)
        #expect(back.apiKey == "sk-ant")
        #expect(LiveModelRefresh.agentsNeedingRestart(from: out, to: back).contains(.claude))
    }

    /// A live model change restarts only the agents whose staging moved.
    @Test("Only agents whose credential or model changed restart")
    func agentsNeedingRestart() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "k1"),
                       ProviderCredential(provider: .openai, apiKey: "o1")]
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "stale")
        let before = p.overlaidWithGlobalModels(s)
        #expect(LiveModelRefresh.agentsNeedingRestart(from: before, to: before).isEmpty)

        // A new Anthropic key: Claude — and omp, whose default provider is
        // Anthropic too; Codex, Grok, Kimi stay put.
        s.providers[0].apiKey = "k2"
        let keyed = p.overlaidWithGlobalModels(s)
        #expect(LiveModelRefresh.agentsNeedingRestart(from: before, to: keyed) == [.claude, .omp])

        // Codex moved to a local server: Codex only (Claude stays cloud).
        s.localServer = LocalServer(baseURL: "http://box:8000/v1")
        s.agentTiers[.codex] = [.medium: ModelRef(source: .localServer, modelID: "qwen")]
        let local = p.overlaidWithGlobalModels(s)
        #expect(LiveModelRefresh.agentsNeedingRestart(from: keyed, to: local) == [.codex])

        // The local server's model changes: every local agent, i.e. Codex.
        s.agentTiers[.codex] = [.medium: ModelRef(source: .localServer, modelID: "qwen-big")]
        let swapped = p.overlaidWithGlobalModels(s)
        #expect(LiveModelRefresh.agentsNeedingRestart(from: local, to: swapped) == [.codex])

        // Claude onto Bedrock: Claude only.
        s.providers.append(ProviderCredential(provider: .bedrock))
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.bedrock), modelID: "us.anthropic.claude-sonnet-4-6")]
        let bedrock = p.overlaidWithGlobalModels(s)
        #expect(LiveModelRefresh.agentsNeedingRestart(from: swapped, to: bedrock) == [.claude])
    }

    /// A workspace that used Bedrock before the redesign keeps it through a
    /// per-workspace override; anything else gets none.
    @Test("Legacy Bedrock workspace → override pinning Claude to Bedrock")
    func bedrockMigration() {
        var global = ModelSettings()
        global.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant")]
        var p = Profile(name: "t", tool: .claude, authMode: .bedrock)
        p.bedrockModelID = "eu.anthropic.claude-sonnet-4-6-v1:0"
        let o = p.bedrockModelOverride(global: global)?.resolved(over: global)
        #expect(o?.credential(.bedrock)?.isUsable == true)
        #expect(o?.credential(.anthropic)?.apiKey == "sk-ant")   // inherited, not copied
        #expect(p.bedrockModelOverride(global: global)?.settings.credential(.anthropic) == nil)
        #expect(o?.agentTiers[.claude]?[.medium]?.source == .provider(.bedrock))
        #expect(o?.agentTiers[.claude]?[.medium]?.modelID == "eu.anthropic.claude-sonnet-4-6-v1:0")
        // Not Bedrock → nothing; already overridden → nothing.
        #expect(Profile(name: "u", tool: .claude, authMode: .token).bedrockModelOverride(global: global) == nil)
        p.modelOverride = .standalone(global)
        #expect(p.bedrockModelOverride(global: global) == nil)
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

    @Test("Claude on Anthropic: no pick = Claude Code default; a pick is pinned")
    func claudeNativeModelPin() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, useSubscription: true)]
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: nil)
        let bare = p.overlaidWithGlobalModels(s)
        #expect(bare.authMode == .subscription)
        #expect(bare.claudeGatewayBaseURL == nil)
        #expect(bare.claudeGatewayModels.isEmpty)

        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.anthropic), modelID: "claude-opus-5")]
        let pinned = p.overlaidWithGlobalModels(s)
        #expect(pinned.authMode == .subscription)
        #expect(pinned.claudeGatewayBaseURL == nil)
        #expect(pinned.claudeGatewayModels == ["medium": "claude-opus-5"])
        #expect(LiveModelRefresh.agentsNeedingRestart(from: bare, to: pinned).contains(.claude))
    }

    @Test("Stale native pre-fills are dropped; other routes are kept")
    func dropNativePrefills() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-5")
        s.agentTiers[.claude] = [.medium: ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-5"),
                                 .large: ModelRef(source: .provider(.openrouter), modelID: "anthropic/claude-opus-4.8")]
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openai), modelID: "gpt-5.5")]
        s.agentTiers[.kimi] = [.medium: ModelRef(source: .localServer, modelID: "qwen")]
        s.dropNativeCloudAgentRefs()
        #expect(s.tiers[.medium]?.modelID == "claude-sonnet-5")          // Default row untouched
        #expect(s.agentTiers[.claude] == [.large: ModelRef(source: .provider(.openrouter),
                                                           modelID: "anthropic/claude-opus-4.8")])
        #expect(s.agentTiers[.codex] == nil)
        #expect(s.agentTiers[.kimi]?[.medium]?.modelID == "qwen")
    }
}
