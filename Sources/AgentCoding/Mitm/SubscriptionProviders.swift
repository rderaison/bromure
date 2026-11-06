import Foundation

/// A static provider the proxies read on their connections' threads while
/// `MitmEngine.register` replaces it (at every session's start, on the main
/// thread): under a lock. Unlocked, a read in the middle of a replace could
/// take the closure being released, and free it a second time.
final class LockedProvider<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init() {}

    var current: Value? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What the intercepting proxy reaches on the host for the agents' sign-ins:
/// the subscription stores and refreshers, a sign-in being captured, the
/// credential minter. Set once by MitmEngine.register (HTTPMitmConnection
/// keeps its old names for them); read by every proxy that swaps a
/// workspace's stand-in credentials, on macOS and on the Linux server.
/// Each is replaced at every session's start while other sessions'
/// connections read it, so each is behind a lock (LockedProvider).
enum SubscriptionProviders {
    /// The engine's `CredentialMinter`: rewrites the responses of calls
    /// that issue a credential (`CredentialMint`).
    static var credentialMinter: (@Sendable () -> CredentialMinter?)? {
        get { credentialMinterSlot.current }
        set { credentialMinterSlot.current = newValue }
    }
    private static let credentialMinterSlot = LockedProvider<@Sendable () -> CredentialMinter?>()
    /// The host-owned Claude subscription store + refresher. nil →
    /// subscription auth off.
    static var claude: (@Sendable () -> (ClaudeSubscriptionStore, ClaudeSubscriptionRefresher)?)? {
        get { claudeSlot.current }
        set { claudeSlot.current = newValue }
    }
    private static let claudeSlot = LockedProvider<@Sendable () -> (ClaudeSubscriptionStore, ClaudeSubscriptionRefresher)?>()
    /// A sign-in the host is capturing for this workspace (SignInCapture.swift):
    /// the token exchange is answered by the host, not the provider.
    static var signInCapture: (@Sendable (UUID) -> SignInCapture?)? {
        get { signInCaptureSlot.current }
        set { signInCaptureSlot.current = newValue }
    }
    private static let signInCaptureSlot = LockedProvider<@Sendable (UUID) -> SignInCapture?>()
    /// Codex / ChatGPT counterpart of `claude`.
    static var codex: (@Sendable () -> (CodexSubscriptionStore, CodexSubscriptionRefresher)?)? {
        get { codexSlot.current }
        set { codexSlot.current = newValue }
    }
    private static let codexSlot = LockedProvider<@Sendable () -> (CodexSubscriptionStore, CodexSubscriptionRefresher)?>()
    /// Grok (xAI) counterpart of `claude`.
    static var grok: (@Sendable () -> (GrokSubscriptionStore, GrokSubscriptionRefresher)?)? {
        get { grokSlot.current }
        set { grokSlot.current = newValue }
    }
    private static let grokSlot = LockedProvider<@Sendable () -> (GrokSubscriptionStore, GrokSubscriptionRefresher)?>()
    /// Kimi (Moonshot) counterpart of `claude`.
    static var kimi: (@Sendable () -> (KimiSubscriptionStore, KimiSubscriptionRefresher)?)? {
        get { kimiSlot.current }
        set { kimiSlot.current = newValue }
    }
    private static let kimiSlot = LockedProvider<@Sendable () -> (KimiSubscriptionStore, KimiSubscriptionRefresher)?>()
}
