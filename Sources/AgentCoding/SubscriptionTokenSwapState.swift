import Foundation

/// Per-profile state of the Claude subscription-token swap consent.
///
/// `unset` is the default for new and pre-existing profiles — the
/// proxy will prompt on the first clean OAuth token it sees outbound to
/// anthropic.com. `accepted` means the user said yes once; the proxy
/// keeps fake↔real registered for this profile and the VM holds fakes.
/// `declined` means the user picked "Never for this profile" — no
/// further prompts, no agent interaction.
///
/// "Not now" (the other decline button on the consent sheet) is
/// represented by leaving the state at `.unset` — the next session for
/// this profile will prompt again.
public enum SubscriptionTokenSwapState: String, Codable, Sendable {
    case unset
    case accepted
    case declined
}
