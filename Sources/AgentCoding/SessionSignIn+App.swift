import Foundation

/// The macOS app's proxy sign-in host: its MITM engine's stores and capture
/// registry (SessionSignIn.swift has the flow).
extension ACAppDelegate: ProxySignInHost {
    var proxySignInBackend: ProxySignInBackend? {
        guard let engine = mitmEngine else { return nil }
        return ProxySignInBackend(captures: engine.signInCaptures,
                                  claude: engine.claudeSubscriptionStore,
                                  codex: engine.codexSubscriptionStore,
                                  grok: engine.grokSubscriptionStore,
                                  kimi: engine.kimiSubscriptionStore)
    }
}
