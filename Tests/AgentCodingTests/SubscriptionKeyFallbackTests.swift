import Foundation
import Testing
@testable import bromure_ac

/// A workspace set to its provider's SUBSCRIPTION with no subscription login
/// but an API key in Settings › Models keeps running on that key — the user
/// configured it on purpose — and the session merely notes "using API key".
/// Nothing is blocked, no sign-in is forced.
@Suite("Subscription workspace vs the global API key")
struct SubscriptionKeyFallbackTests {

    private func settings(_ provider: ModelProvider, key: String = "global-key") -> ModelSettings {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: provider, apiKey: key)]
        return s
    }

    @Test("Subscription workspace, no login, global key: the key is used and noted")
    func keyUsedAndNoted() {
        let p = Profile(name: "w", tool: .claude, authMode: .subscription)
        let out = p.overlaidWithGlobalModels(settings(.anthropic), subscribed: [])
        #expect(out.authMode == .token)
        #expect(out.apiKey == "global-key")
        #expect(p.subscriptionResolutions(settings(.anthropic), subscribed: [])[.claude] == .apiKeyFallback)
    }

    @Test("The pasted key keeps its precedence even when a login exists (unchanged staging)")
    func keyPrecedenceUnchanged() {
        let p = Profile(name: "w", tool: .claude, authMode: .subscription)
        let out = p.overlaidWithGlobalModels(settings(.anthropic), subscribed: [.anthropic])
        #expect(out.authMode == .token)
        #expect(out.apiKey == "global-key")
        // The note matches what is staged.
        #expect(p.subscriptionResolutions(settings(.anthropic), subscribed: [.anthropic])[.claude] == .apiKeyFallback)
    }

    @Test("No key: a login authenticates; without one the agent shows its own login")
    func noKey() {
        let p = Profile(name: "w", tool: .claude, authMode: .subscription)
        #expect(p.subscriptionResolutions(ModelSettings(), subscribed: [.anthropic])[.claude] == .subscription)
        #expect(p.subscriptionResolutions(ModelSettings(), subscribed: [])[.claude] == .signInNeeded)
    }

    @Test("Same rule for Codex, Grok and Kimi",
          arguments: [(Profile.Tool.codex, ModelProvider.openai),
                      (.grok, .xai), (.kimi, .moonshot)])
    func otherSubscriptions(_ tool: Profile.Tool, _ provider: ModelProvider) {
        let p = Profile(name: "w", tool: tool, authMode: .subscription)
        let out = p.overlaidWithGlobalModels(settings(provider), subscribed: [])
        #expect(out.authMode == .token)
        #expect(out.apiKey == "global-key")
        #expect(p.subscriptionResolutions(settings(provider), subscribed: [])[tool] == .apiKeyFallback)
    }

    @Test("A workspace on an API key is untouched; omp has no subscription")
    func notApplicable() {
        let token = Profile(name: "w", tool: .claude, authMode: .token)
        #expect(token.subscriptionResolutions(settings(.anthropic), subscribed: [.anthropic]).isEmpty)
        #expect(token.overlaidWithGlobalModels(settings(.anthropic), subscribed: [.anthropic]).apiKey == "global-key")
        let omp = Profile(name: "w", tool: .omp, authMode: .subscription)
        #expect(omp.subscriptionResolutions(settings(.anthropic), subscribed: []).isEmpty)
    }

    @Test("The workspace's own API key (Models override) needs no note")
    func workspaceOwnKey() {
        var p = Profile(name: "w", tool: .claude, authMode: .subscription)
        var layer = ModelSettings()
        layer.providers = [ProviderCredential(provider: .anthropic, apiKey: "ws-key")]
        p.modelOverride = ModelOverride(inheritsGlobal: true, settings: layer)
        let eff = p.modelOverride!.resolved(over: settings(.anthropic))
        let out = p.overlaidWithGlobalModels(eff, subscribed: [])
        #expect(out.authMode == .token)
        #expect(out.apiKey == "ws-key")
        #expect(p.subscriptionResolutions(eff, subscribed: []).isEmpty)
    }

    @Test("The Security Timeline notes 'using API key' neutrally")
    func timelineRow() {
        let fb = SecurityTimeline.map(profileID: UUID(), eventType: "credential.subscription_auth",
                                      eventData: ["agent": .string("claude"), "verdict": .string("api_key_fallback")],
                                      now: Date())
        #expect(fb?.decision == "using API key")
        #expect(fb?.kind == .info)
    }
}
