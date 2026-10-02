import Foundation
import Testing
@testable import bromure_ac

// A model on the user's own server whose context window the server doesn't
// advertise: the user enters it in the Models pane, and every agent using
// the model is told — omp assumed 128K for a 1M model.

@Suite("Local model context window")
struct ContextWindowTests {

    @Test("tokens typed the way people write them")
    func parse() {
        #expect(ModelCapabilities.parseTokens("1M") == 1_000_000)
        #expect(ModelCapabilities.parseTokens("1.5m") == 1_500_000)
        #expect(ModelCapabilities.parseTokens("256K") == 256_000)
        #expect(ModelCapabilities.parseTokens(" 131,072 ") == 131_072)
        #expect(ModelCapabilities.parseTokens("200000 tokens") == 200_000)
        #expect(ModelCapabilities.parseTokens("") == nil)
        #expect(ModelCapabilities.parseTokens("lots") == nil)
        #expect(ModelCapabilities.parseTokens("12") == nil)   // not a context window
        #expect(ModelCapabilities.formatTokens(1_000_000) == "1M")
        #expect(ModelCapabilities.formatTokens(1_500_000) == "1.5M")
        #expect(ModelCapabilities.formatTokens(131_072) == "131K")
    }

    @Test("the custom server's model: the entered window reaches the launch profile and omp's models file")
    func localServerRoute() {
        var s = ModelSettings()
        s.localServer = LocalServer(baseURL: "http://10.0.0.5:8888")
        s.agentTiers[.omp] = [.medium: ModelRef(source: .localServer, modelID: "big-model",
                                                capabilities: ModelCapabilities(contextWindow: 1_000_000),
                                                capabilitiesOverridden: true)]
        #expect(s.localContextWindow(forModel: "big-model") == 1_000_000)
        #expect(s.localContextWindow(forModel: "other") == nil)
        let out = Profile(name: "t", tool: .omp, authMode: .token).overlaidWithGlobalModels(s)
        #expect(out.activeModelID == "big-model")
        #expect(out.localModelContextWindow == 1_000_000)
        #expect(SessionDisk.localModelContext(profile: out) == 1_000_000)
        #expect(SessionDisk.ompModelsYAML(base: "https://x/v1", model: "big-model",
                                          contextWindow: SessionDisk.localModelContext(profile: out))
                .contains("contextWindow: 1000000"))
        // Not saved with the workspace: it's the launch copy's.
        let data = try! JSONEncoder().encode(out)
        #expect(!String(decoding: data, as: UTF8.self).contains("ContextWindow"))
    }

    @Test("omp switched to a custom provider: the window rides on its own models file")
    func ompCustomProvider() {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .custom, apiKey: "k", baseURL: "http://10.0.0.5:8888/v1")]
        s.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.custom), modelID: "big-model",
                                                capabilities: ModelCapabilities(contextWindow: 1_000_000),
                                                capabilitiesOverridden: true)]
        let out = Profile(name: "t", tool: .omp, authMode: .token).overlaidWithGlobalModels(s)
        #expect(out.ompProvider == .custom)
        #expect(out.ompContextWindow == 1_000_000)
        // Nothing entered: no window, omp keeps its own default.
        s.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.custom), modelID: "big-model")]
        #expect(Profile(name: "t", tool: .omp, authMode: .token).overlaidWithGlobalModels(s).ompContextWindow == nil)
    }
}
