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

    @Test("A cloud primary tier sets the cloud route") func cloudRoute() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "k")]
        s.tiers[.medium] = ModelRef(source: .provider(.anthropic), modelID: "claude-sonnet-4-5")
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "k")
        p.modelRouting = .local   // stale
        let out = p.overlaidWithGlobalModels(s)
        #expect(out.modelRouting == .cloud)
    }
}
