import Foundation
import Testing
@testable import bromure_ac

@Suite("ModelLaunchPlan derivation")
struct ModelLaunchPlanTests {
    let engine = "https://bromure.llm"

    @Test("Cloud provider tier resolves to its host + swap scope") func cloudTier() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant")]
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-4-5")

        let plan = s.launchPlan(builtInEngineBase: engine)
        let m = try! #require(plan.medium)
        #expect(m.baseURL == "https://api.anthropic.com")
        #expect(m.swapHost == "anthropic.com")
        #expect(m.wire == .anthropic)
        #expect(!m.isLocal)
        #expect(plan.primary?.modelID == "claude-sonnet-4-5")
        #expect(plan.usesLocal == false)
        #expect(plan.swapHosts == ["anthropic.com"])
    }

    @Test("Unregistered provider tier drops out") func unregisteredDrops() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .provider(.openai), modelID: "gpt-5.2")
        let plan = s.launchPlan(builtInEngineBase: engine)
        #expect(plan.medium == nil)
        #expect(plan.primary == nil)
    }

    @Test("Local server tier → user URL, no swap, openai wire") func localServerTier() {
        var s = ModelSettings()
        s.localServer = LocalServer(baseURL: "http://box:8000/v1", apiKey: "tok")
        s.tiers[.medium] = ModelRef(source: .localServer, modelID: "qwen3-coder")
        let plan = s.launchPlan(builtInEngineBase: engine)
        let m = try! #require(plan.medium)
        #expect(m.baseURL == "http://box:8000/v1")
        #expect(m.swapHost == "")
        #expect(m.wire == .openaiChat)
        #expect(m.isLocal)
        #expect(plan.usesLocal)
        #expect(plan.swapHosts.isEmpty)
    }

    @Test("On-device tier → engine sentinel, anthropic wire") func onDeviceTier() {
        var s = ModelSettings()
        s.tiers[.medium] = ModelRef(source: .localRun(catalogID: "qwen"), modelID: "qwen")
        let plan = s.launchPlan(builtInEngineBase: engine)
        let m = try! #require(plan.medium)
        #expect(m.baseURL == engine)
        #expect(m.isLocal)
        #expect(m.wire == .anthropic)
    }

    @Test("Custom provider swap host derives from base URL") func customSwapHost() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .custom, apiKey: "k",
                                          baseURL: "https://llm.corp.example.com:8000/v1")]
        s.tiers[.medium] = ModelRef(source: .provider(.custom), modelID: "internal-model")
        let plan = s.launchPlan(builtInEngineBase: engine)
        #expect(plan.medium?.swapHost == "example.com")
        #expect(plan.medium?.baseURL == "https://llm.corp.example.com:8000/v1")
    }

    @Test("Three distinct tiers all resolve; primary is medium") func threeTiers() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "sk-ant")]
        s.localServer = LocalServer(baseURL: "http://box:8000/v1")
        s.tiers[.small]  = ModelRef(source: .localServer, modelID: "small-local")
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-4-5")
        s.tiers[.large]  = ModelRef(source: .provider(.anthropic), modelID: "claude-opus-4-5")

        let plan = s.launchPlan(builtInEngineBase: engine)
        #expect(plan.small?.isLocal == true)
        #expect(plan.medium?.modelID == "claude-sonnet-4-5")
        #expect(plan.large?.modelID == "claude-opus-4-5")
        #expect(plan.primary?.modelID == "claude-sonnet-4-5")
        #expect(plan.usesLocal)                       // small is local
        #expect(plan.swapHosts == ["anthropic.com"])  // only cloud tiers count
    }

    @Test("Primary falls back to large then small") func primaryFallback() {
        var s = ModelSettings()
        s.localServer = LocalServer(baseURL: "http://box:8000/v1")
        s.tiers[.small] = ModelRef(source: .localServer, modelID: "s")
        #expect(s.launchPlan(builtInEngineBase: engine).primary?.modelID == "s")
        s.tiers[.large] = ModelRef(source: .localServer, modelID: "l")
        #expect(s.launchPlan(builtInEngineBase: engine).primary?.modelID == "l")
    }
}
