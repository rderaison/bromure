import Foundation

/// What the intercepting proxy reaches on the host for the agents' sign-ins:
/// the subscription stores and refreshers, a sign-in being captured, the
/// credential minter. Set once by MitmEngine.register (HTTPMitmConnection
/// keeps its old names for them); read by every proxy that swaps a
/// workspace's stand-in credentials, on macOS and on the Linux server.
enum SubscriptionProviders {
    /// The engine's `CredentialMinter`: rewrites the responses of calls
    /// that issue a credential (`CredentialMint`).
    nonisolated(unsafe) static var credentialMinter: (@Sendable () -> CredentialMinter?)?
    /// The host-owned Claude subscription store + refresher. nil →
    /// subscription auth off.
    nonisolated(unsafe) static var claude: (@Sendable () -> (ClaudeSubscriptionStore, ClaudeSubscriptionRefresher)?)?
    /// A sign-in the host is capturing for this workspace (SignInCapture.swift):
    /// the token exchange is answered by the host, not the provider.
    nonisolated(unsafe) static var signInCapture: (@Sendable (UUID) -> SignInCapture?)?
    /// Codex / ChatGPT counterpart of `claude`.
    nonisolated(unsafe) static var codex: (@Sendable () -> (CodexSubscriptionStore, CodexSubscriptionRefresher)?)?
    /// Grok (xAI) counterpart of `claude`.
    nonisolated(unsafe) static var grok: (@Sendable () -> (GrokSubscriptionStore, GrokSubscriptionRefresher)?)?
    /// Kimi (Moonshot) counterpart of `claude`.
    nonisolated(unsafe) static var kimi: (@Sendable () -> (KimiSubscriptionStore, KimiSubscriptionRefresher)?)?
}
