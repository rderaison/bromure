import SwiftUI

/// Where a session's Squelch numbers come from: the host's own ledger here,
/// or what the host sent with the session (a fat client).
enum SquelchHome {
    static func tally(for s: AgentSession) -> SquelchTally? {
        if let t = s.squelch { return t }
        #if os(macOS)
        if let tid = s.agentTranscriptID { return SquelchLedger.shared.conversation(s.profileID, tid) }
        #endif
        return nil
    }

    static let explanation = NSLocalizedString(
        "Trims passing tests, progress bars and repeated lines out of command output before the model reads it. Errors and warnings stay.",
        comment: "Squelch: what it does")
    static let tokenNote = NSLocalizedString(
        "Tokens are estimated as characters ÷ 4.",
        comment: "Squelch: how tokens are counted")
}

/// The header popover: the machine's switch, this conversation's savings,
/// the machine's, and the commands they came from.
struct SquelchPopover: View {
    let machine: String
    let enabled: Bool
    let session: SquelchTally?
    let summary: SquelchSummary?
    /// nil: shown, not changeable from here.
    let setEnabled: ((Bool) -> Void)?
    @State private var on: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(NSLocalizedString("Squelch", comment: "Squelch: feature name"),
                      systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let setEnabled {
                    Toggle(isOn: Binding(get: { on ?? enabled }, set: { on = $0; setEnabled($0) })) { EmptyView() }
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(String(format: NSLocalizedString("Trim command output on “%@”", comment: "Squelch: the switch"), machine))
                }
            }
            Text(SquelchHome.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !(on ?? enabled) {
                Text(String(format: NSLocalizedString("Off on “%@”: its agents' models read every command's output as printed.", comment: "Squelch: off"), machine))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let session, !session.isEmpty {
                SquelchTallyRow(title: NSLocalizedString("This conversation", comment: "Squelch: the session's savings"), tally: session)
            }
            if let summary {
                SquelchTallyRow(title: String(format: NSLocalizedString("All of “%@”", comment: "Squelch: the machine's savings"), machine),
                                tally: summary.total)
                if !summary.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Where it came from", comment: "Squelch: top commands"))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(summary.commands.prefix(6), id: \.name) { e in
                            HStack {
                                Text(e.name).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Text(String(format: NSLocalizedString("%@ tokens · %@", comment: "Squelch: one command's savings (tokens, share)"),
                                            SquelchFormat.tokens(e.tally.savedTokens), SquelchFormat.percent(e.tally.savedFraction)))
                                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if summary.days.contains(where: { $0.tally.savedTokens > 0 }) {
                    SquelchDaysChart(days: summary.days)
                }
            }
            Text(SquelchHome.tokenNote).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        // The popover hangs off the header's one-line meta row and would
        // inherit its lineLimit(1).
        .lineLimit(nil)
        .padding(16)
        .frame(width: 380)
        .onChange(of: enabled) { _, _ in on = nil }
    }
}

/// "~12.4K tokens saved — 38% of 32.6K · 41 outputs, 12 trimmed".
struct SquelchTallyRow: View {
    let title: String
    let tally: SquelchTally

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(String(format: NSLocalizedString("~%@ tokens saved", comment: "Squelch: tokens kept from the model"),
                        SquelchFormat.tokens(tally.savedTokens)))
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(String(format: NSLocalizedString("%@ of %@ tokens of command output · %d outputs, %d trimmed", comment: "Squelch: share, total, counts"),
                        SquelchFormat.percent(tally.savedFraction), SquelchFormat.tokens(tally.rawTokens),
                        tally.outputs, tally.trimmed))
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Tokens saved per day, the last two weeks.
struct SquelchDaysChart: View {
    let days: [SquelchSummary.Entry]

    var body: some View {
        let top = max(1, days.map(\.tally.savedTokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("Last two weeks", comment: "Squelch: daily chart"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.name) { d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d.tally.savedTokens > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: max(2, 36 * CGFloat(d.tally.savedTokens) / CGFloat(top)))
                        .frame(maxWidth: .infinity)
                        .help(String(format: NSLocalizedString("%@: %@ tokens saved", comment: "Squelch: one day"),
                                     d.name, SquelchFormat.tokens(d.tally.savedTokens)))
                }
            }
            .frame(height: 36, alignment: .bottom)
        }
    }
}
