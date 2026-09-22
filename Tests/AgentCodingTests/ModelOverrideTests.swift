import Foundation
import Testing
@testable import bromure_ac

@Suite("ModelOverride — layered workspace model settings")
struct ModelOverrideTests {
    private func global() -> ModelSettings {
        var g = ModelSettings()
        g.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant-global"),
                       ProviderCredential(provider: .openai, apiKey: "sk-oa-global"),
                       ProviderCredential(provider: .zai, apiKey: "zai-global")]
        g.localServer = LocalServer(baseURL: "http://box:8000/v1", apiKey: "srv")
        g.tiers = [.medium: ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-5"),
                   .large: ModelRef(source: .provider(.anthropic), modelID: "claude-opus-5")]
        g.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openai), modelID: "gpt-5.6")]
        return g
    }

    @Test("Layered: own providers replace, exclusions drop, the rest inherits")
    func layeredResolve() {
        let g = global()
        var layer = ModelSettings()
        layer.providers = [ProviderCredential(provider: .openai, apiKey: "sk-oa-mine")]
        layer.tiers = [.medium: ModelRef(source: .provider(.zai), modelID: "glm-5.3")]
        layer.agentTiers[.kimi] = [.medium: ModelRef(source: .localServer, modelID: "qwen")]
        let o = ModelOverride(inheritsGlobal: true, settings: layer, excludedProviders: [.anthropic])
        let r = o.resolved(over: g)
        #expect(r.credential(.openai)?.apiKey == "sk-oa-mine")     // overridden
        #expect(r.credential(.zai)?.apiKey == "zai-global")         // inherited
        #expect(r.credential(.anthropic) == nil)                    // excluded
        #expect(r.localServer?.baseURL == "http://box:8000/v1")     // inherited
        #expect(r.tiers[.medium]?.modelID == "glm-5.3")             // layer wins
        #expect(r.tiers[.large]?.modelID == "claude-opus-5")        // inherited
        #expect(r.agentTiers[.codex]?[.medium]?.modelID == "gpt-5.6")   // inherited per-agent
        #expect(r.agentTiers[.kimi]?[.medium]?.modelID == "qwen")       // layer per-agent
        #expect(o.providerStatus(.openai, global: g) == .overridden)
        #expect(o.providerStatus(.zai, global: g) == .inherited)
        #expect(o.providerStatus(.anthropic, global: g) == .excluded)
        #expect(o.providerStatus(.xai, global: g) == .unset)
    }

    @Test("Layered: `.custom` in the exclusions drops the inherited custom server")
    func excludedCustomServer() {
        let o = ModelOverride(inheritsGlobal: true, excludedProviders: [.custom])
        #expect(o.resolved(over: global()).localServer == nil)
        var own = ModelSettings(); own.localServer = LocalServer(baseURL: "http://mine:1/v1")
        let o2 = ModelOverride(inheritsGlobal: true, settings: own, excludedProviders: [.custom])
        #expect(o2.resolved(over: global()).localServer?.baseURL == "http://mine:1/v1")
    }

    @Test("Standalone ignores the global settings entirely")
    func standalone() {
        var own = ModelSettings()
        own.providers = [ProviderCredential(provider: .xai, apiKey: "xai-mine")]
        let r = ModelOverride.standalone(own).resolved(over: global())
        #expect(r.credential(.anthropic) == nil)
        #expect(r.credential(.xai)?.apiKey == "xai-mine")
        #expect(r.tiers.isEmpty)
    }

    @Test("Empty layer resolves to the global settings; the store honours it")
    @MainActor func emptyLayer() {
        let g = global()
        #expect(ModelOverride(inheritsGlobal: true).resolved(over: g) == g)
    }

    @Test("A legacy full-override document (bare ModelSettings) decodes as standalone")
    func legacyDecode() throws {
        let legacy = global()
        let data = try JSONEncoder().encode(legacy)
        let o = try JSONDecoder().decode(ModelOverride.self, from: data)
        #expect(o.inheritsGlobal == false)
        #expect(o.settings == legacy)
        #expect(o.excludedProviders.isEmpty)
        // And the new shape round-trips.
        let layered = ModelOverride(inheritsGlobal: true, settings: ModelSettings(), excludedProviders: [.openai])
        let back = try JSONDecoder().decode(ModelOverride.self, from: JSONEncoder().encode(layered))
        #expect(back == layered)
    }

    @Test("Override provider keys are vaulted with the profile's secrets and restored")
    func secretsRoundTrip() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        var layer = ModelSettings()
        layer.providers = [ProviderCredential(provider: .openai, apiKey: "sk-oa-mine"),
                           ProviderCredential(provider: .bedrock)]
        layer.localServer = LocalServer(baseURL: "http://mine:1/v1", apiKey: "srv-mine")
        p.modelOverride = ModelOverride(inheritsGlobal: true, settings: layer)
        var stripped = p
        let secrets = ProfileSecrets.extract(stripping: &stripped)
        #expect(stripped.modelOverride?.settings.credential(.openai)?.apiKey == "")
        #expect(stripped.modelOverride?.settings.localServer?.apiKey == "")
        #expect(secrets.modelProviderKeys?["openai"] == "sk-oa-mine")
        #expect(secrets.modelLocalServerKey == "srv-mine")
        var restored = stripped
        secrets.apply(to: &restored)
        #expect(restored.modelOverride?.settings.credential(.openai)?.apiKey == "sk-oa-mine")
        #expect(restored.modelOverride?.settings.localServer?.apiKey == "srv-mine")
        // A retyped key in the incoming document wins over the stored one.
        var typed = stripped
        typed.modelOverride?.settings.providers[0].apiKey = "sk-oa-new"
        secrets.apply(to: &typed)
        #expect(typed.modelOverride?.settings.credential(.openai)?.apiKey == "sk-oa-new")
    }

    @Test("Redaction stand-in keeps credentials usable and restores stored keys on save")
    func redaction() {
        let g = global()
        let red = g.redacted()
        #expect(red.credential(.anthropic)?.apiKey == ModelSettings.redactedSecret)
        #expect(red.credential(.anthropic)?.isUsable == true)
        #expect(red.localServer?.apiKey == ModelSettings.redactedSecret)
        var edited = red
        edited.providers.removeAll { $0.provider == .zai }                 // dropped
        edited.providers.append(ProviderCredential(provider: .xai, apiKey: "xai-new"))   // typed
        edited.providers[0].apiKey = ""                                    // blank = keep
        let merged = edited.restoringSecrets(from: g)
        #expect(merged.credential(.anthropic)?.apiKey == "sk-ant-global")
        #expect(merged.credential(.openai)?.apiKey == "sk-oa-global")
        #expect(merged.credential(.zai) == nil)
        #expect(merged.credential(.xai)?.apiKey == "xai-new")
        #expect(merged.localServer?.apiKey == "srv")
    }
}
