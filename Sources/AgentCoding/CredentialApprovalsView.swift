import SwiftUI
import AppKit

/// Window contents for "Window → Credential Approvals…". Lists every
/// live consent grant the user has issued in this app run, with a
/// per-row Revoke button and a global "Revoke all" reset.
///
/// Grants are ephemeral: 5-min / 1-hr / session-scope variants all live
/// only in the broker's in-memory state, so this view's list shrinks
/// naturally as the clock ticks. Auto-refreshes every 2 s.
struct CredentialApprovalsView: View {
    let broker: ConsentBroker
    /// profileID → display name. Snapshotted once on appear; the
    /// broker doesn't carry a name → ID map externally.
    let profileNames: [UUID: String]
    var onClose: () -> Void

    @State private var entries: [ConsentBroker.LiveEntry] = []
    @State private var loaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(NSLocalizedString("Credential Approvals", comment: ""))
                    .font(.title3.bold())
                Spacer()
                if !entries.isEmpty {
                    Button(NSLocalizedString("Revoke all", comment: "")) {
                        Task {
                            await broker.revokeEverything()
                            await reload()
                        }
                    }
                    .keyboardShortcut(.delete, modifiers: [.command])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            if !loaded {
                placeholder(NSLocalizedString("Loading…", comment: ""))
            } else if entries.isEmpty {
                placeholder(NSLocalizedString(
                    "No active credential approvals. They appear here after you allow a gated credential.",
                    comment: ""))
            } else {
                List {
                    ForEach(entries.indices, id: \.self) { idx in
                        row(for: entries[idx])
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 540, minHeight: 320)
        .task {
            await reload()
            loaded = true
            // Auto-refresh while the window stays open. 2 s is plenty;
            // grants don't churn faster than that.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await reload()
            }
        }
        .onDisappear { onClose() }
    }

    @ViewBuilder
    private func row(for entry: ConsentBroker.LiveEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.grant.isSessionScoped
                  ? "infinity.circle.fill"
                  : "clock.fill")
                .foregroundStyle(entry.grant.isSessionScoped ? .blue : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.grant.credentialDisplayName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(profileNames[entry.profileID] ?? "(unknown profile)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(remainingLabel(for: entry.grant))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(NSLocalizedString("Revoke", comment: "")) {
                let pid = entry.profileID
                let cid = entry.credentialID
                Task {
                    await broker.revoke(profileID: pid, credentialID: cid)
                    await reload()
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func remainingLabel(for grant: ConsentBroker.Grant) -> String {
        if grant.isSessionScoped {
            return NSLocalizedString("rest of session", comment: "")
        }
        let secs = max(0, Int(grant.expiration.timeIntervalSinceNow))
        if secs >= 60 {
            let mins = (secs + 30) / 60
            return String(format: NSLocalizedString(
                "%d min remaining", comment: ""), mins)
        }
        return String(format: NSLocalizedString(
            "%d sec remaining", comment: ""), secs)
    }

    private func reload() async {
        let snap = await broker.snapshot()
        await MainActor.run { self.entries = snap }
    }
}
