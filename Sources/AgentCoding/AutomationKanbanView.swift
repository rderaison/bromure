import SwiftUI

// MARK: - Column classification

/// Pure column logic for the automation board, separated from the views for
/// testability. An automation card never leaves Scheduled — a fire SPAWNS a
/// run card that flows In Progress → Done (or Needs Attention).
enum AutomationBoard {
    struct Columns {
        /// Launched runs whose agent is still going (live tab, not stamped done).
        var inProgress: [AutomationRunRecord] = []
        /// Failed/blocked runs awaiting the user's dismissal. The column
        /// only exists while this is non-empty.
        var needsAttention: [AutomationRunRecord] = []
        /// Everything over: completed, ended (tab gone), skipped, and
        /// acknowledged failures.
        var done: [AutomationRunRecord] = []
    }

    /// `isLive` answers "does this launched run still have a live tab?" —
    /// the caller resolves it against the tab roster.
    static func classify(runs: [AutomationRunRecord],
                         isLive: (AutomationRunRecord) -> Bool) -> Columns {
        var out = Columns()
        for run in runs {
            switch run.outcome {
            case .launched where run.completedAt == nil && isLive(run):
                out.inProgress.append(run)
            case .failed, .blocked:
                if run.acknowledgedAt == nil {
                    out.needsAttention.append(run)
                } else {
                    out.done.append(run)
                }
            default:
                out.done.append(run)
            }
        }
        out.inProgress.sort { $0.firedAt > $1.firedAt }
        out.needsAttention.sort { $0.firedAt > $1.firedAt }
        out.done.sort { ($0.completedAt ?? $0.firedAt) > ($1.completedAt ?? $1.firedAt) }
        return out
    }

    /// Does a tab's worktree branch belong to a run's slug — exact, or with
    /// the guest's "-N" dedup suffix? (Same match the engine's completion
    /// path uses.)
    static func branchMatches(_ branch: String?, slug: String) -> Bool {
        guard let branch, branch.hasPrefix("wt/") else { return false }
        let part = String(branch.dropFirst(3))
        return part == slug || (part.hasPrefix(slug + "-")
            && Int(part.dropFirst(slug.count + 1)) != nil)
    }
}

// MARK: - Board view

/// The automation kanban, shown as a stage surface (same overlay slot
/// pattern as the Docker dashboard). Columns: Scheduled (the automations
/// themselves), In Progress (live runs), Needs Attention (unacknowledged
/// failures — only when non-empty), Done (every past run, ever).
struct AutomationKanbanView: View {
    struct Actions {
        var selectAutomation: (UUID) -> Void = { _ in }
        var newAutomation: () -> Void = {}
        var runNow: (UUID) -> Void = { _ in }
        var toggle: (UUID) -> Void = { _ in }
        var delete: (UUID) -> Void = { _ in }
        var openRun: (AutomationRunRecord) -> Void = { _ in }
        var acknowledge: (UUID) -> Void = { _ in }
    }

    var store: ScheduledAutomationStore
    @Bindable var model: SessionListModel
    let actions: Actions

