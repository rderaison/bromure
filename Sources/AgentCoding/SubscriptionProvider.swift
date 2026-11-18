import Foundation

/// The agents whose subscription sign-in Bromure keeps on the host.
public enum SubscriptionProvider: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case kimi
    /// Nous Portal, signed in through Hermes Agent (its only agent). The raw
    /// value is the TOOL's, like every other case's: a session's tool names
    /// its sign-in (`SubscriptionProvider(rawValue: tool.rawValue)`), and the
    /// `/state` subscription map is keyed by tool.
    case nous = "hermes"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "ChatGPT"
        case .grok:   return "Grok"
        case .kimi:   return "Kimi"
        case .nous:   return "Nous Portal"
        }
    }
    var scratchTool: Profile.Tool {
        switch self {
        case .claude: return .claude
        case .codex:  return .codex
        case .grok:   return .grok
        case .kimi:   return .kimi
        case .nous:   return .hermes
        }
    }
    /// True for providers with no vsock token agent, whose credentials are
    /// read straight out of the (host-mounted) home dir instead.
    var capturesFromHomeDir: Bool {
        switch self {
        case .grok, .kimi, .nous: return true
        case .claude, .codex: return false
        }
    }
    var scratchName: String { "Register with \(displayName)" }
}

/// Where captured tokens go.
public enum SubscriptionRegistrationScope: Sendable {
    /// From Preferences — store as the shared default, no prompt.
    case alwaysShared
    /// From a profile/session — ask "every session vs just this profile".
    case askPerSession(UUID)
}
