import SwiftUI

/// User-facing consent dialog for the Claude subscription-token swap.
/// Three buttons:
///   • Swap  → "Yes, swap them now and keep the real values on this Mac"
///   • Not now → "Don't swap right now, but ask me again next session"
///   • Never  → "Don't ever ask again for this profile"
///
/// The wording leans on what the proxy already does for API keys
/// (real on host, fake in VM, swap on the wire) so the user has a
/// mental model to anchor the new behavior to.
struct SubscriptionTokenSwapSheet: View {
    /// Provider-specific label used in the title ("Claude", "Codex").
    let providerLabel: String
    /// Outbound host shown in the body ("anthropic.com", "chatgpt.com").
    let outboundHost: String
    let profileName: String
    let onDecision: (Decision) -> Void

    enum Decision {
        case swap
        case notNow
        case never
    }

    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: NSLocalizedString(
                    "Swap %@ subscription token?",
                    comment: "Subscription-token swap sheet title"), providerLabel))
                    .font(.title2).bold()
                Text(String(format: NSLocalizedString(
                    "Bromure detected a real %@ subscription token going out to %@ from “%@”. We can replace it inside the VM with a fake — the real token stays on this Mac and the proxy substitutes it on the wire only when needed.",
                    comment: "Subscription-token swap sheet body"),
                    providerLabel, outboundHost, profileName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(NSLocalizedString("Both the access and refresh tokens are swapped together.",
                                        comment: ""),
                      systemImage: "arrow.left.arrow.right")
                    .font(.callout)
                Label(NSLocalizedString("The VM never receives any real credential — only the fake replacements.",
                                        comment: ""),
                      systemImage: "lock.shield")
                    .font(.callout)
            }
            .foregroundStyle(.primary)

            HStack {
                Button(NSLocalizedString("Never for this profile",
                                         comment: "Subscription-token swap — permanent decline")) {
                    onDecision(.never)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(NSLocalizedString("Not now",
                                         comment: "Subscription-token swap — defer this session")) {
                    onDecision(.notNow)
                }
                Button {
                    inFlight = true
                    onDecision(.swap)
                } label: {
                    if inFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString("Swap",
                                               comment: "Subscription-token swap — accept"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inFlight)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}