    /// Done-column paging: recent runs come from the store; older ones load
    /// from the on-disk archive on demand.
    @State private var doneLimit = 30
    @State private var archived: [AutomationRunRecord]?
    /// Compact = iPhone portrait → columns stack in one vertical scroll.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        if store.automations.isEmpty {
            ContentUnavailableView {
                Label(NSLocalizedString("No automations yet", comment: ""),
                      systemImage: "bolt.badge.clock")
            } description: {
                Text(NSLocalizedString(
                    "Automations are recurring, unattended agent runs. Their runs will flow across this board.",
                    comment: ""))
            } actions: {
                Button(NSLocalizedString("New Automation…", comment: ""),
                       action: actions.newAutomation)
            }
        } else {
            board
        }
    }

    // MARK: Column data

    /// The live tab backing a launched run, if any — resolved through the
    /// sidebar's live tab models so status changes redraw the board.
    private func liveTab(for run: AutomationRunRecord) -> TabsModel.Tab? {
        guard run.outcome == .launched, let slug = run.branchSlug else { return nil }
        let pid = run.runProfileID
            ?? store.automation(run.automationID)?.profileID
        guard let pid,
              let entry = model.entries.first(where: { $0.id == pid }) else { return nil }
        return entry.model.tabs.first {
            AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
        }
    }

    private var columns: AutomationBoard.Columns {
        AutomationBoard.classify(runs: store.runs) { liveTab(for: $0) != nil }
    }

    /// Done + archived (deduped), newest first.
    private func doneRuns(_ columns: AutomationBoard.Columns) -> [AutomationRunRecord] {
        guard let archived else { return columns.done }
        var seen = Set(columns.done.map(\.id))
        return columns.done + archived.filter { seen.insert($0.id).inserted }
    }

    private func accentHex(for automationID: UUID) -> String {
        guard let a = store.automation(automationID) else { return "#888888" }
        return model.profileRows.first { $0.id == a.profileID }?.accentHex ?? "#888888"
    }

    private func automationName(_ id: UUID) -> String {
        let name = store.automation(id)?.name ?? ""
        return name.isEmpty ? NSLocalizedString("Untitled automation", comment: "") : name
    }

    // MARK: Layout

    private var board: some View {
        let cols = columns
        let done = doneRuns(cols)
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if compact {
                // Phone: one vertical scroll with the columns stacked.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        scheduledColumn(cols)
                        inProgressColumn(cols)
                        if !cols.needsAttention.isEmpty {
                            attentionColumn(cols)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        doneColumn(done)
                    }
                    .animation(.easeInOut(duration: 0.2), value: cols.needsAttention.isEmpty)
                    .padding(14)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    scheduledColumn(cols)
                    inProgressColumn(cols)
                    if !cols.needsAttention.isEmpty {
                        attentionColumn(cols)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    doneColumn(done)
                }
                .animation(.easeInOut(duration: 0.2), value: cols.needsAttention.isEmpty)
                .padding(14)
            }
        }
        .background(Color.platformWindowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.badge.clock.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Automations", comment: "kanban title"))
                .font(.system(size: 16, weight: .bold))
            Spacer()
            Button(action: actions.newAutomation) {
                Label(NSLocalizedString("New Automation", comment: ""),
                      systemImage: "plus")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func scheduledColumn(_ cols: AutomationBoard.Columns) -> some View {
        KanbanColumn(title: NSLocalizedString("Scheduled", comment: "kanban column"),
                     systemImage: "calendar",
                     count: store.automations.count) {
            ForEach(store.automations) { automation in
                ScheduledAutomationCard(
                    automation: automation,
                    accentHex: model.profileRows.first { $0.id == automation.profileID }?
                        .accentHex ?? "#888888",
                    workspaceName: model.profileRows.first { $0.id == automation.profileID }?
                        .name ?? "",
                    nextFire: store.nextFire(for: automation.id),
                    runningCount: cols.inProgress.filter { $0.automationID == automation.id }.count,
                    onSelect: { actions.selectAutomation(automation.id) },
                    onRunNow: { actions.runNow(automation.id) },
                    onToggle: { actions.toggle(automation.id) },
                    onDelete: { actions.delete(automation.id) })
            }
        }
    }

    private func inProgressColumn(_ cols: AutomationBoard.Columns) -> some View {
        KanbanColumn(title: NSLocalizedString("In Progress", comment: "kanban column"),
                     systemImage: "play.circle",
                     count: cols.inProgress.count,
                     emptyText: NSLocalizedString("Nothing running", comment: "kanban")) {
            ForEach(cols.inProgress) { run in
                InProgressRunCard(
                    run: run,
                    automationName: automationName(run.automationID),
                    accentHex: accentHex(for: run.automationID),
                    status: liveTab(for: run)?.agentStatus ?? .working,
                    onOpen: { actions.openRun(run) })
            }
        }
    }

    private func attentionColumn(_ cols: AutomationBoard.Columns) -> some View {
        KanbanColumn(title: NSLocalizedString("Needs Attention", comment: "kanban column"),
                     systemImage: "exclamationmark.triangle.fill",
                     count: cols.needsAttention.count,
                     tint: .orange) {
            ForEach(cols.needsAttention) { run in
                AttentionRunCard(
                    run: run,
                    automationName: automationName(run.automationID),
                    onOpen: { actions.openRun(run) },
                    onDismiss: { actions.acknowledge(run.id) },
                    onRunAgain: { actions.runNow(run.automationID) })
            }
        }
    }

    private func doneColumn(_ done: [AutomationRunRecord]) -> some View {
        KanbanColumn(title: NSLocalizedString("Done", comment: "kanban column"),
                     systemImage: "checkmark.circle",
                     count: done.count,
                     emptyText: NSLocalizedString("No runs yet", comment: "kanban")) {
            ForEach(done.prefix(doneLimit)) { run in
                DoneRunCard(
                    run: run,
                    automationName: automationName(run.automationID),
                    accentHex: accentHex(for: run.automationID),
                    onOpen: { actions.openRun(run) })
            }
            if done.count > doneLimit {
                Button(String(format: NSLocalizedString("Show more (%d)", comment: "kanban"),
                              done.count - doneLimit)) {
                    doneLimit += 50
                }
                .platformLinkButtonStyle()
                .font(.system(size: 11))
                .padding(.top, 2)
            }
            if archived == nil {
                Button(NSLocalizedString("Load older runs…", comment: "kanban")) {
                    archived = AutomationRunArchive.loadArchivedRuns()
                }
                .platformLinkButtonStyle()
                .font(.system(size: 11))
                .help(NSLocalizedString(
                    "Runs beyond the recent window are archived on disk — nothing is ever deleted.",
                    comment: ""))
            } else if archived?.isEmpty == true {
                Text(NSLocalizedString("No archived runs.", comment: "kanban"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Column container (shared with the coding board)

struct KanbanColumn<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    var tint: Color = .secondary
    var emptyText: String = ""
    @ViewBuilder let content: () -> Content
    /// Compact = iPhone portrait: columns are stacked vertically in one board
    /// scroll, so a column is full-width and lays its cards out inline (no inner
    /// scroll / fixed height). macOS/iPad keep the side-by-side columns.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if compact {
                cards   // inline — the whole board scrolls
            } else {
                ScrollView(showsIndicators: false) { cards }
            }
        }
        .padding(8)
        .frame(minWidth: compact ? nil : 210, maxWidth: compact ? .infinity : 400,
               maxHeight: compact ? nil : .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.035)))
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if count == 0 && !emptyText.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
            content()
        }
        .padding(2)
    }
}

