import AppKit
import Foundation

// MARK: - Onboarding: provider sign-in from the Models step
//
// The wizard's Models board is the Preferences pane; its "Sign in with X"
// runs the same throwaway-machine registration Preferences uses, but QUIET:
// the machine's window never shows, and the wizard renders the chat's
// host-sign-in card instead (progress, then the outcome). For the CLIs whose
// browser hand-off doesn't reach the host's URL-open outbox (Codex, and the
// device-code flows of Grok / Kimi), the card also lifts the sign-in URL and
// device code off the hidden machine's tmux screen — so the user never has
// to look at a terminal, which is the whole point of the beautified view.

extension ACAppDelegate {

    /// Provider-keyed hooks over the SHARED subscription stores — what
    /// Preferences → Models gets, with `register` routed to the wizard card.
    @MainActor
    func wizardModelsHooks() -> ModelsSubscriptionHooks {
        ModelsSubscriptionHooks(
            savedAt: { [weak self] provider in
                guard let e = self?.mitmEngine else { return nil }
                switch provider {
                case .anthropic: return e.claudeSubscriptionStore.record(for: nil)?.savedAt
                case .openai:    return e.codexSubscriptionStore.record(for: nil)?.savedAt
                case .xai:       return e.grokSubscriptionStore.record(for: nil)?.savedAt
                case .moonshot:  return e.kimiSubscriptionStore.record(for: nil)?.savedAt
                case .zai, .bedrock, .openrouter, .custom: return nil
                }
            },
            register: { [weak self] provider in self?.beginWizardSignIn(provider: provider) },
            forget: { [weak self] provider in
                guard let e = self?.mitmEngine else { return }
                switch provider {
                case .anthropic: try? e.claudeSubscriptionStore.forget(for: nil)
                case .openai:    try? e.codexSubscriptionStore.forget(for: nil)
                case .xai:       try? e.grokSubscriptionStore.forget(for: nil)
                case .moonshot:  try? e.kimiSubscriptionStore.forget(for: nil)
                case .zai, .bedrock, .openrouter, .custom: return
                }
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            fetchModels: { provider, useSubscription, apiKey, completion in
                guard let tool = provider.fusionTool else {
                    ModelsSettingsView.fetchCompatibleModels(provider, apiKey: apiKey, completion: completion)
                    return
                }
                Task {
                    let m = await Fusion.listModels(provider: tool,
                                                    authMode: useSubscription ? .subscription : .token,
                                                    apiKey: apiKey, profileID: nil)
                    await MainActor.run { completion(m) }
                }
            },
            reauthAt: { [weak self] provider in
                guard let e = self?.mitmEngine else { return nil }
                switch provider {
                case .anthropic: return e.claudeSubscriptionStore.reauthRequiredAt(for: nil)
                case .openai:    return e.codexSubscriptionStore.reauthRequiredAt(for: nil)
                case .xai:       return e.grokSubscriptionStore.reauthRequiredAt(for: nil)
                case .moonshot:  return e.kimiSubscriptionStore.reauthRequiredAt(for: nil)
                case .zai, .bedrock, .openrouter, .custom: return nil
                }
            })
    }

    /// Start a quiet registration for `provider` and mirror its progress into
    /// the wizard's sign-in card.
    @MainActor
    func beginWizardSignIn(provider: ModelProvider) {
        guard let wizard = onboarding else { return }
        let sub: SubscriptionProvider
        switch provider {
        case .anthropic: sub = .claude
        case .openai:    sub = .codex
        case .xai:       sub = .grok
        case .moonshot:  sub = .kimi
        case .zai, .bedrock, .openrouter, .custom: return
        }
        wizard.signIn = OnboardingWizardModel.SignIn(
            provider: provider, providerName: sub.displayName,
            status: NSLocalizedString("Setting up a private sign-in machine…", comment: "sign-in"))

        beginSubscriptionRegistration(provider: sub, scope: .alwaysShared, quiet: true) { [weak self] event in
            Task { @MainActor in
                guard let self, let wizard = self.onboarding,
                      wizard.signIn?.provider == provider else { return }
                switch event {
                case .status(let text):
                    wizard.signIn?.status = text
                case .finished(let success, let message):
                    wizard.signIn?.status = nil
                    if success {
                        wizard.signIn?.succeeded = true
                        wizard.signIn?.error = nil
                        self.markProviderSubscribed(provider)
                        NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                    } else {
                        // Cancelled from the card: it's already gone.
                        guard wizard.signIn?.succeeded != true else { return }
                        wizard.signIn?.error = message ?? NSLocalizedString(
                            "The sign-in didn't complete.", comment: "sign-in")
                    }
                }
            }
        }
        watchWizardSignInScreen(provider: provider)
    }

    /// Abandon the wizard's sign-in: drop the card, destroy the hidden machine.
    @MainActor
    func cancelWizardSignIn() {
        onboarding?.signIn = nil
        if claudeRegistration != nil { teardownClaudeRegistration(reason: .cancelled) }
    }

    /// Poll the hidden machine's screen while the sign-in is mid-flight and
    /// surface the sign-in URL / device code on the card. Claude's flow opens
    /// the browser on its own (the URL reaches `onURLOpen`); the others print
    /// it and wait, so this is how the user gets to it without a terminal.
    @MainActor
    private func watchWizardSignInScreen(provider: ModelProvider) {
        Task { @MainActor [weak self] in
            while let self, let wizard = self.onboarding,
                  let s = wizard.signIn, s.provider == provider,
                  !s.succeeded, s.error == nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let state = self.claudeRegistration, !state.finished else { continue }
                let pid = state.scratchProfile.id
                guard let screen = try? await self.guestExec(
                    profileID: pid, command: "tmux capture-pane -p -J -t bromure 2>/dev/null",
                    timeout: 8) else { continue }
                guard let wizard = self.onboarding, wizard.signIn?.provider == provider else { return }
                if let url = TerminalPrompt.detect(inScreen: screen)?.authURL
                    ?? Self.signInURL(inScreen: screen) {
                    if wizard.signIn?.authURL != url { wizard.signIn?.authURL = url }
                }
                if let code = Self.deviceCode(inScreen: screen), wizard.signIn?.deviceCode != code {
                    wizard.signIn?.deviceCode = code
                }
            }
        }
    }

    /// The first https URL on the screen that looks like a sign-in hand-off
    /// (Codex's auth page, Grok's / Kimi's device pages) — `TerminalPrompt`
    /// only recognizes the `/oauth/authorize` shape.
    static func signInURL(inScreen screen: String) -> String? {
        for line in screen.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: "https://") else { continue }
            let url = String(line[r.lowerBound...])
                .split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
            let low = url.lowercased()
            if low.contains("/oauth") || low.contains("/device") || low.contains("/activate")
                || low.contains("/login") || low.contains("auth.") {
                return url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
            }
        }
        return nil
    }

    /// A device code the CLI asks the user to type into the browser
    /// (`ABCD-EFGH` style). Only meaningful once a sign-in URL is on screen.
    static func deviceCode(inScreen screen: String) -> String? {
        let pattern = #"\b[A-Z0-9]{4}-[A-Z0-9]{4,6}\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in screen.split(whereSeparator: \.isNewline) {
            // Skip URL lines: their query strings can carry look-alike tokens.
            if line.contains("https://") { continue }
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
                return String(s[r])
            }
        }
        return nil
    }
}
