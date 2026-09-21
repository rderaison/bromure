import Foundation
import Testing
@testable import bromure_ac

@Suite("Global model settings")
struct ModelSettingsTests {

    @Test("Provider credential usability") func usable() {
        #expect(!ProviderCredential(provider: .anthropic).isUsable)
        #expect(ProviderCredential(provider: .anthropic, apiKey: "sk-x").isUsable)
        #expect(ProviderCredential(provider: .anthropic, useSubscription: true).isUsable)
        // custom needs a base URL if no key.
        #expect(!ProviderCredential(provider: .custom).isUsable)
        #expect(ProviderCredential(provider: .custom, baseURL: "http://h:8000").isUsable)
    }

    @Test("Endpoint resolves per source") func endpoint() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant")]
        s.localServer = LocalServer(baseURL: "http://box:8000/v1", apiKey: "tok")

        // provider → its api host + key
        let cloud = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-4")
        #expect(s.endpoint(for: cloud, builtInEngineBase: "https://bromure.llm")?.base == "https://api.anthropic.com")
        #expect(s.endpoint(for: cloud, builtInEngineBase: "https://bromure.llm")?.apiKey == "sk-ant")

        // an unregistered provider → nil (not usable)
        let unreg = ModelRef(source: .provider(.openai), modelID: "gpt-5.2")
        #expect(s.endpoint(for: unreg, builtInEngineBase: "https://bromure.llm") == nil)

        // local server + built-in engine
        let ls = ModelRef(source: .localServer, modelID: "qwen")
        #expect(s.endpoint(for: ls, builtInEngineBase: "https://bromure.llm")?.base == "http://box:8000/v1")
        let lr = ModelRef(source: .localRun(catalogID: "qwen3-coder"), modelID: "qwen3-coder")
        #expect(s.endpoint(for: lr, builtInEngineBase: "https://bromure.llm")?.base == "https://bromure.llm")
    }

    @Test("Primary ref falls back medium → large → small") func primary() {
        var s = ModelSettings()
        #expect(s.primaryRef() == nil)
        s.tiers[.small] = ModelRef(source: .localServer, modelID: "s")
        #expect(s.primaryRef()?.modelID == "s")     // only small set
        s.tiers[.large] = ModelRef(source: .localServer, modelID: "l")
        #expect(s.primaryRef()?.modelID == "l")     // large beats small
        s.tiers[.medium] = ModelRef(source: .localServer, modelID: "m")
        #expect(s.primaryRef()?.modelID == "m")     // medium wins
    }

    @Test("Distinct local-run model ids gather list + tier refs") func distinctLocal() {
        var s = ModelSettings(localRunModels: ["a"])
        s.tiers[.small] = ModelRef(source: .localRun(catalogID: "b"), modelID: "b")
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude")  // not local
        let ids = Set(s.distinctLocalRunModelIDs)
        #expect(ids == ["a", "b"])
    }

    @Test("Old JSON without agentTiers still decodes (tolerant)") func backwardCompatDecode() throws {
        // A payload from a build predating `agentTiers`.
        let json = #"{"providers":[],"localRunModels":[],"tiers":[]}"#
        let s = try JSONDecoder().decode(ModelSettings.self, from: Data(json.utf8))
        #expect(s.agentTiers.isEmpty)
        #expect(s.providers.isEmpty)
        #expect(s.tiers.isEmpty)
    }

    @Test("Per-agent tier overrides the default; unset inherits it") func agentOverride() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "default-med")
        // Codex overrides medium; Claude inherits the default.
        s.agentTiers[.codex] = [.medium: ModelRef(source: .provider(.openai), modelID: "codex-med")]
        #expect(s.ref(for: .claude, tier: .medium)?.modelID == "default-med")
        #expect(s.ref(for: .codex, tier: .medium)?.modelID == "codex-med")
        #expect(s.primaryRef(for: .codex)?.modelID == "codex-med")
        #expect(s.primaryRef(for: .grok)?.modelID == "default-med")   // inherits
    }

    @MainActor
    @Test("Per-agent tier round-trips + reset clears the override") func agentTierStore() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-agent-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ModelSettingsStore(url: tmp)
        store.setTier(.medium, ModelRef(source: .provider(.anthropic), modelID: "def"))
        store.setTier(.medium, ModelRef(source: .provider(.openai), modelID: "codex-only"), for: .codex)

        let reopened = ModelSettingsStore(url: tmp)
        #expect(reopened.settings.ref(for: .codex, tier: .medium)?.modelID == "codex-only")
        #expect(reopened.settings.ref(for: .claude, tier: .medium)?.modelID == "def")

        reopened.resetAgentOverrides(.codex)
        #expect(reopened.settings.ref(for: .codex, tier: .medium)?.modelID == "def")  // back to default
        #expect(reopened.settings.agentTiers[.codex] == nil)
    }

    @MainActor
    @Test("Store round-trips encrypted through a temp file") func storeRoundTrip() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelSettingsStore(url: tmp)
        store.setProvider(.zai, apiKey: "zai-key")
        store.setTier(.medium, ModelRef(source: .provider(.zai), modelID: "glm-5.3-flash"))

        // A fresh store on the same file decrypts what we saved.
        let reopened = ModelSettingsStore(url: tmp)
        #expect(reopened.settings.credential(.zai)?.apiKey == "zai-key")
        #expect(reopened.settings.ref(for: .medium)?.modelID == "glm-5.3-flash")
    }
}