// MARK: - Cards

/// Shared card chrome: rounded, hairline border, hover-highlight.
struct CardChrome: ViewModifier {
    var borderTint: Color = .clear
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.platformControlBackground
                    .opacity(hovering ? 1.0 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderTint == .clear
                              ? Color.primary.opacity(0.09)
                              : borderTint.opacity(0.55),
                              lineWidth: borderTint == .clear ? 1 : 1.5))
            .onHover { hovering = $0 }
    }
}

/// A Scheduled-column card: the automation itself. Firing never moves it —
/// it stays here and spawns run cards.
private struct ScheduledAutomationCard: View {
    let automation: ScheduledAutomation
    let accentHex: String
    let workspaceName: String
    let nextFire: Date?
    let runningCount: Int
    let onSelect: () -> Void
    let onRunNow: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: accentHex))
                        .frame(width: 8, height: 8)
                        .opacity(automation.enabled ? 1 : 0.4)
                    Text(automation.name.isEmpty
                         ? NSLocalizedString("Untitled automation", comment: "")
                         : automation.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if runningCount > 0 {
                        Text("\(runningCount)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.orange))
                            .help(NSLocalizedString("Runs in progress", comment: ""))
                    }
                }
                Text(scheduleSummary(automation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !automation.enabled {
                        Text(NSLocalizedString("Paused", comment: "kanban card"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    } else if let nextFire {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(String(format: NSLocalizedString("next %@", comment: "kanban card"),
                                    nextFire.formatted(date: .abbreviated, time: .shortened)))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome())
        .contextMenu {
            Button(NSLocalizedString("Run Now", comment: ""), action: onRunNow)
            Button(automation.enabled
                   ? NSLocalizedString("Pause", comment: "")
                   : NSLocalizedString("Resume", comment: ""), action: onToggle)
            Divider()
            Button(NSLocalizedString("Delete…", comment: ""), role: .destructive,
                   action: onDelete)
        }
    }
}

/// An In Progress card: one live run. Red-ringed when the agent needs the
/// user; clicking opens the run's own window (live terminal).
private struct InProgressRunCard: View {
    let run: AutomationRunRecord
    let automationName: String
    let accentHex: String
    let status: AgentStatus
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentStatusDot(status: status)
                    Text(automationName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(Color(hex: accentHex))
                        .frame(width: 7, height: 7)
                }
                if run.detail != run.branchSlug {
                    Text(run.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    RelativeTimeText(
                        format: NSLocalizedString("started %@", comment: "kanban card"),
                        date: run.firedAt)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if status == .needsInput {
                        Text(NSLocalizedString("Needs your input", comment: "kanban card"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: status == .needsInput ? .red : .clear))
        .help(NSLocalizedString("Open the run's live session", comment: ""))
    }
}

/// A Needs Attention card: a failed or blocked run, parked until dismissed.
private struct AttentionRunCard: View {
    let run: AutomationRunRecord
    let automationName: String
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onRunAgain: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: run.outcome.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(run.outcome.tint)
                    Text(automationName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text(run.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack {
                    RelativeTimeText(format: nil, date: run.firedAt)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button(NSLocalizedString("Dismiss", comment: "kanban card"),
                           action: onDismiss)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.system(size: 10.5))
                        .help(NSLocalizedString("Move this run to Done", comment: ""))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: .orange))
        .contextMenu {
            Button(NSLocalizedString("Run Again", comment: ""), action: onRunAgain)
            Button(NSLocalizedString("Dismiss", comment: ""), action: onDismiss)
        }
    }
}

/// A Done card: any ended run. Clicking opens the run window — transcript
/// when one was captured, outcome details otherwise.
private struct DoneRunCard: View {
    let run: AutomationRunRecord
    let automationName: String
    let accentHex: String
    let onOpen: () -> Void

    @State private var hasTranscript = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: run.outcome.glyph)
                        .font(.system(size: 10))
                        .foregroundStyle(run.outcome.tint)
                    Text(automationName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hasTranscript {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help(NSLocalizedString("Transcript available", comment: ""))
                    }
                    Circle()
                        .fill(Color(hex: accentHex))
                        .frame(width: 6, height: 6)
                }
                if run.detail != run.branchSlug, !run.detail.isEmpty {
                    Text(run.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text((run.completedAt ?? run.firedAt)
                    .formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome())
        .task(id: run.id) {
            hasTranscript = AutomationRunArchive.hasTranscript(run.id)
        }
    }
}
