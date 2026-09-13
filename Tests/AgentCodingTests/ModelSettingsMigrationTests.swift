import Foundation
import Testing
@testable import bromure_ac

@Suite("Global model settings migration")
struct ModelSettingsMigrationTests {

    @Test("Token Claude profile → anthropic provider") func tokenClaude() {
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        let s = ModelSettings.migrated(from: [p])
        #expect(s.credential(.anthropic)?.apiKey == "sk-ant-x")
        #expect(s.credential(.anthropic)?.useSubscription == false)
    }

    @Test("Subscription Claude → anthropic subscription, no key") func subscriptionClaude() {
        let p = Profile(name: "t", tool: .claude, authMode: .subscription)
        let s = ModelSettings.migrated(from: [p])
        #expect(s.credential(.anthropic)?.useSubscription == true)
        #expect(s.credential(.anthropic)?.apiKey == nil)
    }

    @Test("omp with z.ai provider → zai credential") func ompZai() {
        var p = Profile(name: "t", tool: .omp, authMode: .token, apiKey: "zai-key")
        p.ompProvider = .zai
        let s = ModelSettings.migrated(from: [p])
        #expect(s.credential(.zai)?.apiKey == "zai-key")
    }

    @Test("Custom-server profile seeds the local server + medium tier") func localServer() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.modelRouting = .local
        p.localEngineURL = "http://box:8000/v1"
        p.localEngineAPIKey = "tok"
        p.activeModelID = "qwen3-coder"
        let s = ModelSettings.migrated(from: [p])
        #expect(s.localServer?.baseURL == "http://box:8000/v1")
        #expect(s.localServer?.apiKey == "tok")
        // A local model over a custom server → localServer-sourced medium tier.
        #expect(s.tiers[.medium]?.modelID == "qwen3-coder")
        if case .localServer = s.tiers[.medium]?.source {} else { Issue.record("expected .localServer source") }
    }

    @Test("On-device local model → localRun medium tier") func localRun() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.modelRouting = .local
        p.activeModelID = "qwen3-coder-mlx"
        let s = ModelSettings.migrated(from: [p])
        if case .localRun(let cid) = s.tiers[.medium]?.source {
            #expect(cid == "qwen3-coder-mlx")
        } else { Issue.record("expected .localRun source") }
    }

    @Test("First usable key wins; a later blank profile doesn't clobber it") func firstWins() {
        let a = Profile(name: "a", tool: .claude, authMode: .token, apiKey: "real-key")
        let b = Profile(name: "b", tool: .claude, authMode: .token, apiKey: "")
        let s = ModelSettings.migrated(from: [a, b])
        #expect(s.credential(.anthropic)?.apiKey == "real-key")
    }

    @Test("Cloud-only profiles seed no tier (provider defaults were used)") func cloudNoTier() {
        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        let s = ModelSettings.migrated(from: [p])
        #expect(s.tiers[.medium] == nil)
    }

    @MainActor
    @Test("seedIfEmpty populates once, then is idempotent") func seedOnce() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-mig-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ModelSettingsStore(url: tmp)
        #expect(store.isEmpty)

        let p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        #expect(store.seedIfEmpty(from: [p]) == true)
        #expect(store.settings.credential(.anthropic)?.apiKey == "sk-ant-x")
        #expect(!store.isEmpty)

        // A second seed (or a profile with a different key) is a no-op now.
        let q = Profile(name: "q", tool: .codex, authMode: .token, apiKey: "sk-openai-y")
        #expect(store.seedIfEmpty(from: [q]) == false)
        #expect(store.settings.credential(.openai) == nil)
    }
}
