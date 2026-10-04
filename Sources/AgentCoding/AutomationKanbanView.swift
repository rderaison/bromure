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
    /// Off when the board is a tab of the Automations hub (it has its own).
    var showsHeader = true

    /// Done-column paging: recent runs come from the store; older ones load
    /// from the on-disk archive on demand.
    @State private var doneLimit = 30
    @State private var archived: [AutomationRunRecord]?
    /// Compact = iPhone portrait → columns stack in one vertical scroll.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        content
        // iOS shows this board inside a NavigationStack — its bar carries the
        // title, so the in-board header would repeat it. One title, with the
        // icon, at the top (see CodingKanbanView for the same trade).
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // .titleAndIcon is not the default in a navigation bar — a
                    // bare Label renders icon-only there.
                    Label(NSLocalizedString("Automations", comment: "kanban title"),
                          systemImage: "bolt.badge.clock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                }
            }
        #endif
    }

    @ViewBuilder private var content: some View {
        if store.automations.isEmpty {
            ContentUnavailableView {
                // As the hub's Runs tab the empty state is about runs; the
                // stand-alone board keeps the automations wording.
                Label(showsHeader
                      ? NSLocalizedString("No automations yet", comment: "")
                      : NSLocalizedString("No runs yet", comment: "automation runs tab"),
                      systemImage: "bolt.badge.clock")
            } description: {
                Text(showsHeader
                     ? NSLocalizedString(
                        "Automations are recurring, unattended agent runs. Their runs will flow across this board.",
                        comment: "")
                     : NSLocalizedString(
                        "Each time an automation fires, its run shows up here — scheduled, in progress, then done. Create an automation to get started.",
                        comment: "automation runs tab"))
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
            #if os(macOS)
            if showsHeader {
                header
                Divider()
            }
            #endif
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
                // Same horizontally-panning board as the coding kanban: the
                // columns may not fit side by side (iPad portrait, a narrow
                // Mac window) — scroll rather than spill over the sidebar.
                GeometryReader { geo in
                    let n = cols.needsAttention.isEmpty ? 3 : 4
                    let w = CodingKanbanView.columnWidth(count: n, available: geo.size.width)
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 14) {
                            scheduledColumn(cols).frame(width: w)
                            inProgressColumn(cols).frame(width: w)
                            if !cols.needsAttention.isEmpty {
                                attentionColumn(cols).frame(width: w)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            doneColumn(done).frame(width: w)
                        }
                        .animation(.easeInOut(duration: 0.2), value: cols.needsAttention.isEmpty)
                        .padding(14)
                    }
                }
            }
        }
        .background(BoardBackdrop(tints: [.orange, .pink, .blue]))
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
    /// One line under the title: what the column is for.
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    /// Compact = iPhone portrait: columns are stacked vertically in one board
    /// scroll, so a column is full-width and lays its cards out inline (no inner
    /// scroll / fixed height). macOS/iPad keep the side-by-side columns.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    /// The header's accent: the column tint, or a neutral grey.
    private var accent: Color { tint == .secondary ? Color.gray : tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The heading floats as a glass pill; the cards sit on the
            // board's wash underneath — no grey wells.
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent.gradient))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // Shrink a little before truncating ("Waiting
                            // for your revi…"); the whole line on hover.
                            .minimumScaleFactor(0.8)
                            .help(subtitle)
                    }
                }
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(count > 0 ? accent : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(count > 0 ? 0.14 : 0.06)))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .modifier(GlassCapsule(cornerRadius: 14))
            if compact {
                cards   // inline — the whole board scrolls
            } else {
                ScrollView(showsIndicators: false) { cards }
                    .scrollClipDisabled()
            }
        }
        .padding(.horizontal, 2)
        .frame(minWidth: compact ? nil : 210, maxWidth: compact ? .infinity : 420,
               maxHeight: compact ? nil : .infinity, alignment: .top)
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if count == 0 && !emptyText.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(accent.opacity(0.7))
                    Text(emptyText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(accent.opacity(0.25)))
            }
            content()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}

/// The primary action of a board header ("New Task", "New Automation").
/// `.glassProminent` lost its tint on the pale board backdrop, and on the
/// Mac `.borderedProminent` drops its fill in a window that isn't key — a
/// fat-client mirror beside the local window, a headless snapshot — leaving
/// the label's white "+" on a white button: plain text with a missing glyph.
/// So the Mac draws the fill itself, accent-colored whatever the window's
/// state (the same blue in the local window and in a mirror).
struct ProminentGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.buttonStyle(BoardPrimaryButtonStyle())
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

#if os(macOS)
/// An always-filled accent button (see `ProminentGlassButton`).
struct BoardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor))
                    .brightness(configuration.isPressed ? -0.08 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
#endif

/// Liquid Glass on macOS 26 (a thin material before, and off the Mac).
struct GlassCapsule: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// A card floating on a board's backdrop — the task board's look: solid,
/// softly shadowed, lifted a little under the pointer.
struct FloatingCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 12
    var hovering = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.platformControlBackground.opacity(scheme == .dark ? 0.85 : 0.96))
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.05),
                        radius: hovering ? 10 : 4, y: hovering ? 4 : 2))
    }
}

/// A board's backdrop: the window colour washed with a few soft tints, so
/// glass and cards have something to sit on.
struct BoardBackdrop: View {
    var tints: [Color] = [.blue, .purple, .teal]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let a = scheme == .dark ? 0.16 : 0.10
        ZStack {
            Color.platformWindowBackground
            if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.55, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: [
                    tints[0].opacity(a), .clear, tints[1].opacity(a * 0.8),
                    .clear, tints[2].opacity(a * 0.5), .clear,
                    tints[1].opacity(a * 0.6), .clear, tints[0].opacity(a * 0.7),
                ])
            } else {
                LinearGradient(colors: [tints[0].opacity(a), .clear, tints[1].opacity(a)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards

/// Shared card chrome: a raised surface that lifts on hover. A tint marks a
/// state (needs you, in review, attention) with a bar down the leading edge.
struct CardChrome: ViewModifier {
    var borderTint: Color = .clear
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 13)
            .padding(.leading, borderTint == .clear ? 0 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape
                    .fill(Color.platformControlBackground.opacity(scheme == .dark ? 0.85 : 0.96))
                    .shadow(color: .black.opacity(hovering ? 0.14 : 0.06),
                            radius: hovering ? 12 : 4, y: hovering ? 6 : 2))
            .overlay(alignment: .leading) {
                if borderTint != .clear {
                    // State as an inset capsule, not a hard edge.
                    Capsule()
                        .fill(borderTint.gradient)
                        .frame(width: 4)
                        .padding(.vertical, 10)
                        .padding(.leading, 6)
                }
            }
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.12 : 0.7),
                                        Color.primary.opacity(hovering ? 0.12 : 0.06)],
                               startPoint: .top, endPoint: .bottom)))
            .scaleEffect(hovering ? 1.012 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The workspace a card belongs to: its colour and name, as a small chip.
struct WorkspaceChip: View {
    let name: String
    let accentHex: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(hex: accentHex)).frame(width: 6, height: 6)
            Text(name.isEmpty ? "—" : name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
        }
        .help(name)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(hex: accentHex).opacity(0.1)))
    }
}

/// A short state label on a card ("Working", "Needs you", "Queued").
struct CardStatusPill: View {
    let text: String
    let tint: Color
    var spinning = false
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if spinning {
                ProgressView().controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
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
