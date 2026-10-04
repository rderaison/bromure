#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Automations hub
//
// The stage surface behind "Automations" (⇧⌘A, the sidebar, ⌘K): one full
// window for everything that runs unattended.
//
//   Automations — everything set up, by kind: scheduled runs, runs that react
//                 to GitHub / Linear events, and repository code reviews
//   Runs        — the run board (scheduled / in progress / attention / done)
//   Code Review — the repository watches' dashboard: Overview, Findings,
//                 Repositories
//
// "New" always offers the three kinds, each saying what will happen.

/// Hub navigation state, owned by the window so menu items, notifications
/// and the debug hooks can land on a tab or a finding.
@MainActor
@Observable
final class AutomationHubModel {
    enum Tab: String, CaseIterable, Identifiable {
        case automations, runs, security
        var id: String { rawValue }

        var title: String {
            switch self {
            case .automations: return NSLocalizedString("Automations", comment: "hub tab")
            case .runs:        return NSLocalizedString("Runs", comment: "hub tab")
            case .security:    return NSLocalizedString("Code Review", comment: "hub tab")
            }
        }
    }

    enum SecurityTab: String, CaseIterable, Identifiable {
        case overview, findings, repositories
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:     return NSLocalizedString("Overview", comment: "hub tab")
            case .findings:     return NSLocalizedString("Findings", comment: "hub tab")
            case .repositories: return NSLocalizedString("Repositories", comment: "hub tab")
            }
        }
    }

    enum StatusFilter: Hashable {
        case open, all
        case only(RepoFinding.Status)
    }

    var tab: Tab = .automations
    var securityTab: SecurityTab = .overview
    /// The "what do you want to automate?" sheet.
    var showingNewChooser = false
    var selectedFindingID: UUID?
    var search = ""
    var severityFilter: RepoFinding.Severity?
    var statusFilter: StatusFilter = .open
    var repoFilter: String?
    /// The watch editor sheet's draft (nil = closed).
    var editingWatch: WatchedRepo?
    var editingWatchIsNew = false
    /// Pipeline card: one repository, or all.
    var pipelineRepo: String?
    /// A short confirmation under the header ("Scan of … started").
    var flash: String?
    private var flashToken = 0

    func showFlash(_ text: String) {
        flashToken += 1
        let token = flashToken
        flash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flash = nil
        }
    }

    func showSecurity(_ section: SecurityTab) {
        tab = .security
        securityTab = section
    }

    func showFinding(_ id: UUID?) {
        showSecurity(.findings)
        if let id {
            selectedFindingID = id
            // A filter that hides it would make the jump look broken.
            statusFilter = .all
            severityFilter = nil
            repoFilter = nil
            search = ""
        }
    }

    /// A route by name (menu items, debug hooks): a tab, a security
    /// section, or the older names ("board", "overview", …).
    @discardableResult
    func go(_ name: String) -> Bool {
        if let t = Tab(rawValue: name) { tab = t; return true }
        if let s = SecurityTab(rawValue: name) { showSecurity(s); return true }
        if name == "board" { tab = .runs; return true }
        if name == "code-review" { tab = .security; return true }
        if name == "new" { tab = .automations; showingNewChooser = true; return true }
        return false
    }
}

/// A workspace as the watch editor needs it.
struct WatchWorkspaceChoice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tools: [Profile.Tool]
    var defaultTool: Profile.Tool
    var hasGitHubToken: Bool
    var askBeforeUseLabels: [String]
}

struct AutomationHubView: View {
    struct Actions {
        var board = AutomationKanbanView.Actions()
        /// A new automation of this trigger kind (the editor, preset).
        var newAutomation: (ScheduledAutomation.TriggerKind) -> Void = { _ in }
        var saveWatch: (WatchedRepo, _ scanNow: Bool) -> Void = { _, _ in }
        var deleteWatch: (UUID) -> Void = { _ in }
        var toggleWatch: (UUID) -> Void = { _ in }
        var scanNow: (UUID) -> Void = { _ in }
        var fix: (UUID) -> Void = { _ in }
        /// Ask a Switchboard (room nil = the global one) who should fix it.
        var routeToSwitchboard: ((UUID, UUID?) -> Void)?
        /// Rooms with a Switchboard to ask.
        var switchboardRooms: () -> [FindingRouting.Room] = { [] }
        var openTask: (UUID) -> Void = { _ in }
        var setStatus: (UUID, RepoFinding.Status, String?) -> Void = { _, _, _ in }
        var markDuplicate: (UUID, UUID) -> Void = { _, _ in }
        var deleteFinding: (UUID) -> Void = { _ in }
        var editWorkspace: (UUID) -> Void = { _ in }
        /// Repos the workspace's GitHub token can reach (the editor's picker).
        var fetchRepos: (UUID) async throws -> [String] = { _ in [] }
    }

    var automationStore: ScheduledAutomationStore
    var findingStore: FindingStore
    var taskStore: CodingTaskStore?
    @Bindable var model: SessionListModel
    @Bindable var hub: AutomationHubModel
    var workspaces: () -> [WatchWorkspaceChoice]
    var promptGuardInstalled: () -> Bool
    let actions: Actions

    /// The actions as the tabs get them: the ones that start work in the
    /// background confirm it under the header.
    private var tabActions: Actions {
        var a = actions
        let store = findingStore
        let hub = hub
        a.scanNow = { id in
            actions.scanNow(id)
            hub.showFlash(String(format: NSLocalizedString(
                "Full scan of %@ requested — it shows under Recent scans once the agent starts.",
                comment: "hub flash"), store.watch(id)?.repo ?? ""))
        }
        a.saveWatch = { w, scan in
            let isNew = hub.editingWatchIsNew
            actions.saveWatch(w, scan)
            guard isNew else { return }
            hub.showSecurity(.repositories)
            hub.showFlash(String(format: scan
                ? NSLocalizedString("Now watching %@ — the first full scan is starting.", comment: "hub flash")
                : NSLocalizedString("Now watching %@.", comment: "hub flash"), w.repo))
        }
        a.fix = { id in
            actions.fix(id)
            hub.showFlash(NSLocalizedString(
                "Fix started — an agent is working on it in its own branch. It moves to In review when it's ready.",
                comment: "hub flash"))
        }
        let run = actions.board.runNow
        let autos = automationStore
        a.board.runNow = { id in
            run(id)
            let n = autos.automation(id)?.name ?? ""
            hub.showFlash(String(format: NSLocalizedString(
                "“%@” is starting — follow it on the Runs tab.", comment: "hub flash"),
                n.isEmpty ? NSLocalizedString("Untitled automation", comment: "") : n))
        }
        return a
    }

