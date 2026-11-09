import Foundation

/// What Fusion (shared) reads off macOS's proxy connection type: the
/// subscription providers, which forward to SubscriptionProviders there too.
// @port-skip linux-only: stand-in for HTTPMitmConnection's subscription-provider forwards (the Linux proxy is MitmProxy)
enum HTTPMitmConnection {
    // @port-skip linux-only: see the type
    static var claudeSubscriptionProvider: (@Sendable () -> (ClaudeSubscriptionStore, ClaudeSubscriptionRefresher)?)? {
        SubscriptionProviders.claude
    }
    // @port-skip linux-only: see the type
    static var codexSubscriptionProvider: (@Sendable () -> (CodexSubscriptionStore, CodexSubscriptionRefresher)?)? {
        SubscriptionProviders.codex
    }
    // @port-skip linux-only: see the type
    static var grokSubscriptionProvider: (@Sendable () -> (GrokSubscriptionStore, GrokSubscriptionRefresher)?)? {
        SubscriptionProviders.grok
    }
    // @port-skip linux-only: see the type
    static var kimiSubscriptionProvider: (@Sendable () -> (KimiSubscriptionStore, KimiSubscriptionRefresher)?)? {
        SubscriptionProviders.kimi
    }
    // @port-skip linux-only: see the type
    static func reasonPhrase(_ code: Int) -> String { ProxyPolicy.reasonPhrase(code) }
}

/// The guest-facing stream Fusion writes its reply to (macOS: the
/// connection's TLS stream): here the reply is collected, and the Linux
/// request chain answers the guest with it.
// @port-skip linux-only: stand-in for MitmServerStream's write, the one Fusion uses
protocol MitmServerStream: AnyObject {
    func write(_ data: Data) throws
}

// @port-skip linux-only: see MitmServerStream
final class CollectedReply: MitmServerStream, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    // @port-skip linux-only: see MitmServerStream
    func write(_ data: Data) throws { lock.lock(); bytes.append(data); lock.unlock() }
    // @port-skip linux-only: see the type
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
