import SwiftUI

// "Rewind home…" on a machine. A checkpoint of the home image is taken at
// each boot (the last few boots, then one a day for a week, then one a week
// for a month); this sheet lists them and rolls the home back to one. The
// machine has to be off — the image is swapped whole — and the current home
// is checkpointed first, so a rewind can itself be undone from the same
// list. Both windows show it: the local one over its store, the fat client
// over the server's checkpoint API.

struct HomeRewindSheet: View {
    let name: String
    /// The machine is up (or coming up) — a rewind waits for it to be off.
    let isRunning: () -> Bool
    let list: () async -> [HomeCheckpoint]
    /// nil = rewound; else why not.
    let rewind: (String) async -> String?
    let shutdown: () -> Void
    let onClose: () -> Void

    @State private var checkpoints: [HomeCheckpoint]?
    @State private var selected: String?
    @State private var running = false
    @State private var busy = false
    @State private var error: String?
    @State private var rewoundTo: HomeCheckpoint?

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("Rewind “%@”’s home", comment: "rewind home"), name))
                    .font(.system(size: 15, weight: .semibold))
                Text(NSLocalizedString("Each point is the home folder as it was when that boot started. The next start boots from the one you pick; the home as it is now is kept as a new point, so this can be undone here.", comment: "rewind home"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rewoundTo {
                Label {
                    Text(String(format: NSLocalizedString("Done — the next start of “%@” boots from its home of %@.", comment: "rewind home"),
                                name, rewoundTo.createdAt.formatted(date: .abbreviated, time: .shortened)))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.system(size: 12.5))
            } else {
                content
                if running {
                    HStack(spacing: 8) {
                        Image(systemName: "power").foregroundStyle(.secondary)
                        Text(NSLocalizedString("The machine is running — its home can't be swapped while it's in use. Shut it down first.", comment: "rewind home"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(NSLocalizedString("Shut down", comment: "rewind home")) { shutdown() }
                            .controlSize(.small)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if rewoundTo != nil {
                    Button(NSLocalizedString("OK", comment: "")) { onClose() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(NSLocalizedString("Cancel", comment: "")) { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await doRewind() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) }
                        else { Text(NSLocalizedString("Rewind", comment: "rewind home")) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || running || busy)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await refresh() }
        // The machine may be shutting down under the sheet: keep the notice
        // and the button honest.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = isRunning()
                if now != running { running = now }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let checkpoints {
            if checkpoints.isEmpty {
                Text(NSLocalizedString("No rollback points yet — one is taken each time this machine starts.", comment: "rewind home"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                List(checkpoints, selection: $selected) { cp in
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cp.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12.5, weight: .medium))
                            Text(Self.relative.localizedString(for: cp.createdAt, relativeTo: Date()))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cp.allocatedBytes, countStyle: .file))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(cp.id)
                }
                .listStyle(.inset)
                .frame(height: min(260, CGFloat(checkpoints.count) * 40 + 12))
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        }
    }

    private func refresh() async {
        running = isRunning()
        let items = await list()
        checkpoints = items
        if selected == nil { selected = items.first?.id }
    }

    private func doRewind() async {
        guard let id = selected, let cp = checkpoints?.first(where: { $0.id == id }), !busy else { return }
        busy = true
        error = nil
        let why = await rewind(id)
        busy = false
        if let why { error = why } else { rewoundTo = cp }
    }
}
