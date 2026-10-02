import Foundation
import Testing
@testable import bromure_ac

// Issue #36: a pre-5.0 omp custom server stayed forced on a workspace with no
// way to see or remove it. And omp should default to the model it's given
// without hiding the other providers configured in Settings → Models.

@Suite("omp providers")
struct OmpProvidersTests {

    private func legacyWorkspace() -> Profile {
        var p = Profile(name: "ws", tool: .omp, authMode: .token, apiKey: "sk-old")
        p.ompProvider = .custom
        p.ompBaseURL = "http://10.0.0.5:8888/"
        p.ompModel = "big-model"
        return p
    }

    @Test("the old custom server moves into the workspace's model settings, once")
    func migratesLegacyCustom() throws {
        let moved = try #require(legacyWorkspace().migratedLegacyOmpCustom(global: ModelSettings()))
        let layer = try #require(moved.modelOverride)
        #expect(layer.inheritsGlobal)
        let cred = try #require(layer.settings.credential(.custom))
        #expect(cred.baseURL == "http://10.0.0.5:8888/" && cred.apiKey == "sk-old")
        #expect(layer.settings.ref(for: .omp, tier: .medium) == ModelRef(source: .provider(.custom), modelID: "big-model"))
        // Off the agent, key included (it would pass for an Anthropic key).
        #expect(moved.ompProvider == nil && moved.ompBaseURL == nil && moved.ompModel == nil && moved.apiKey == nil)
        // Nothing left to move.
        #expect(moved.migratedLegacyOmpCustom(global: ModelSettings()) == nil)
        // And the launch still puts omp on that server, now from the settings.
        let launch = moved.overlaidWithGlobalModels(layer.settings)
        #expect(launch.ompProvider == .custom && launch.ompModel == "big-model")
    }

    @Test("the same server already shared, or omp already given a model: not duplicated, not overridden")
    func migrationRespectsSettings() throws {
        var global = ModelSettings()
        global.providers = [ProviderCredential(provider: .custom, baseURL: "http://10.0.0.5:8888/v1")]
        global.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.zai), modelID: "glm")]
        let moved = try #require(legacyWorkspace().migratedLegacyOmpCustom(global: global))
        #expect(moved.modelOverride?.settings.credential(.custom) == nil)
        #expect(moved.modelOverride?.settings.agentTiers[.omp] == nil)
        // A workspace override naming ANOTHER custom server: left alone.
        var other = legacyWorkspace()
        var layer = ModelSettings()
        layer.providers = [ProviderCredential(provider: .custom, baseURL: "http://elsewhere")]
        other.modelOverride = ModelOverride(settings: layer)
        #expect(other.migratedLegacyOmpCustom(global: ModelSettings()) == nil)
    }

    @Test("omp keeps the other configured providers on offer, its own one aside")
    func extraProviders() throws {
        var s = ModelSettings()
        s.providers = [
            ProviderCredential(provider: .custom, baseURL: "http://10.0.0.5:8888/v1"),
            ProviderCredential(provider: .zai, apiKey: "zai-key"),
            ProviderCredential(provider: .openrouter, apiKey: "or-key"),
            ProviderCredential(provider: .anthropic, useSubscription: true),
        ]
        s.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.custom), modelID: "big-model")]
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openrouter), modelID: "openai/gpt-5")]
        let out = Profile(name: "t", tool: .omp, authMode: .token).overlaidWithGlobalModels(s)
        #expect(out.ompProvider == .custom)   // the assigned one stays the default
        let extras = out.ompExtraProviders
        // Not its own (custom), not a subscription (API keys only).
        #expect(extras.map(\.provider) == [.zai, .openrouter])
        let zai = try #require(extras.first { $0.provider == .zai })
        #expect(zai.baseURL == nil && zai.envVar == "ZAI_API_KEY" && zai.host == "api.z.ai")
        let or = try #require(extras.first { $0.provider == .openrouter })
        #expect(or.baseURL == "https://openrouter.ai/api/v1" && or.models == ["openai/gpt-5"])
        #expect(or.envVar == "BROMURE_OMP_OPENROUTER_API_KEY")
        // Each key is swapped on its own host only.
        let plan = out.makeTokenPlan(salt: Data(repeating: 1, count: 32))
        let zaiFake = try #require(plan.fakeForCloud(host: "api.z.ai"))
        #expect(zaiFake != "zai-key")
        #expect(plan.fakeForCloud(host: "openrouter.ai") != nil)
        // The OpenAI-compatible one is an entry in omp's models.yml, next to its own.
        let yaml = SessionDisk.ompModelsYAML(base: "http://10.0.0.5:8888/v1", model: "big-model", extras: extras)
        #expect(yaml.contains("  bromure:") && yaml.contains("  bromure-openrouter:"))
        #expect(yaml.contains("apiKey: BROMURE_OMP_OPENROUTER_API_KEY"))
        #expect(!yaml.contains("bromure-zai"))
    }
}
