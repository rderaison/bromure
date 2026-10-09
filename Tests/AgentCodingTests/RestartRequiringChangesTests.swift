import Foundation
import Testing
@testable import bromure_ac

/// The workspace editor's "Restart now" prompt must only fire for a genuine
/// VM-baked change — not because the running pane holds the launch-time,
/// model-overlaid copy of the profile while the editor returns the stored one.
@Suite("Restart-requiring profile changes")
struct RestartRequiringChangesTests {

    private func globalSettings() -> ModelSettings {
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .anthropic, apiKey: "global-ant"),
                       ProviderCredential(provider: .openai, apiKey: "global-oai")]
        return s
    }

    private func diff(_ old: Profile, _ new: Profile, _ s: ModelSettings) -> [ACAppDelegate.RestartChange] {
        ACAppDelegate.restartRequiringChangeKinds(from: old.overlaidWithGlobalModels(s),
                                                  to: new.overlaidWithGlobalModels(s))
    }

    @Test("Cosmetic save after launch doesn't prompt for tools")
    func cosmeticSaveAfterLaunch() {
        let s = globalSettings()
        let stored = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        // What the running pane holds: the launch-time overlaid copy.
        let running = stored.overlaidWithGlobalModels(s)
        var edited = stored
        edited.name = "renamed"
        // The raw comparison is exactly the old false positive…
        #expect(ACAppDelegate.restartRequiringChangeKinds(from: running, to: edited)
                    .contains(.additionalTools))
        // …while comparing like with like reports nothing.
        #expect(diff(running, edited, s).isEmpty)
    }

    @Test("Overlay is idempotent, so a raw running profile compares the same")
    func idempotentOverlay() {
        let s = globalSettings()
        let stored = Profile(name: "ws", tool: .codex, authMode: .token, apiKey: nil)
        #expect(stored.overlaidWithGlobalModels(s).overlaidWithGlobalModels(s)
                    == stored.overlaidWithGlobalModels(s))
        #expect(diff(stored, stored, s).isEmpty)
    }

    @Test("A genuine tool change still prompts")
    func genuineChanges() {
        let s = globalSettings()
        let stored = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        let running = stored.overlaidWithGlobalModels(s)
        var switched = stored
        switched.tool = .codex
        #expect(diff(running, switched, s).contains(.primaryTool))

        // Without global settings the profile's own agent list is what stages.
        let empty = ModelSettings()
        var added = stored
        added.additionalTools = [Profile.ToolSpec(tool: .codex)]
        #expect(diff(stored, added, empty) == [.additionalTools])

        var bigger = stored
        bigger.memoryGB = stored.memoryGB + 2
        #expect(diff(running, bigger, s) == [.memory])
    }

    @Test("Putting a setting back to what the VM booted with doesn't prompt")
    func revertToBootValue() {
        var booted = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: nil)
        booted.memoryGB = 4
        var bumped = booted
        bumped.memoryGB = 6
        // 4 → 6 on a VM booted with 4: restart.
        #expect(ACAppDelegate.restartChangesToPrompt(previous: booted, new: bumped, booted: booted) == [.memory])
        // 6 → 4 again: the VM already runs with 4.
        #expect(ACAppDelegate.restartChangesToPrompt(previous: bumped, new: booted, booted: booted).isEmpty)
        // Restart declined, then an unrelated rename: not asked again.
        var renamed = bumped
        renamed.name = "renamed"
        #expect(ACAppDelegate.restartChangesToPrompt(previous: bumped, new: renamed, booted: booted).isEmpty)
        // No boot record: the plain diff.
        #expect(ACAppDelegate.restartChangesToPrompt(previous: bumped, new: booted, booted: nil) == [.memory])
    }
}