    var body: some View {
        let actions = tabActions
        return VStack(spacing: 0) {
            // The task board's chrome: a floating glass bar over a tinted
            // backdrop, the content's cards floating on the same wash.
            VStack(spacing: 0) {
                header
                if hub.tab == .security && !findingStore.watches.isEmpty {
                    Divider().opacity(0.5).padding(.horizontal, 12)
                    securityBar
                }
            }
            .modifier(GlassCapsule(cornerRadius: 20))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            if let flash = hub.flash {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(flash).font(.system(size: 12))
                    Spacer()
                    Button { hub.flash = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch hub.tab {
                case .automations:
                    AutomationsHomeTab(automationStore: automationStore,
                                       findingStore: findingStore, model: model,
                                       hub: hub, actions: actions,
                                       onChoose: choose)
                case .runs:
                    AutomationKanbanView(store: automationStore, model: model,
                                         actions: actions.board, showsHeader: false)
                case .security:
                    if findingStore.watches.isEmpty {
                        HubSecurityWelcome(onNewWatch: newWatch)
                    } else {
                        switch hub.securityTab {
                        case .overview:
                            HubOverviewTab(automationStore: automationStore,
                                           findingStore: findingStore, model: model,
                                           hub: hub, actions: actions, onNewWatch: newWatch)
                        case .findings:
                            HubFindingsTab(automationStore: automationStore,
                                           findingStore: findingStore, taskStore: taskStore,
                                           model: model, hub: hub, actions: actions)
                        case .repositories:
                            HubRepositoriesTab(automationStore: automationStore,
                                               findingStore: findingStore, model: model,
                                               hub: hub, actions: actions, onNewWatch: newWatch)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BoardBackdrop())
        .animation(.easeInOut(duration: 0.2), value: hub.flash)
        .environment(\.findingRouting, FindingRouting(
            rooms: actions.switchboardRooms(),
            route: actions.routeToSwitchboard.map { route in
                { id, room in
                    route(id, room)
                    hub.showFlash(NSLocalizedString(
                        "Asked the Switchboard — it will propose a session and wait for your OK.",
                        comment: "hub flash"))
                }
            }))
        .sheet(item: $hub.editingWatch) { draft in
            WatchEditorSheet(
                draft: draft, isNew: hub.editingWatchIsNew,
                workspaces: workspaces(),
                promptGuardInstalled: promptGuardInstalled(),
                fetchRepos: actions.fetchRepos,
                onEditWorkspace: { id in
                    hub.editingWatch = nil
                    actions.editWorkspace(id)
                },
                onCancel: { hub.editingWatch = nil },
                onSave: { w, scan in
                    hub.editingWatch = nil
                    actions.saveWatch(w, scan)
                })
        }
        .sheet(isPresented: $hub.showingNewChooser) {
            NewAutomationChooser(
                onChoose: { kind in
                    hub.showingNewChooser = false
                    // Let the sheet go away before the next surface comes up.
                    DispatchQueue.main.async { choose(kind) }
                },
                onCancel: { hub.showingNewChooser = false })
        }
    }

    private func choose(_ kind: AutomationDescriber.Kind) {
        switch kind {
        case .scheduled: actions.newAutomation(.schedule)
        case .event:     actions.newAutomation(.githubPullRequest)
        case .security:  newWatch()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tint)
                Text(NSLocalizedString("Automations", comment: "hub title"))
                    .font(.system(size: 16, weight: .bold))
            }
            HubTabBar(selection: $hub.tab, tabs: AutomationHubModel.Tab.allCases,
                      title: \.title)
            Spacer(minLength: 8)
            Button {
                hub.showingNewChooser = true
            } label: {
                Label(NSLocalizedString("New Automation", comment: "hub"), systemImage: "plus")
            }
            .modifier(ProminentGlassButton())
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The Security tab's own navigation, with its scan action.
    private var securityBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $hub.securityTab) {
                ForEach(AutomationHubModel.SecurityTab.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Spacer()
            if let first = findingStore.watches.first, findingStore.watches.count == 1 {
                Button {
                    tabActions.scanNow(first.id)
                } label: {
                    Label(NSLocalizedString("Scan Now", comment: "watch"), systemImage: "play.fill")
                }
                .controlSize(.small)
                .help(String(format: NSLocalizedString("Run a full scan of %@ now", comment: ""), first.repo))
            } else {
                Menu {
                    ForEach(findingStore.watches) { w in
                        Button(w.repo) { tabActions.scanNow(w.id) }
                    }
                } label: {
                    Label(NSLocalizedString("Scan Now", comment: "watch"), systemImage: "play.fill")
                }
                .controlSize(.small)
                .fixedSize()
            }
            Button {
                newWatch()
            } label: {
                Label(NSLocalizedString("Watch a Repository…", comment: "hub welcome"), systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func newWatch() {
        let ws = workspaces()
        guard let first = ws.first(where: \.hasGitHubToken) ?? ws.first else { return }
        hub.editingWatchIsNew = true
        hub.editingWatch = WatchedRepo(repo: "", profileID: first.id, tool: first.defaultTool)
    }
}

// MARK: - Shared bits

/// The hub's tab switch: a capsule track with the selected tab raised and
/// evenly drawn separators between the others. (The system segmented
/// control drew a divider between some unselected segments but not others
/// on the board's translucent backdrop.)
struct HubTabBar<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: KeyPath<Tab, String>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                if i > 0 {
                    // A separator only between two unselected tabs.
                    Rectangle()
                        .fill(Color.primary.opacity(
                            selection == tab || selection == tabs[i - 1] ? 0 : 0.15))
                        .frame(width: 1, height: 14)
                }
                Button { selection = tab } label: {
                    Text(tab[keyPath: title])
                        .font(.system(size: 12.5, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(Color.platformControlBackground.opacity(scheme == .dark ? 0.9 : 1))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
        .animation(.easeInOut(duration: 0.15), value: selection)
    }
}

extension RepoFinding.Severity {
    var tint: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .yellow
        case .low:      return .blue
        case .info:     return .gray
        }
    }
}

extension RepoFinding.Status {
    var tint: Color {
        switch self {
        case .new:        return .secondary
        case .triaged:    return .gray
        case .inProgress: return .blue
        case .inReview:   return .purple
        case .fixed:      return .green
        case .duplicate, .dismissed: return .secondary
        }
    }
}

struct SeverityBadge: View {
    let severity: RepoFinding.Severity
    var compact = false

    var body: some View {
        Text(severity.displayName)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, 2)
            .foregroundStyle(severity == .medium ? Color.primary : severity.tint)
            .background(severity.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct FindingStatusPill: View {
    let status: RepoFinding.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.tint).frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// The rounded card every hub section sits in.
struct HubCard<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, trailing: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title).font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                    trailing
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FloatingCardBackground(cornerRadius: 12))
    }
}

private func relative(_ d: Date) -> String {
    d.formatted(.relative(presentation: .named))
}

// MARK: - Overview

struct HubOverviewTab: View {
    var automationStore: ScheduledAutomationStore
    var findingStore: FindingStore
    @Bindable var model: SessionListModel
    @Bindable var hub: AutomationHubModel
    let actions: AutomationHubView.Actions
    var onNewWatch: () -> Void

    private var liveRunIDs: Set<UUID> {
        var out = Set<UUID>()
        for run in automationStore.runs where run.outcome == .launched && run.completedAt == nil {
            guard let slug = run.branchSlug,
                  let pid = run.runProfileID ?? automationStore.automation(run.automationID)?.profileID,
                  let entry = model.entries.first(where: { $0.id == pid }) else { continue }
            if entry.model.tabs.contains(where: {
                AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
            }) { out.insert(run.id) }
        }
        return out
    }

    var body: some View {
        do {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tiles
                    HubPipelineCard(findings: findingStore.findings,
                                    repos: findingStore.watches.map(\.repo),
                                    selectedRepo: $hub.pipelineRepo)
                    attention
                    recentScans
                }
                .padding(16)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var tiles: some View {
        let stats = FindingStats(findingStore.findings)
        let columns = AutomationBoard.classify(runs: automationStore.runs) { liveRunIDs.contains($0.id) }
        let continuous = findingStore.watches.filter {
            $0.enabled && ($0.scans.contains(.commits) || $0.scans.contains(.pullRequests))
        }.count
        return HStack(spacing: 12) {
            HubStatTile(value: "\(findingStore.watches.count)",
                     label: NSLocalizedString("Watched repositories", comment: "hub tile"),
                     icon: "eye", tint: .accentColor,
                     detail: String(format: NSLocalizedString("%d scanning continuously", comment: "hub tile"),
                                    continuous)) {
                hub.showSecurity(.repositories)
            }
            HubStatTile(value: "\(stats.open)",
                     label: NSLocalizedString("Open findings", comment: "hub tile"),
                     icon: "exclamationmark.shield",
                     tint: (stats.openBySeverity[.critical] ?? 0) > 0 ? .red : .orange,
                     chips: [RepoFinding.Severity.critical, .high].compactMap { sev in
                         let n = stats.openBySeverity[sev] ?? 0
                         return n > 0 ? (severity: sev, count: n) : nil
                     }) {
                hub.statusFilter = .open
                hub.severityFilter = nil
                hub.showSecurity(.findings)
            }
            HubStatTile(value: "\(stats.fixedRecently)",
                     label: NSLocalizedString("Fixed in the last 30 days", comment: "hub tile"),
                     icon: "checkmark.shield", tint: .green) {
                hub.statusFilter = .only(.fixed)
                hub.showSecurity(.findings)
            }
            HubStatTile(value: "\(columns.inProgress.count)",
                     label: NSLocalizedString("Runs in progress", comment: "hub tile"),
                     icon: "play.circle", tint: .blue,
                     detail: columns.needsAttention.isEmpty ? nil
                        : String(format: NSLocalizedString("%d need attention", comment: "hub tile"),
                                 columns.needsAttention.count),
                     detailTint: .orange) {
                hub.tab = .runs
            }
        }
    }

    private var attention: some View {
        let open = findingStore.findings
            .filter { $0.status == .new || $0.status == .triaged }
            .sortedForTriage()
        let failed = AutomationBoard.classify(runs: automationStore.runs) { liveRunIDs.contains($0.id) }
            .needsAttention
        return HubCard(NSLocalizedString("Needs attention", comment: "hub section"),
                       trailing: open.count > 8 ? AnyView(
                        Button(String(format: NSLocalizedString("All %d", comment: "hub"), open.count)) {
                            hub.statusFilter = .open
                            hub.showSecurity(.findings)
                        }.platformLinkButtonStyle()) : nil) {
            if open.isEmpty && failed.isEmpty {
                Text(NSLocalizedString("Nothing needs you right now.", comment: "hub"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(open.prefix(8)) { f in
                        HubFindingRow(finding: f, workspace: workspaceName(f.profileID),
                                   onOpen: { hub.showFinding(f.id) },
                                   onFix: { actions.fix(f.id) },
                                   onStatus: { st, note in actions.setStatus(f.id, st, note) })
                        Divider()
                    }
                    ForEach(failed.prefix(5)) { run in
                        AttentionRunRow(run: run,
                                        automationName: automationStore.automation(run.automationID)?.name
                                            ?? NSLocalizedString("Deleted automation", comment: ""),
                                        onOpen: { actions.board.openRun(run) },
                                        onDismiss: { actions.board.acknowledge(run.id) })
                        Divider()
                    }
                }
            }
        }
    }

    private var recentScans: some View {
        let watchAutomationIDs = Set(findingStore.watches.flatMap { $0.automationIDs.values })
        let runs = automationStore.runs
            .filter { watchAutomationIDs.contains($0.automationID) && $0.outcome != .skipped }
            .prefix(8)
        return HubCard(NSLocalizedString("Recent scans", comment: "hub section")) {
            if runs.isEmpty {
                Text(NSLocalizedString("No scans yet — they appear here as the watches run.", comment: "hub"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runs)) { run in
                        ScanRunRow(run: run,
                                   automationName: automationStore.automation(run.automationID)?.name ?? "",
                                   live: liveRunIDs.contains(run.id),
                                   newCount: findingStore.findings(firstReportedBy: run.id).count,
                                   onOpen: { actions.board.openRun(run) })
                        Divider()
                    }
                }
            }
        }
    }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
}

/// One step of a "what happens" explanation.
struct HowStep: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

/// The three kinds of automation, each with what happens when you pick it.
struct AutomationKindCards: View {
    var onChoose: (AutomationDescriber.Kind) -> Void

    static func title(_ k: AutomationDescriber.Kind) -> String {
        switch k {
        case .scheduled: return NSLocalizedString("Scheduled", comment: "automation kind")
        case .event:     return NSLocalizedString("GitHub & Linear events", comment: "automation kind")
        case .security:  return NSLocalizedString("Code review", comment: "automation kind")
        }
    }

    static func icon(_ k: AutomationDescriber.Kind) -> String {
        switch k {
        case .scheduled: return "calendar.badge.clock"
        case .event:     return "arrow.triangle.pull"
        case .security:  return "doc.text.magnifyingglass"
        }
    }

    static func tint(_ k: AutomationDescriber.Kind) -> Color {
        switch k {
        case .scheduled: return .blue
        case .event:     return .purple
        case .security:  return .green
        }
    }

    static func tagline(_ k: AutomationDescriber.Kind) -> String {
        switch k {
        case .scheduled:
            return NSLocalizedString("Run an agent on a prompt, on a schedule.", comment: "automation kind")
        case .event:
            return NSLocalizedString("React when something happens on GitHub or Linear.", comment: "automation kind")
        case .security:
            return NSLocalizedString("Keep a GitHub repository continuously reviewed for vulnerabilities and bugs.", comment: "automation kind")
        }
    }

    static func steps(_ k: AutomationDescriber.Kind) -> [HowStep] {
        switch k {
        case .scheduled:
            return [
                HowStep(icon: "clock", text: NSLocalizedString("At the time you pick — every weekday at 9:00, hourly, weekly…", comment: "how it works")),
                HowStep(icon: "terminal", text: NSLocalizedString("An agent starts in one of your workspaces with your prompt, on a fresh branch", comment: "how it works")),
                HowStep(icon: "tray.full", text: NSLocalizedString("You find its result on the Runs tab: transcript and branch", comment: "how it works")),
            ]
        case .event:
            return [
                HowStep(icon: "bell", text: NSLocalizedString("When a pull request, issue or commit lands on GitHub, a Linear issue appears, or another automation finishes", comment: "how it works")),
                HowStep(icon: "terminal", text: NSLocalizedString("An agent picks up that item with your prompt — screened for prompt injection first", comment: "how it works")),
                HowStep(icon: "tray.full", text: NSLocalizedString("Each item runs once, on its own branch, listed on the Runs tab", comment: "how it works")),
            ]
        case .security:
            return [
                HowStep(icon: "magnifyingglass", text: NSLocalizedString("An agent reviews the whole repository weekly, and every new commit and pull request", comment: "how it works")),
                HowStep(icon: "list.bullet.rectangle", text: NSLocalizedString("Findings are collected and deduplicated across scans, by severity", comment: "how it works")),
                HowStep(icon: "wrench.and.screwdriver", text: NSLocalizedString("One click starts a fix on its own branch — you review before anything merges", comment: "how it works")),
            ]
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AutomationDescriber.Kind.allCases, id: \.self) { k in
                AutomationKindCard(kind: k, action: { onChoose(k) })
            }
        }
    }
}

private struct AutomationKindCard: View {
    let kind: AutomationDescriber.Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tint = AutomationKindCards.tint(kind)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: AutomationKindCards.icon(kind))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(AutomationKindCards.title(kind))
                        .font(.system(size: 15, weight: .semibold))
                    Text(AutomationKindCards.tagline(kind))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text(NSLocalizedString("What happens", comment: "automation kind"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(AutomationKindCards.steps(kind).enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(i + 1)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(tint)
                                .frame(width: 18, height: 18)
                                .background(tint.opacity(0.14), in: Circle())
                            Text(step.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 6)
                HStack {
                    Spacer()
                    Text(NSLocalizedString("Set Up", comment: "automation kind"))
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(hovering ? tint : .secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .modifier(FloatingCardBackground(cornerRadius: 14, hovering: hovering))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.55) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// "New Automation": pick the kind first, with what each one does.
struct NewAutomationChooser: View {
    var onChoose: (AutomationDescriber.Kind) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("What should run on its own?", comment: "new automation"))
                    .font(.system(size: 20, weight: .semibold))
                Text(NSLocalizedString(
                    "Every automation runs an agent unattended in one of your workspaces, under its credentials and guardrails.",
                    comment: "new automation"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            AutomationKindCards(onChoose: onChoose)
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 900)
    }
}

/// The Security tab before any repository is watched: what a scan does.
struct HubSecurityWelcome: View {
    var onNewWatch: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.green)
                VStack(spacing: 6) {
                    Text(NSLocalizedString("Continuous code review for your GitHub repositories",
                                           comment: "security welcome"))
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(NSLocalizedString(
                        "Scans run as automations in the workspace you choose, with its GitHub token. Nothing is changed in the repository until you start a fix and merge it.",
                        comment: "security welcome"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(AutomationKindCards.steps(.security).enumerated()), id: \.offset) { i, step in
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: step.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.green)
                            Text(String(format: NSLocalizedString("Step %d", comment: "security welcome"), i + 1))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            Text(step.text)
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .modifier(FloatingCardBackground(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: 820)
                Button(action: onNewWatch) {
                    Label(NSLocalizedString("Watch a Repository…", comment: "hub welcome"), systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct HubStatTile: View {
    let value: String
    let label: String
    var icon: String
    var tint: Color = .accentColor
    var detail: String?
    var detailTint: Color = .secondary
    var chips: [(severity: RepoFinding.Severity, count: Int)] = []
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    Spacer()
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(chips.indices, id: \.self) { i in
                        let sev = chips[i].severity
                        Text("\(chips[i].count) \(sev.displayName)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(sev.tint)
                            .background(sev.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(detailTint)
                    }
                }
                .frame(minHeight: 18, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .modifier(FloatingCardBackground(cornerRadius: 12, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Hover highlight for the hub's clickable rows.
struct HubRowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .padding(.horizontal, -8)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hubRowHover() -> some View { modifier(HubRowHover()) }
}

/// The remediation pipeline as a band: New → Backlog → In progress → In
/// review → Fixed, its width at each stage the number of findings there,
/// with the Duplicate / Dismissed branches noted underneath.
struct HubPipelineCard: View {
    let findings: [RepoFinding]
    let repos: [String]
    @Binding var selectedRepo: String?

    private var scoped: [RepoFinding] {
        guard let r = selectedRepo else { return findings }
        return findings.filter { $0.repo == r }
    }

    var body: some View {
        let stats = FindingStats(scoped)
        let stages = RepoFinding.Status.pipeline
        let counts = stages.map { stats.count($0) }
        HubCard(NSLocalizedString("Pipeline", comment: "hub section"),
                trailing: repos.count > 1 ? AnyView(
                    Picker("", selection: $selectedRepo) {
                        Text(NSLocalizedString("All repositories", comment: "hub")).tag(String?.none)
                        ForEach(repos, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()) : nil) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                        VStack(spacing: 2) {
                            Text(s.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("\(counts[i])")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                PipelineBand(counts: counts, colors: stages.map(\.bandColor))
                    .frame(height: 54)
                HStack(spacing: 16) {
                    Spacer()
                    Label(String(format: NSLocalizedString("%d duplicate", comment: "pipeline"),
                                 stats.count(.duplicate)), systemImage: "square.on.square")
                    Label(String(format: NSLocalizedString("%d dismissed", comment: "pipeline"),
                                 stats.count(.dismissed)), systemImage: "xmark.circle")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }
}

extension RepoFinding.Status {
    var bandColor: Color {
        switch self {
        case .new:        return Color.gray.opacity(0.45)
        case .triaged:    return Color.gray.opacity(0.7)
        case .inProgress: return Color.blue.opacity(0.75)
        case .inReview:   return Color.indigo.opacity(0.75)
        case .fixed:      return Color.green.opacity(0.75)
        default:          return Color.gray.opacity(0.3)
        }
    }
}

struct PipelineBand: View {
    let counts: [Int]
    let colors: [Color]

    var body: some View {
        Canvas { ctx, size in
            let n = counts.count
            guard n > 0 else { return }
            let maxCount = max(counts.max() ?? 0, 1)
            let colW = size.width / CGFloat(n)
            let mid = size.height / 2
            func h(_ c: Int) -> CGFloat {
                c == 0 ? 2 : 6 + (size.height - 6) * CGFloat(sqrt(Double(c) / Double(maxCount)))
            }
            let centers = (0..<n).map { (CGFloat($0) + 0.5) * colW }
            let heights = counts.map(h)
            // The band's outline: flat to the first center, eased between
            // centers, flat to the end.
            var band = Path()
            band.move(to: CGPoint(x: 0, y: mid - heights[0] / 2))
            band.addLine(to: CGPoint(x: centers[0], y: mid - heights[0] / 2))
            for i in 1..<n {
                let x0 = centers[i - 1], x1 = centers[i]
                let y0 = mid - heights[i - 1] / 2, y1 = mid - heights[i] / 2
                band.addCurve(to: CGPoint(x: x1, y: y1),
                              control1: CGPoint(x: (x0 + x1) / 2, y: y0),
                              control2: CGPoint(x: (x0 + x1) / 2, y: y1))
            }
            band.addLine(to: CGPoint(x: size.width, y: mid - heights[n - 1] / 2))
            band.addLine(to: CGPoint(x: size.width, y: mid + heights[n - 1] / 2))
            band.addLine(to: CGPoint(x: centers[n - 1], y: mid + heights[n - 1] / 2))
            for i in stride(from: n - 1, to: 0, by: -1) {
                let x0 = centers[i], x1 = centers[i - 1]
                let y0 = mid + heights[i] / 2, y1 = mid + heights[i - 1] / 2
                band.addCurve(to: CGPoint(x: x1, y: y1),
                              control1: CGPoint(x: (x0 + x1) / 2, y: y0),
                              control2: CGPoint(x: (x0 + x1) / 2, y: y1))
            }
            band.addLine(to: CGPoint(x: 0, y: mid + heights[0] / 2))
            band.closeSubpath()
            for i in 0..<n {
                ctx.drawLayer { layer in
                    layer.clip(to: Path(CGRect(x: CGFloat(i) * colW, y: 0,
                                               width: colW, height: size.height)))
                    layer.fill(band, with: .color(colors[i]))
                }
                if i > 0 {
                    var sep = Path()
                    sep.move(to: CGPoint(x: CGFloat(i) * colW, y: 0))
                    sep.addLine(to: CGPoint(x: CGFloat(i) * colW, y: size.height))
                    ctx.stroke(sep, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                }
            }
        }
        .accessibilityLabel(Text(NSLocalizedString("Findings pipeline", comment: "")))
    }
}

struct HubFindingRow: View {
    let finding: RepoFinding
    var workspace: String = ""
    var onOpen: () -> Void
    var onFix: () -> Void
    var onStatus: (RepoFinding.Status, String?) -> Void = { _, _ in }

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: finding.severity, compact: true)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text([finding.repo, finding.location].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FindingStatusPill(status: finding.status)
            Text(relative(finding.lastSeenAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .trailing)
            FixButton(finding: finding, onFix: onFix)
            FindingRowMenu(finding: finding, onStatus: onStatus)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hubRowHover()
        .onTapGesture(perform: onOpen)
        .contextMenu { FindingTriageItems(finding: finding, onStatus: onStatus, onOpen: onOpen) }
    }
}

/// Where "Ask the Switchboard" can send a finding: the global Switchboard
/// and each room's. Put in the environment at the hub's root.
struct FindingRouting {
    struct Room: Identifiable, Equatable {
        let id: UUID
        let name: String
        let colorHex: String
    }
    var rooms: [Room] = []
    /// (finding, room — nil = the global Switchboard). nil = unavailable.
    var route: ((UUID, UUID?) -> Void)?
}

private struct FindingRoutingKey: EnvironmentKey {
    static let defaultValue = FindingRouting()
}

extension EnvironmentValues {
    var findingRouting: FindingRouting {
        get { self[FindingRoutingKey.self] }
        set { self[FindingRoutingKey.self] = newValue }
    }
}

/// "Ask the Switchboard" / "Ask a room's Switchboard ▸" menu items.
struct SwitchboardRouteItems: View {
    let finding: RepoFinding
    @Environment(\.findingRouting) private var routing

    var body: some View {
        if let route = routing.route {
            Button {
                route(finding.id, nil)
            } label: {
                Label(NSLocalizedString("Ask the Switchboard Who Should Fix It", comment: "finding menu"),
                      systemImage: "person.2.wave.2")
            }
            if !routing.rooms.isEmpty {
                Menu {
                    ForEach(routing.rooms) { room in
                        Button(room.name) { route(finding.id, room.id) }
                    }
                } label: {
                    Label(NSLocalizedString("Ask a Room's Switchboard", comment: "finding menu"),
                          systemImage: "square.grid.2x2")
                }
            }
        }
    }
}

/// Triage verbs for a finding — the rows' ⋯ menu and right-click menu.
struct FindingTriageItems: View {
    let finding: RepoFinding
    var onStatus: (RepoFinding.Status, String?) -> Void
    var onOpen: (() -> Void)? = nil

    var body: some View {
        if let onOpen {
            Button(NSLocalizedString("Show Details", comment: "finding menu"), action: onOpen)
            Divider()
        }
        if finding.status.isOpen && finding.taskID == nil {
            SwitchboardRouteItems(finding: finding)
            Divider()
        }
        if finding.status.isOpen {
            if finding.status == .new {
                Button(NSLocalizedString("Move to Backlog", comment: "finding menu")) {
                    onStatus(.triaged, nil)
                }
            } else if finding.status == .triaged {
                Button(NSLocalizedString("Mark as New", comment: "finding menu")) { onStatus(.new, nil) }
            }
            Button(NSLocalizedString("Mark as Fixed", comment: "finding menu")) {
                onStatus(.fixed, NSLocalizedString("Marked fixed by hand", comment: "finding status note"))
            }
            Button(NSLocalizedString("Dismiss (Not an Issue)", comment: "finding menu")) {
                onStatus(.dismissed, NSLocalizedString("Dismissed", comment: ""))
            }
        } else {
            Button(NSLocalizedString("Reopen", comment: "finding menu")) { onStatus(.new, nil) }
        }
    }
}

/// The ⋯ button next to Fix on a finding row.
struct FindingRowMenu: View {
    let finding: RepoFinding
    var onStatus: (RepoFinding.Status, String?) -> Void

    var body: some View {
        Menu {
            FindingTriageItems(finding: finding, onStatus: onStatus)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Backlog, dismiss, mark fixed…", comment: "finding menu"))
    }
}

struct FixButton: View {
    let finding: RepoFinding
    var prominent = false
    var onFix: () -> Void
    @State private var confirmFlagged = false
    @Environment(\.findingRouting) private var routing

    var body: some View {
        // No fix yet — or one whose start failed and fell back to the backlog.
        if finding.status.isOpen && (finding.taskID == nil || finding.status == .triaged) {
            Group {
                if prominent {
                    Button {
                        if finding.screenWarning != nil { confirmFlagged = true } else { onFix() }
                    } label: {
                        Label(finding.taskID == nil
                              ? NSLocalizedString("Start a Fix", comment: "finding action")
                              : NSLocalizedString("Retry the Fix", comment: "finding action"),
                              systemImage: finding.taskID == nil ? "wrench.and.screwdriver" : "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if routing.route != nil && finding.taskID == nil {
                    // Split button: click = a new fix session; the arrow
                    // offers the Switchboards.
                    Menu {
                        Button {
                            if finding.screenWarning != nil { confirmFlagged = true } else { onFix() }
                        } label: {
                            Label(NSLocalizedString("Start a Fix Session", comment: "finding menu"),
                                  systemImage: "wrench.and.screwdriver")
                        }
                        Divider()
                        SwitchboardRouteItems(finding: finding)
                    } label: {
                        Label(NSLocalizedString("Fix", comment: "finding action"), systemImage: "wrench.and.screwdriver")
                    } primaryAction: {
                        if finding.screenWarning != nil { confirmFlagged = true } else { onFix() }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Button {
                        if finding.screenWarning != nil { confirmFlagged = true } else { onFix() }
                    } label: {
                        Label(finding.taskID == nil
                              ? NSLocalizedString("Fix", comment: "finding action")
                              : NSLocalizedString("Retry", comment: "finding action"),
                              systemImage: finding.taskID == nil ? "wrench.and.screwdriver" : "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
            .alert(NSLocalizedString("This finding's text was flagged", comment: ""),
                   isPresented: $confirmFlagged) {
                Button(NSLocalizedString("Start Fix Anyway", comment: ""), role: .destructive, action: onFix)
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(String(format: NSLocalizedString(
                    "The prompt-injection screen flagged it (%@). It came from an agent reading repository content, and a fix agent would read it too. Check it before starting a fix.",
                    comment: ""), finding.screenWarning ?? ""))
            }
        } else {
            Color.clear.frame(width: 56, height: 1)
        }
    }
}

private struct AttentionRunRow: View {
    let run: AutomationRunRecord
    let automationName: String
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.outcome.glyph)
                .foregroundStyle(run.outcome.tint)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(automationName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(run.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(relative(run.firedAt))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Button(NSLocalizedString("Dismiss", comment: ""), action: onDismiss)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hubRowHover()
        .onTapGesture(perform: onOpen)
    }
}

private struct ScanRunRow: View {
    let run: AutomationRunRecord
    let automationName: String
    let live: Bool
    let newCount: Int
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if live {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: run.completedAt != nil ? "checkmark.circle.fill" : run.outcome.glyph)
                        .foregroundStyle(run.completedAt != nil ? .green : run.outcome.tint)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(automationName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(run.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if newCount > 0 {
                Text(String(format: NSLocalizedString("%d new", comment: "scan row"), newCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(relative(run.firedAt))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .hubRowHover()
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - Findings

struct HubFindingsTab: View {
    var automationStore: ScheduledAutomationStore
    var findingStore: FindingStore
    var taskStore: CodingTaskStore?
    @Bindable var model: SessionListModel
    @Bindable var hub: AutomationHubModel
    let actions: AutomationHubView.Actions

    private var filtered: [RepoFinding] {
        let q = hub.search.trimmingCharacters(in: .whitespaces)
        return findingStore.findings.filter { f in
            switch hub.statusFilter {
            case .open: if !f.status.isOpen { return false }
            case .all: break
            case .only(let s): if f.status != s { return false }
            }
            if let sev = hub.severityFilter, f.severity != sev { return false }
            if let r = hub.repoFilter, f.repo != r { return false }
            if !q.isEmpty {
                let hay = [f.title, f.file ?? "", f.summary, f.cwe ?? "", f.repo].joined(separator: " ")
                if !hay.localizedCaseInsensitiveContains(q) { return false }
            }
            return true
        }.sortedForTriage()
    }

    var body: some View {
        VStack(spacing: 0) {
            HubFindingsFlow(findings: findingStore.findings)
                .frame(height: 150)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            filterBar
            Divider()
            HStack(spacing: 0) {
                table
                if let id = hub.selectedFindingID, let f = findingStore.finding(id) {
                    Divider()
                    FindingDetailPanel(
                        finding: f,
                        task: f.taskID.flatMap { taskStore?.task($0) },
                        others: findingStore.findings(repo: f.repo, profileID: f.profileID)
                            .filter { $0.id != f.id && $0.status != .duplicate },
                        runs: f.runIDs.compactMap { rid in automationStore.runs.first { $0.id == rid } },
                        automationName: { automationStore.automation($0)?.name ?? "" },
                        actions: actions,
                        onClose: { hub.selectedFindingID = nil })
                        .frame(width: 420)
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("Search findings", comment: "hub"), text: $hub.search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            Picker(NSLocalizedString("Status", comment: "filter"), selection: $hub.statusFilter) {
                Text(NSLocalizedString("Open", comment: "filter")).tag(AutomationHubModel.StatusFilter.open)
                Text(NSLocalizedString("All", comment: "filter")).tag(AutomationHubModel.StatusFilter.all)
                Divider()
                ForEach(RepoFinding.Status.allCases, id: \.self) { s in
                    Text(s.displayName).tag(AutomationHubModel.StatusFilter.only(s))
                }
            }
            .fixedSize()
            Picker(NSLocalizedString("Severity", comment: "filter"), selection: $hub.severityFilter) {
                Text(NSLocalizedString("Any severity", comment: "filter")).tag(RepoFinding.Severity?.none)
                ForEach(RepoFinding.Severity.allCases, id: \.self) { s in
                    Text(s.displayName).tag(RepoFinding.Severity?.some(s))
                }
            }
            .fixedSize()
            let repos = Array(Set(findingStore.findings.map(\.repo))).sorted()
            if repos.count > 1 {
                Picker(NSLocalizedString("Repository", comment: "filter"), selection: $hub.repoFilter) {
                    Text(NSLocalizedString("All repositories", comment: "filter")).tag(String?.none)
                    ForEach(repos, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
            }
            Spacer()
            Text(String(format: NSLocalizedString("%d finding(s)", comment: "hub"), filtered.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var table: some View {
        let rows = filtered
        if findingStore.findings.isEmpty {
            ContentUnavailableView {
                Label(NSLocalizedString("No findings yet", comment: "hub"), systemImage: "checkmark.shield")
            } description: {
                Text(NSLocalizedString(
                    "Findings appear here as the repository watches scan. Watch a repository from the Repositories tab.",
                    comment: "hub"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label(NSLocalizedString("No matching findings", comment: "hub"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(NSLocalizedString("Nothing matches these filters.", comment: "hub"))
            } actions: {
                Button(NSLocalizedString("Clear Filters", comment: "hub")) {
                    hub.search = ""; hub.severityFilter = nil; hub.repoFilter = nil; hub.statusFilter = .all
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FindingsList(rows: rows, compact: hub.selectedFindingID != nil,
                         selection: $hub.selectedFindingID, onFix: actions.fix,
                         onStatus: actions.setStatus)
        }
    }
}

/// The findings table: fixed columns that fold away (repository, seen) when
/// the detail panel takes the room, so Fix never scrolls off.
struct FindingsList: View {
    let rows: [RepoFinding]
    let compact: Bool
    @Binding var selection: UUID?
    var onFix: (UUID) -> Void
    var onStatus: (UUID, RepoFinding.Status, String?) -> Void = { _, _, _ in }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { f in
                            FindingListRow(finding: f, compact: compact,
                                           selected: selection == f.id,
                                           onSelect: {
                                               selection = selection == f.id ? nil : f.id
                                               focused = true
                                           },
                                           onFix: { onFix(f.id) },
                                           onStatus: { st, note in onStatus(f.id, st, note) })
                                .id(f.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let i = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = i.map { min(max($0 + delta, 0), rows.count - 1) } ?? 0
        selection = rows[next].id
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString("Severity", comment: "column")).frame(width: 72, alignment: .leading)
            Text(NSLocalizedString("Finding", comment: "column")).frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(NSLocalizedString("Repository", comment: "column")).frame(width: 160, alignment: .leading)
            }
            Text(NSLocalizedString("Status", comment: "column")).frame(width: 104, alignment: .leading)
            if !compact {
                Text(NSLocalizedString("Seen", comment: "column")).frame(width: 120, alignment: .leading)
            }
            Color.clear.frame(width: 78 + 20 + 12, height: 1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
    }
}

private struct FindingListRow: View {
    let finding: RepoFinding
    let compact: Bool
    let selected: Bool
    var onSelect: () -> Void
    var onFix: () -> Void
    var onStatus: (RepoFinding.Status, String?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: finding.severity, compact: true)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if finding.screenWarning != nil {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .help(NSLocalizedString("Flagged by the prompt-injection screen", comment: ""))
                    }
                    Text(finding.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                Text(compact
                     ? [finding.repo, finding.location].filter { !$0.isEmpty }.joined(separator: " · ")
                     : (finding.location.isEmpty ? finding.category.displayName : finding.location))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(finding.repo)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
            }
            FindingStatusPill(status: finding.status)
                .frame(width: 104, alignment: .leading)
            if !compact {
                Text(finding.seenCount > 1
                     ? String(format: NSLocalizedString("%1$@ · ×%2$d", comment: "seen column"),
                              relative(finding.lastSeenAt), finding.seenCount)
                     : relative(finding.lastSeenAt))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
            FixButton(finding: finding, onFix: onFix)
                .frame(width: 78, alignment: .trailing)
            FindingRowMenu(finding: finding, onStatus: onStatus)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            selected ? Color.accentColor.opacity(0.16)
                     : Color.primary.opacity(hovering ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu { FindingTriageItems(finding: finding, onStatus: onStatus, onOpen: onSelect) }
    }
}

/// Findings by severity flowing into their status — the Findings tab's
/// header: two columns of bars joined by ribbons sized by count.
struct HubFindingsFlow: View {
    let findings: [RepoFinding]

    /// Node layout for one column: each node gets a floor height (so its
    /// label always fits) plus a share of the rest by count.
    private static func layout<K: Hashable>(_ keys: [K], counts: [K: Int], height: CGFloat,
                                            gap: CGFloat, floor: CGFloat) -> [K: (y: CGFloat, h: CGFloat)] {
        let n = CGFloat(keys.count)
        let total = CGFloat(keys.reduce(0) { $0 + (counts[$1] ?? 0) })
        let spare = max(height - gap * max(n - 1, 0) - floor * n, 0)
        var out: [K: (y: CGFloat, h: CGFloat)] = [:]
        var y: CGFloat = 0
        for k in keys {
            let h = floor + (total > 0 ? spare * CGFloat(counts[k] ?? 0) / total : 0)
            out[k] = (y, h)
            y += h + gap
        }
        return out
    }

    var body: some View {
        Canvas { ctx, size in
            guard !findings.isEmpty else {
                ctx.draw(Text(NSLocalizedString("No findings yet", comment: ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let sevs = RepoFinding.Severity.allCases.filter { s in findings.contains { $0.severity == s } }
            let stats = RepoFinding.Status.allCases.filter { s in findings.contains { $0.status == s } }
            var sevCount: [RepoFinding.Severity: Int] = [:]
            var statCount: [RepoFinding.Status: Int] = [:]
            var pair: [String: Int] = [:]
            for f in findings {
                sevCount[f.severity, default: 0] += 1
                statCount[f.status, default: 0] += 1
                pair["\(f.severity.rawValue)|\(f.status.rawValue)", default: 0] += 1
            }
            let left = Self.layout(sevs, counts: sevCount, height: size.height, gap: 6, floor: 12)
            let right = Self.layout(stats, counts: statCount, height: size.height, gap: 6, floor: 12)
            let barW: CGFloat = 5
            let leftX: CGFloat = 104, rightX = size.width - 130

            // Ribbons first, under the bars. Each takes its share of both
            // ends' node heights.
            var lCursor = left.mapValues { $0.y }, rCursor = right.mapValues { $0.y }
            for sev in sevs {
                for st in stats {
                    let n = pair["\(sev.rawValue)|\(st.rawValue)"] ?? 0
                    guard n > 0, let l = lCursor[sev], let r = rCursor[st],
                          let ln = left[sev], let rn = right[st] else { continue }
                    let hl = ln.h * CGFloat(n) / CGFloat(sevCount[sev] ?? 1)
                    let hr = rn.h * CGFloat(n) / CGFloat(statCount[st] ?? 1)
                    let x0 = leftX, x1 = rightX, mx = (x0 + x1) / 2
                    var p = Path()
                    p.move(to: CGPoint(x: x0, y: l))
                    p.addCurve(to: CGPoint(x: x1, y: r), control1: CGPoint(x: mx, y: l),
                               control2: CGPoint(x: mx, y: r))
                    p.addLine(to: CGPoint(x: x1, y: r + hr))
                    p.addCurve(to: CGPoint(x: x0, y: l + hl), control1: CGPoint(x: mx, y: r + hr),
                               control2: CGPoint(x: mx, y: l + hl))
                    p.closeSubpath()
                    let faded = !st.isOpen
                    ctx.fill(p, with: .linearGradient(
                        Gradient(colors: [sev.tint.opacity(faded ? 0.12 : 0.28),
                                          st.bandColor.opacity(faded ? 0.12 : 0.30)]),
                        startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                    lCursor[sev] = l + hl
                    rCursor[st] = r + hr
                }
            }
            for s in sevs {
                guard let n = left[s] else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: leftX - barW, y: n.y, width: barW, height: n.h),
                              cornerRadius: 2), with: .color(s.tint))
                ctx.draw(Text("\(s.displayName)  ").font(.system(size: 11, weight: .medium))
                         + Text("\(sevCount[s] ?? 0)").font(.system(size: 11)).foregroundColor(.secondary),
                         at: CGPoint(x: leftX - barW - 8, y: n.y + n.h / 2), anchor: .trailing)
            }
            for s in stats {
                guard let n = right[s] else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: rightX, y: n.y, width: barW, height: n.h),
                              cornerRadius: 2), with: .color(s.bandColor))
                ctx.draw(Text("\(s.displayName)  ").font(.system(size: 11, weight: .medium))
                         + Text("\(statCount[s] ?? 0)").font(.system(size: 11)).foregroundColor(.secondary),
                         at: CGPoint(x: rightX + barW + 8, y: n.y + n.h / 2), anchor: .leading)
            }
        }
        .accessibilityLabel(Text(NSLocalizedString("Findings by severity and status", comment: "")))
    }
}

struct FindingDetailPanel: View {
    let finding: RepoFinding
    let task: CodingTask?
    /// Candidates for "Duplicate of".
    let others: [RepoFinding]
    let runs: [AutomationRunRecord]
    let automationName: (UUID) -> String
    let actions: AutomationHubView.Actions
    var onClose: () -> Void

    @State private var dismissNote = ""
    @State private var askDismiss = false
    @Environment(\.findingRouting) private var routing

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SeverityBadge(severity: finding.severity)
                Text(finding.category.displayName + (finding.cwe.map { " · " + $0 } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(finding.title)
                        .font(.system(size: 15, weight: .semibold))
                        .textSelection(.enabled)
                    triageBar
                    if let note = finding.statusNote, !note.isEmpty {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let warn = finding.screenWarning {
                        Label(String(format: NSLocalizedString("Flagged by the prompt-injection screen: %@", comment: ""), warn),
                              systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    fixSection
                    meta
                    section(NSLocalizedString("What's wrong", comment: "finding detail"), markdown: finding.summary)
                    if let e = finding.evidence, !e.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("Evidence", comment: "finding detail"))
                                .font(.system(size: 12, weight: .semibold))
                            ScrollView(.horizontal) {
                                Text(e)
                                    .font(.system(size: 11).monospaced())
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    if let r = finding.recommendation, !r.isEmpty {
                        section(NSLocalizedString("Recommendation", comment: "finding detail"), markdown: r)
                    }
                    history
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.platformWindowBackground)
        .alert(NSLocalizedString("Dismiss this finding?", comment: ""), isPresented: $askDismiss) {
            TextField(NSLocalizedString("Reason (optional)", comment: ""), text: $dismissNote)
            Button(NSLocalizedString("Dismiss", comment: "")) {
                actions.setStatus(finding.id, .dismissed,
                                  dismissNote.isEmpty ? NSLocalizedString("Dismissed", comment: "") : dismissNote)
                dismissNote = ""
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("Later scans that see it again won't reopen it.", comment: ""))
        }
    }

    /// Status at a glance, the usual verbs as buttons, the rest in the menu.
    private var triageBar: some View {
        HStack(spacing: 8) {
            statusMenu
            Spacer(minLength: 4)
            if finding.status == .new {
                Button(NSLocalizedString("Move to Backlog", comment: "finding menu")) {
                    actions.setStatus(finding.id, .triaged, nil)
                }
                .controlSize(.small)
            }
            if finding.status.isOpen {
                Button(NSLocalizedString("Dismiss…", comment: "")) { askDismiss = true }
                    .controlSize(.small)
            } else {
                Button(NSLocalizedString("Reopen", comment: "finding menu")) {
                    actions.setStatus(finding.id, .new, nil)
                }
                .controlSize(.small)
            }
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach([RepoFinding.Status.new, .triaged, .fixed], id: \.self) { s in
                Button(String(format: NSLocalizedString("Mark as %@", comment: ""), s.displayName)) {
                    actions.setStatus(finding.id, s, nil)
                }
                .disabled(finding.status == s)
            }
            Button(NSLocalizedString("Dismiss…", comment: "")) { askDismiss = true }
                .disabled(finding.status == .dismissed)
            if !others.isEmpty {
                Menu(NSLocalizedString("Duplicate of", comment: "")) {
                    ForEach(others.sortedForTriage().prefix(40)) { o in
                        Button(o.title) { actions.markDuplicate(finding.id, o.id) }
                    }
                }
            }
            Divider()
            Button(NSLocalizedString("Delete Finding", comment: ""), role: .destructive) {
                actions.deleteFinding(finding.id)
                onClose()
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(finding.status.tint).frame(width: 7, height: 7)
                Text(finding.status.displayName)
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(NSLocalizedString("Change the status", comment: "finding status menu"))
    }

    @ViewBuilder private var fixSection: some View {
        if let task, task.stage == .backlog, let err = task.lastError {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: NSLocalizedString("The fix couldn't start: %@", comment: "finding detail"), err),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    FixButton(finding: finding, prominent: true) { actions.fix(finding.id) }
                    Button(NSLocalizedString("Open Task", comment: "fix task")) { actions.openTask(task.id) }
                        .controlSize(.large)
                }
            }
            .padding(10)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        } else if let task {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(taskStageText(task)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(NSLocalizedString("Open", comment: "fix task")) { actions.openTask(task.id) }
                    .controlSize(.small)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if finding.status.isOpen {
            VStack(alignment: .leading, spacing: 6) {
                FixButton(finding: finding, prominent: true) { actions.fix(finding.id) }
                if routing.route != nil {
                    Menu {
                        SwitchboardRouteItems(finding: finding)
                    } label: {
                        Label(NSLocalizedString("Ask the Switchboard Instead…", comment: "finding detail"),
                              systemImage: "person.2.wave.2")
                            .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .controlSize(.large)
                }
                Text(NSLocalizedString(
                    "An agent fixes it on a branch of its own — or the Switchboard proposes which of your running sessions should. You review the change before anything merges.",
                    comment: "finding detail"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func taskStageText(_ t: CodingTask) -> String {
        switch t.stage {
        case .backlog:    return t.lastError ?? NSLocalizedString("Fix not started", comment: "")
        case .planning:   return NSLocalizedString("Planning", comment: "")
        case .inProgress: return NSLocalizedString("Agent working on the fix", comment: "")
        case .testing:    return NSLocalizedString("Ready for review", comment: "")
        case .done:
            if t.merged { return NSLocalizedString("Merged", comment: "") }
            if t.prOpened == true { return NSLocalizedString("Pull request opened", comment: "") }
            return NSLocalizedString("Closed", comment: "")
        }
    }

    private var meta: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text(NSLocalizedString("Repository", comment: "")).foregroundStyle(.secondary)
                Link(finding.repo, destination: URL(string: "https://github.com/\(finding.repo)")!)
            }
            if !finding.location.isEmpty {
                GridRow {
                    Text(NSLocalizedString("Location", comment: "")).foregroundStyle(.secondary)
                    if let url = sourceURL {
                        Link(finding.location, destination: url).font(.system(size: 11.5).monospaced())
                    } else {
                        Text(finding.location).font(.system(size: 11.5).monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let c = finding.commit {
                GridRow {
                    Text(NSLocalizedString("Commit", comment: "")).foregroundStyle(.secondary)
                    Text(String(c.prefix(10))).font(.system(size: 11.5).monospaced()).textSelection(.enabled)
                }
            }
            GridRow {
                Text(NSLocalizedString("First seen", comment: "")).foregroundStyle(.secondary)
                Text(finding.firstSeenAt.formatted(date: .abbreviated, time: .shortened))
            }
            GridRow {
                Text(NSLocalizedString("Last seen", comment: "")).foregroundStyle(.secondary)
                Text(finding.lastSeenAt.formatted(date: .abbreviated, time: .shortened)
                     + (finding.seenCount > 1
                        ? " · " + String(format: NSLocalizedString("reported %d times", comment: ""), finding.seenCount)
                        : ""))
            }
        }
        .font(.system(size: 11.5))
    }

    private var sourceURL: URL? {
        guard let file = finding.file else { return nil }
        let ref = finding.commit ?? "HEAD"
        var s = "https://github.com/\(finding.repo)/blob/\(ref)/\(file)"
        if let l = finding.line {
            s += "#L\(l)"
            if let e = finding.endLine, e > l { s += "-L\(e)" }
        }
        return URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s)
    }

    private func section(_ title: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text((try? AttributedString(markdown: markdown, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var history: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Reported by", comment: "finding detail"))
                    .font(.system(size: 12, weight: .semibold))
                ForEach(runs) { run in
                    Button {
                        actions.board.openRun(run)
                    } label: {
                        HStack {
                            Text(automationName(run.automationID)).lineLimit(1)
                            Spacer()
                            Text(run.firedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Repositories

struct HubRepositoriesTab: View {
    var automationStore: ScheduledAutomationStore
    var findingStore: FindingStore
    @Bindable var model: SessionListModel
    @Bindable var hub: AutomationHubModel
    let actions: AutomationHubView.Actions
    var onNewWatch: () -> Void

    var body: some View {
        if findingStore.watches.isEmpty {
            ContentUnavailableView {
                Label(NSLocalizedString("No watched repositories", comment: "hub"),
                      systemImage: "eye")
            } description: {
                Text(NSLocalizedString(
                    "A watch scans a GitHub repository with an agent in one of your workspaces: the whole codebase on a schedule, and every new commit and pull request as they land. Findings are deduplicated across scans.",
                    comment: "hub"))
                    .frame(maxWidth: 520)
            } actions: {
                Button(NSLocalizedString("Watch a GitHub Repository…", comment: "hub"),
                       action: onNewWatch)
                .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(findingStore.watches) { w in
                        WatchCard(watch: w,
                                  automationStore: automationStore,
                                  findings: findingStore.findings(forWatch: w.id),
                                  workspace: model.profileRows.first { $0.id == w.profileID },
                                  actions: actions,
                                  onEdit: {
                                      hub.editingWatchIsNew = false
                                      hub.editingWatch = w
                                  },
                                  onShowFindings: {
                                      hub.repoFilter = w.repo
                                      hub.statusFilter = .open
                                      hub.showSecurity(.findings)
                                  })
                    }
                    AddWatchCard(action: onNewWatch)
                }
                .padding(16)
            }
        }
    }
}

/// The grid's last tile: add another repository.
private struct AddWatchCard: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                Text(NSLocalizedString("Watch a Repository…", comment: "hub welcome"))
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Color.primary.opacity(hovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.3 : 0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct WatchCard: View {
    let watch: WatchedRepo
    var automationStore: ScheduledAutomationStore
    let findings: [RepoFinding]
    let workspace: SessionListModel.ProfileRow?
    let actions: AutomationHubView.Actions
    var onEdit: () -> Void
    var onShowFindings: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let stats = FindingStats(findings)
        HubCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(.secondary)
                            Link(watch.repo, destination: URL(string: "https://github.com/\(watch.repo)")!)
                                .font(.system(size: 14, weight: .semibold))
                            if !watch.enabled {
                                Text(NSLocalizedString("Paused", comment: "watch"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                        HStack(spacing: 5) {
                            if let workspace {
                                Circle().fill(Color(hex: workspace.accentHex)).frame(width: 7, height: 7)
                            }
                            Text([workspace?.name, watch.tool.displayName, watch.focus.displayName]
                                .compactMap { $0 }.joined(separator: " · "))
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        actions.scanNow(watch.id)
                    } label: {
                        Label(NSLocalizedString("Scan Now", comment: "watch"), systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    Menu {
                        Button(NSLocalizedString("Edit…", comment: ""), action: onEdit)
                        Button(watch.enabled ? NSLocalizedString("Pause", comment: "")
                                             : NSLocalizedString("Resume", comment: "")) {
                            actions.toggleWatch(watch.id)
                        }
                        Divider()
                        Button(NSLocalizedString("Stop Watching…", comment: ""), role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button(action: onShowFindings) {
                    HStack(spacing: 8) {
                        Text(String(format: NSLocalizedString("%d open", comment: "watch card"), stats.open))
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(RepoFinding.Severity.allCases.filter { (stats.openBySeverity[$0] ?? 0) > 0 },
                                id: \.self) { sev in
                            Text("\(stats.openBySeverity[sev] ?? 0) \(sev.displayName)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .foregroundStyle(sev.tint)
                                .background(sev.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                        Text(String(format: NSLocalizedString("%d fixed", comment: "watch card"),
                                    stats.count(.fixed)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WatchedRepo.Scan.allCases, id: \.self) { scan in
                        scanLine(scan)
                    }
                }
            }
        }
        .alert(String(format: NSLocalizedString("Stop watching %@?", comment: ""), watch.repo),
               isPresented: $confirmDelete) {
            Button(NSLocalizedString("Stop Watching", comment: ""), role: .destructive) {
                actions.deleteWatch(watch.id)
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString(
                "Its scans stop and its automations are removed. Its findings are deleted too; fix tasks already started stay on the task board.",
                comment: ""))
        }
    }

    @ViewBuilder private func scanLine(_ scan: WatchedRepo.Scan) -> some View {
        let on = watch.scans.contains(scan)
        let aid = watch.automationID(for: scan)
        let last = aid.flatMap { automationStore.lastRun(for: $0) }
        let poll = aid.flatMap { automationStore.pollState(for: $0) }
        HStack(spacing: 8) {
            Image(systemName: scan.systemImage)
                .frame(width: 16)
                .foregroundStyle(on ? .primary : .tertiary)
            Text(scan.shortName)
                .font(.system(size: 12))
                .foregroundStyle(on ? .primary : .tertiary)
            Spacer()
            Group {
                if !on {
                    Text(NSLocalizedString("Off", comment: "scan line"))
                } else if let err = poll?.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(err)
                } else if scan == .fullScan, let aid, let next = automationStore.nextFire(for: aid) {
                    Text(String(format: NSLocalizedString("next %@", comment: "scan line"), relative(next)))
                } else if let last {
                    Text(String(format: NSLocalizedString("last %@", comment: "scan line"), relative(last.firedAt)))
                } else if let polled = poll?.lastPolledAt {
                    Text(String(format: NSLocalizedString("watching · checked %@", comment: "scan line"),
                                relative(polled)))
                } else {
                    Text(NSLocalizedString("watching", comment: "scan line"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Watch editor

struct WatchEditorSheet: View {
    @State var draft: WatchedRepo
    let isNew: Bool
    let workspaces: [WatchWorkspaceChoice]
    let promptGuardInstalled: Bool
    let fetchRepos: (UUID) async throws -> [String]
    var onEditWorkspace: (UUID) -> Void
    var onCancel: () -> Void
    var onSave: (WatchedRepo, Bool) -> Void

    @State private var repoChoices: [String]?
    @State private var repoError: String?
    @State private var pathEdited = false
    @State private var autoFix: RepoFinding.Severity?

    init(draft: WatchedRepo, isNew: Bool, workspaces: [WatchWorkspaceChoice],
         promptGuardInstalled: Bool,
         fetchRepos: @escaping (UUID) async throws -> [String],
         onEditWorkspace: @escaping (UUID) -> Void,
         onCancel: @escaping () -> Void,
         onSave: @escaping (WatchedRepo, Bool) -> Void) {
        _draft = State(initialValue: draft)
        _autoFix = State(initialValue: draft.autoFixMinSeverity)
        _pathEdited = State(initialValue: !isNew)
        self.isNew = isNew
        self.workspaces = workspaces
        self.promptGuardInstalled = promptGuardInstalled
        self.fetchRepos = fetchRepos
        self.onEditWorkspace = onEditWorkspace
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var workspace: WatchWorkspaceChoice? {
        workspaces.first { $0.id == draft.profileID }
    }

    private var repoValid: Bool { GitHubPRPoller.isValidRepoSlug(draft.repo) }

    /// GitHub answered 401 for this workspace's token (set by `loadRepos`).
    @State private var tokenRejected = false

    /// A watch with a token GitHub refuses would only fail every scan.
    private var canSave: Bool { repoValid && !tokenRejected }

    private func scanBinding(_ s: WatchedRepo.Scan) -> Binding<Bool> {
        Binding(get: { draft.scans.contains(s) },
                set: { on in
                    if on { if !draft.scans.contains(s) { draft.scans.append(s) } }
                    else { draft.scans.removeAll { $0 == s } }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? NSLocalizedString("Watch a GitHub Repository", comment: "watch editor")
                       : String(format: NSLocalizedString("Watch on %@", comment: "watch editor"), draft.repo))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 16)
            Form {
                Section(NSLocalizedString("Repository", comment: "watch editor")) {
                    Picker(NSLocalizedString("Workspace", comment: ""), selection: $draft.profileID) {
                        ForEach(workspaces) { Text($0.name).tag($0.id) }
                    }
                    if workspace?.hasGitHubToken == false {
                        HStack {
                            Label(NSLocalizedString("This workspace has no github.com token — scans poll GitHub with it.", comment: ""),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            Spacer()
                            Button(NSLocalizedString("Edit Workspace…", comment: "")) {
                                onEditWorkspace(draft.profileID)
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent(NSLocalizedString("Repository", comment: "")) {
                        HStack(spacing: 4) {
                            TextField("", text: $draft.repo, prompt: Text("owner/name"))
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                            if let repos = repoChoices, !repos.isEmpty {
                                Menu {
                                    ForEach(repoSuggestions(repos), id: \.self) { r in
                                        Button(r) { draft.repo = r }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(NSLocalizedString("Repositories this workspace's token can reach", comment: ""))
                            }
                        }
                    }
                    if tokenRejected {
                        // A dead token isn't a footnote: every scan of this
                        // watch would fail. Say what's wrong and where to fix it.
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NSLocalizedString("GitHub rejected this workspace's token", comment: "watch editor"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.red)
                                Text(String(format: NSLocalizedString(
                                    "The github.com token is expired, revoked, or mistyped (HTTP 401). Update it in %@ › Credentials, or pick another workspace.",
                                    comment: "watch editor"), workspace?.name ?? ""))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button(NSLocalizedString("Edit Workspace…", comment: "")) {
                                onEditWorkspace(draft.profileID)
                            }
                            .controlSize(.small)
                        }
                    } else if let repoError {
                        Label(repoError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    TextField(NSLocalizedString("Checkout in the workspace", comment: ""),
                              text: Binding(get: { draft.repoPath },
                                            set: { draft.repoPath = $0; pathEdited = true }))
                        .help(NSLocalizedString("Where the repository is (or will be cloned) inside the workspace.", comment: ""))
                    if let ws = workspace, !ws.tools.isEmpty {
                        Picker(NSLocalizedString("Agent", comment: ""), selection: $draft.tool) {
                            ForEach(ws.tools, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    Picker(NSLocalizedString("Look for", comment: ""), selection: $draft.focus) {
                        ForEach(WatchedRepo.Focus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section(NSLocalizedString("Scans", comment: "watch editor")) {
                    Toggle(WatchedRepo.Scan.fullScan.displayName, isOn: scanBinding(.fullScan))
                    if draft.scans.contains(.fullScan) {
                        LabeledContent(NSLocalizedString("Weekly", comment: "full scan cadence")) {
                            HStack(spacing: 6) {
                                Picker("", selection: $draft.fullScanWeekday) {
                                    ForEach(1...7, id: \.self) { d in
                                        Text(Calendar.current.weekdaySymbols[d - 1]).tag(d)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                Picker("", selection: $draft.fullScanHour) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d:00", h)).tag(h)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }
                    Toggle(WatchedRepo.Scan.commits.displayName, isOn: scanBinding(.commits))
                    if draft.scans.contains(.commits) {
                        TextField(NSLocalizedString("Branch", comment: ""), text: $draft.commitBranch,
                                  prompt: Text(NSLocalizedString("default branch", comment: "")))
                    }
                    Toggle(WatchedRepo.Scan.pullRequests.displayName, isOn: scanBinding(.pullRequests))
                    if !promptGuardInstalled,
                       draft.scans.contains(.commits) || draft.scans.contains(.pullRequests) {
                        Label(NSLocalizedString(
                            "Commit and pull-request scans put third-party text in front of an agent, so they require the PromptGuard model. It downloads when you save the watch; until it's ready, those scans are blocked.",
                            comment: ""), systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Text(NSLocalizedString(
                        "Commit and pull-request scans start with what lands after the watch is created. Use Scan Now for the existing code.",
                        comment: ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(NSLocalizedString("Fixes", comment: "watch editor")) {
                    Picker(NSLocalizedString("Start fixes automatically", comment: ""), selection: $autoFix) {
                        Text(NSLocalizedString("Never", comment: "auto fix")).tag(RepoFinding.Severity?.none)
                        Text(NSLocalizedString("For critical findings", comment: "auto fix"))
                            .tag(RepoFinding.Severity?.some(.critical))
                        Text(NSLocalizedString("For high and critical", comment: "auto fix"))
                            .tag(RepoFinding.Severity?.some(.high))
                        Text(NSLocalizedString("For medium and above", comment: "auto fix"))
                            .tag(RepoFinding.Severity?.some(.medium))
                    }
                    Text(NSLocalizedString(
                        "A fix is a coding task on its own branch — it waits in review for you before anything merges. At most three automatic fixes run at once per repository.",
                        comment: ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(NSLocalizedString("Instructions for the scanning agent", comment: "watch editor")) {
                    TextEditor(text: $draft.instructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 60)
                }
                if let labels = workspace?.askBeforeUseLabels, !labels.isEmpty {
                    Section {
                        Label(String(format: NSLocalizedString(
                            "These credentials ask before each use, which stalls an unattended scan until you answer: %@",
                            comment: ""), labels.joined(separator: ", ")),
                              systemImage: "hand.raised.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if tokenRejected {
                    Text(NSLocalizedString("Fix the workspace's GitHub token to watch a repository.", comment: "watch editor"))
                        .font(.system(size: 11)).foregroundStyle(.red)
                } else if !repoValid {
                    Text(NSLocalizedString("Pick a repository (owner/name).", comment: ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if isNew {
                    Button(NSLocalizedString("Watch and Scan Now", comment: "")) { save(scan: true) }
                        .disabled(!canSave)
                }
                Button(isNew ? NSLocalizedString("Watch", comment: "") : NSLocalizedString("Save", comment: "")) {
                    save(scan: false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 580, height: 720)
        .task(id: draft.profileID) { await loadRepos() }
        .onAppear {
            if let ws = workspace, !ws.tools.isEmpty, !ws.tools.contains(draft.tool) {
                draft.tool = ws.defaultTool
            }
        }
        .onChange(of: draft.repo) { _, repo in
            if !pathEdited { draft.repoPath = WatchedRepo.defaultRepoPath(for: repo) }
        }
        .onChange(of: draft.profileID) { _, _ in
            if let ws = workspace, !ws.tools.contains(draft.tool) { draft.tool = ws.defaultTool }
        }
    }

    /// The picker's list: everything, or what matches what's typed so far.
    private func repoSuggestions(_ repos: [String]) -> [String] {
        let q = draft.repo.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !repos.contains(q) else { return Array(repos.prefix(60)) }
        let hits = repos.filter { $0.localizedCaseInsensitiveContains(q) }
        return Array((hits.isEmpty ? repos : hits).prefix(60))
    }

    private func loadRepos() async {
        repoChoices = nil
        repoError = nil
        tokenRejected = false
        guard workspace?.hasGitHubToken == true else { return }
        do {
            repoChoices = try await fetchRepos(draft.profileID)
        } catch {
            let ns = error as NSError
            if ns.domain == "GitHubPoller", ns.code == 401 {
                tokenRejected = true
            } else {
                repoError = error.localizedDescription
            }
        }
    }

    private func save(scan: Bool) {
        var w = draft
        w.repo = w.repo.trimmingCharacters(in: .whitespaces)
        w.autoFixMinSeverity = autoFix
        if w.repoPath.trimmingCharacters(in: .whitespaces).isEmpty {
            w.repoPath = WatchedRepo.defaultRepoPath(for: w.repo)
        }
        onSave(w, scan)
    }
}
#endif
