import Foundation
import Testing
@testable import bromure_ac

/// "Nous portal registration doesn't work over the fat client": a remote
/// Mac's New Workspace editor wired no sign-in at all, yet its Models pane
/// showed "Sign in with …" -- a button that did nothing.
@Suite("Remote sign-in from a new workspace")
struct RemoteNewWorkspaceSignInTests {
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the remote New Workspace editor signs every provider in, to the remote's shared account")
    func newEditorWired() throws {
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        let fn = try #require(fc.range(of: "private func presentNewWorkspaceEditor(draft: Profile, remoteGlobalModels: ModelSettings,"))
        let body = String(fc[fn.upperBound...].prefix(6000))
        // The host mints the new workspace's id: a draft-scoped login would
        // be stranded, so these go to the shared account (profileID nil).
        for p in [".claude", ".codex", ".grok", ".kimi", ".nous"] {
            #expect(body.contains("self?.beginRemoteRegistration(\(p), nil)"), "\(p)")
        }
        #expect(body.contains("onForgetNous: { [weak c] in c?.forgetRemoteSubscription(provider: \"hermes\", profileID: nil) }"))
        #expect(body.contains("nousAccountSavedAt: { [weak c] in c?.subscriptionStatus[\"hermes\"]?.registeredAt }"))
    }

    @Test("Sign in shows only where the editor wired it")
    func signInNeedsAHook() throws {
        let models = try Self.src("Sources/AgentCoding/Inference/ModelsSettingsView.swift")
        #expect(models.contains("hasCapture: provider.supportsSubscription && (subscription?.canRegister(provider) ?? false),"))
        let editor = try Self.src("Sources/AgentCoding/ProfileViews.swift")
        #expect(editor.contains("case .nous:      return onRegisterNous != nil"))
        // Hooks built without saying stay as before: sign-in offered.
        let hooks = ModelsSubscriptionHooks(savedAt: { _ in nil }, register: { _ in }, forget: { _ in }, fetchModels: nil)
        #expect(hooks.canRegister(.nous))
    }

    @Test("a remote sign-in says it's starting until its page opens or it ends")
    func progress() throws {
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        let open = try #require(fc.range(of: "        NSWorkspace.shared.open(url)\n#else\n        UIApplication.shared.open(url)\n#endif\n        onRegistrationPageOpened?()"))
        _ = open
        let begin = try #require(fc.range(of: "func beginRemoteRegistration(_ provider: SubscriptionProvider, _ profileID: Profile.ID?) {"))
        let body = String(fc[begin.upperBound...].prefix(2500))
        #expect(body.contains("RemoteSignInProgress.show("))
        #expect(body.contains("controller.onRegistrationPageOpened = { progress.close() }"))
        #expect(body.contains("{ [weak self] ok, message in\n            progress.close()"))
    }

    @Test("the progress text is in every locale")
    func localized() throws {
        let keys = ["Signing in to %@…",
                    "Starting a private sign-in machine on %@. The sign-in page opens in your browser when it's ready, usually within a minute.",
                    "Hide"]
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for loc in ["en", "de", "es", "fr", "ja", "pt", "zh-Hans", "zh-Hant"] {
            let url = top.appendingPathComponent("Sources/AgentCoding/\(loc).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(loc)")
            for k in keys { #expect(table[k] != nil, "\(loc): \(k)") }
        }
    }
}
