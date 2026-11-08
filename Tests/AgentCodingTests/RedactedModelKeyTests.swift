import Foundation
import Testing
@testable import bromure_ac

/// Live finding: a workspace's own Claude API key (Models override) went out
/// in a describe/export as the redaction stand-in "••••••••", and the update
/// route (a fat client's save, `PATCH` of a fetched document) saved the
/// stand-in AS the key: extract lifted it, overlay let it replace the stored
/// one. The proxy then put it in every request -- non-ASCII, so each was
/// refused as malformed and Claude Code saw ECONNRESET.
@Suite("A workspace's own model keys survive the redacted round trip")
struct RedactedModelKeyTests {
    private func workspace(key: String) -> Profile {
        var p = Profile(name: "w", tool: .claude, authMode: .subscription)
        var layer = ModelSettings()
        layer.providers = [ProviderCredential(provider: .anthropic, apiKey: key)]
        p.modelOverride = ModelOverride(inheritsGlobal: true, settings: layer)
        return p
    }
    /// What the update route does (`automationUpsertProfile`).
    private func merged(existing: Profile, incoming: Profile) -> Profile {
        var e = existing, i = incoming, out = incoming
        let stored = ProfileSecrets.extract(stripping: &e)
        let typed = ProfileSecrets.extract(stripping: &i)
        var m = stored
        m.overlay(with: typed)
        m.apply(to: &out)
        return out
    }

    @Test("the stand-in keeps the stored key; a typed key replaces it")
    func roundTrip() {
        let existing = workspace(key: "sk-ant-api03-real")
        let back = merged(existing: existing, incoming: workspace(key: ModelSettings.redactedSecret))
        #expect(back.modelOverride?.settings.credential(.anthropic)?.apiKey == "sk-ant-api03-real")
        let typed = merged(existing: existing, incoming: workspace(key: "sk-ant-api03-new"))
        #expect(typed.modelOverride?.settings.credential(.anthropic)?.apiKey == "sk-ant-api03-new")
    }

    @Test("a stand-in already saved as the key is never stored or used as one")
    func alreadyCorrupted() {
        var p = workspace(key: ModelSettings.redactedSecret)
        let lifted = ProfileSecrets.extract(stripping: &p)
        #expect(lifted.modelProviderKeys?["anthropic"] == nil)
        #expect(p.modelOverride?.settings.credential(.anthropic)?.apiKey == "")
        // At boot the Models overlay doesn't make it the agent's API key.
        let corrupted = workspace(key: ModelSettings.redactedSecret)
        let eff = ModelSettingsStore.effective(for: corrupted, global: ModelSettings())
        let out = corrupted.overlaidWithGlobalModels(eff)
        #expect(out.apiKey != ModelSettings.redactedSecret)
        #expect(!(out.authMode == .token && out.apiKey == ModelSettings.redactedSecret))
    }
}
