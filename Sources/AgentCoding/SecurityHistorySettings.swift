#if os(macOS)
import SwiftUI

/// Preferences › Tracing (this Mac's Preferences only): how long the Security
/// Timeline keeps its history on disk, and the time range the Security window
/// opens on. App-wide, like the subnet settings beside it.
struct SecurityHistorySettingsView: View {
    @AppStorage(SecurityTimeline.retentionKey, store: ACDefaults.standard) private var retentionDays = 90
    @AppStorage(SecurityTimeline.defaultRangeKey, store: ACDefaults.standard) private var rangeHours = 24

    private static let retentionChoices = [7, 30, 90, 180, 365, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Security history", systemImage: "shield.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("Keep events for")
                Spacer()
                Picker("Keep events for", selection: $retentionDays) {
                    ForEach(Self.retentionChoices, id: \.self) { d in
                        Text(d == 0 ? NSLocalizedString("Forever", comment: "security history retention")
                             : d == 365 ? NSLocalizedString("1 year", comment: "security history retention")
                             : String(format: NSLocalizedString("%d days", comment: "security history retention"), d))
                            .tag(d)
                    }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Text("Security window opens on")
                Spacer()
                Picker("Security window opens on", selection: $rangeHours) {
                    ForEach(SecurityTimeline.rangeChoices, id: \.self) { h in
                        Text(SecurityTimeline.rangeTitle(hours: h)).tag(h)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Text("Events older than this are deleted from this Mac. The window shows the newest 5,000.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: retentionDays) { _, _ in SecurityTimeline.shared.pruneNow() }
    }
}
#endif
