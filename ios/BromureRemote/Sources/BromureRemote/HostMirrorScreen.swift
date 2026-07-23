import SwiftUI

// MARK: - Host mirror (iOS)
//
// Owns a `RemoteHostController` — the SAME poll/reconcile engine the macOS
// mirror window uses — and renders its live state on a small screen: the
// workspace list, the automation and coding-task boards, and per-workspace
// detail (terminals, dashboard, docker, files). Every list here is driven by
// the reused mirror stores, refreshed by the 0.75 s /state poll.

/// A workspace window to open straight away — set when a tapped notification
/// deep-links to the exact agent that's waiting.
struct WorkspaceDeepLink: Hashable {
    let profileID: UUID
    let window: Int?
}

struct HostMirrorScreen: View {
    /// Owned by the app's per-host store, NOT created here — so leaving the host
    /// can deterministically stop it (poll + P2P teardown) instead of relying on
    /// @State dealloc, which never closed the peer path and left a stale
    /// connection to be reused (and stall) on reconnect.
    let controller: RemoteHostController
    let host: RemoteHost
    /// When set (a notification tap), push straight to this workspace window
    /// once the mirror has connected and knows about it.
    let openWorkspace: WorkspaceDeepLink?
    @State private var deepWorkspace: WorkspaceDeepLink?
    @State private var didDeepLink = false

    init(controller: RemoteHostController, host: RemoteHost,
         openWorkspace: WorkspaceDeepLink? = nil) {
        self.controller = controller
        self.host = host
        self.openWorkspace = openWorkspace
    }

    /// Push the deep-linked workspace the moment the mirror knows it exists
    /// (the profile-id guard means a stale link for another server no-ops).
    private func tryDeepLink() {
        guard !didDeepLink, let target = openWorkspace,
              controller.listModel.profileRows.contains(where: { $0.id == target.profileID })
        else { return }
        didDeepLink = true
        deepWorkspace = target
    }

    private var runningCount: Int {
        controller.listModel.profileRows.filter { $0.state == .running }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !controller.connected { reconnectBanner }

                boardsRow

                if !waitingAgents.isEmpty { waitingSection }

                workspacesSection
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(host.name.isEmpty ? host.address : host.name)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            // `start()` is idempotent, so re-appearing (popping back from a
            // pushed workspace/grid) is a no-op. Crucially we do NOT stop on
            // disappear: a NavigationStack push fires the parent's onDisappear,
            // and stopping there froze the mirror (stale tabs, dead grid cells)
            // for as long as a child was open. The poll runs for the whole time
            // the host is open; the controller invalidates its timer on dealloc
            // when the mirror is finally popped.
            controller.start()
            AppBadge.set(waitingAgents.count)
            tryDeepLink()
        }
        // Mirror the "agents waiting for input" count onto the app-icon badge.
        .onChange(of: waitingAgents.count) { AppBadge.set($0) }
        // Once the mirror connects and the workspaces load, a tapped
        // notification pushes straight to the waiting agent's window.
        .onChange(of: controller.revision) { tryDeepLink() }
        .navigationDestination(item: $deepWorkspace) { link in
            WorkspaceScreen(controller: controller, profileID: link.profileID,
                            initialWindow: link.window)
        }
        // Snap the mirror back to life when the app returns to the foreground.
        // After a long absence the P2P path is almost certainly dead — tear it
        // down so the next dial re-establishes a fresh one, rather than looping
        // on a locally-alive-but-remotely-dead shim (which just re-polls to no
        // avail). The controller + attached terminals then reconnect on it.
        .onReceive(NotificationCenter.default.publisher(for: .bromureDidForeground)) { note in
            let away = (note.userInfo?["awaySeconds"] as? TimeInterval) ?? 0
            if away > 20, let pid = host.peerDeviceID {
                P2PBroker.shared.closePeer(pid)
            }
            controller.foregroundKick()
        }
        .alert(item: topPrompt) { prompt in
            promptAlert(prompt)
        }
    }

    // MARK: At a Glance — agents waiting for input

    /// One coding agent paused on a question (its tab is in the red
    /// `needsInput` state), across every running workspace.
    struct WaitingAgent: Identifiable {
        let profileID: Profile.ID
        let windowIndex: Int
        let workspaceName: String
        let tabLabel: String
        let accentHex: String
        var id: String { "\(profileID.uuidString):\(windowIndex)" }
    }

    private var waitingAgents: [WaitingAgent] {
        controller.listModel.entries.flatMap { entry in
            entry.model.tabs
                .filter { $0.agentStatus == .needsInput }
                .map { tab in
                    WaitingAgent(
                        profileID: entry.id,
                        windowIndex: tab.index,
                        workspaceName: entry.name,
                        tabLabel: tab.shownLabel.isEmpty ? "shell" : tab.shownLabel,
                        accentHex: entry.accentHex)
                }
        }
    }

    // MARK: Dashboard sections

    private var reconnectBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.hasSnapshot ? "Reconnecting…" : "Connecting…")
                    .font(.subheadline.weight(.semibold))
                if let err = controller.lastError, controller.hasSnapshot {
                    Text(err).font(.caption)
                }
            }
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.orange.opacity(0.14)))
    }

    private var boardsRow: some View {
        HStack(spacing: 12) {
            NavigationLink { CodingBoardScreen(controller: controller) } label: {
                boardCard("Coding Tasks", icon: "checklist",
                          count: controller.taskStore.tasks.count, tint: .blue)
            }.buttonStyle(.plain)
            NavigationLink { AutomationsBoardScreen(controller: controller) } label: {
                boardCard("Automations", icon: "bolt.badge.clock.fill",
                          count: controller.automationStore.automations.count, tint: .orange)
            }.buttonStyle(.plain)
            NavigationLink { GridScreen(controller: controller) } label: {
                boardCard("Grid", icon: "square.grid.2x2.fill",
                          count: controller.gridStore.cells.count, tint: .purple)
            }.buttonStyle(.plain)
        }
    }

    private func boardCard(_ title: String, icon: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.footnote.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .foregroundStyle(tint)
                }
            }
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Needs your input", icon: "exclamationmark.bubble.fill", tint: .red)
            ForEach(waitingAgents) { agent in
                NavigationLink {
                    WorkspaceScreen(controller: controller, profileID: agent.profileID,
                                    initialWindow: agent.windowIndex)
                } label: { waitingAgentCard(agent) }
                .buttonStyle(.plain)
            }
        }
    }

    private func waitingAgentCard(_ agent: WaitingAgent) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.15)).frame(width: 42, height: 42)
                PulsingDot(color: .red, active: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.tabLabel).font(.body.weight(.semibold)).lineLimit(1)
                Text(agent.workspaceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("Reply").font(.caption.weight(.bold)).foregroundStyle(.red)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.red.opacity(0.55))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.red.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Workspaces",
                          trailing: controller.listModel.profileRows.isEmpty ? nil
                                    : "\(runningCount) running")
            if controller.listModel.profileRows.isEmpty {
                Text(controller.hasSnapshot ? "No workspaces on this server."
                                            : "Loading workspaces…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(controller.listModel.profileRows) { row in
                    NavigationLink {
                        WorkspaceScreen(controller: controller, profileID: row.id)
                    } label: { workspaceCard(row) }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func workspaceCard(_ row: SessionListModel.ProfileRow) -> some View {
        let accent = Color(hex: row.accentHex)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.18)).frame(width: 42, height: 42)
                Image(systemName: "cpu")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    stateDot(row.state)
                    Text(stateLabel(row.state)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if row.compromised {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(row.state == .running ? accent.opacity(0.4) : .clear, lineWidth: 1))
    }

    @ViewBuilder private func stateDot(_ s: SessionListModel.RunState) -> some View {
        switch s {
        case .running:   PulsingDot(color: .green, active: true)
        case .booting:   PulsingDot(color: .orange, active: true)
        case .suspended: PulsingDot(color: .yellow, active: false)
        case .off:       PulsingDot(color: .secondary, active: false)
        }
    }

    private func sectionHeader(_ title: String, icon: String? = nil,
                               tint: Color = .primary, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.subheadline).foregroundStyle(tint) }
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func stateLabel(_ s: SessionListModel.RunState) -> String {
        switch s {
        case .running: "Running"
        case .booting: "Booting…"
        case .suspended: "Suspended"
        case .off: "Off"
        }
    }

    // MARK: Decision prompts (mirror of the macOS NSAlert path)

    private var topPrompt: Binding<RemoteHostController.DecisionPrompt?> {
        Binding(
            get: { controller.decisionPrompts.first },
            set: { _ in })
    }

    private func promptAlert(_ prompt: RemoteHostController.DecisionPrompt) -> Alert {
        // Two-button prompts map to the native alert; more are collapsed to the
        // first two (destructive-looking first title is styled cautiously).
        let buttons = prompt.buttons
        let primaryIsDestructive = buttons.first?.lowercased().contains("wipe") == true
        if buttons.count >= 2 {
            let primary: Alert.Button = primaryIsDestructive
                ? .destructive(Text(buttons[0])) { controller.answerPrompt(prompt.id, choice: 0) }
                : .default(Text(buttons[0])) { controller.answerPrompt(prompt.id, choice: 0) }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: primary,
                secondaryButton: .cancel(Text(buttons[1])) {
                    controller.answerPrompt(prompt.id, choice: 1)
                })
        }
        return Alert(
            title: Text(prompt.title),
            message: Text(prompt.message),
            dismissButton: .default(Text(buttons.first ?? "OK")) {
                controller.answerPrompt(prompt.id, choice: 0)
            })
    }
}

// MARK: - Boards

struct CodingBoardScreen: View {
    let controller: RemoteHostController
    @State private var openedTask: TranscriptTarget?
    var body: some View {
        CodingKanbanView(
            store: controller.taskStore,
            model: controller.listModel,
            profilesProvider: { controller.profiles },
            actions: CodingKanbanView.Actions(
                start: { controller.taskCommand($0, "start") },
                plan: { controller.taskCommand($0, "plan") },
                openReview: { _ in },
                jumpToRun: { _ in },
                moveToTesting: { controller.taskCommand($0, "to-testing") },
                backToInProgress: { controller.taskCommand($0, "to-in-progress") },
                merge: { controller.taskCommand($0, "merge") },
                closeNoMerge: { controller.taskCommand($0, "close-no-merge") },
                delete: { controller.deleteTask($0) },
                save: { controller.upsertTask($0) },
                validate: { controller.upsertTask($0) },
                openPlanSession: { _ in },
                destroy: { controller.taskCommand($0, "destroy") },
                resume: { controller.taskCommand($0, "resume") },
                openTranscript: { openedTask = TranscriptTarget(id: $0) }))
        // Title, icon and "New Task" come from the board itself, straight into
        // this stack's navigation bar — one header, not two.
        .sheet(item: $openedTask) { t in
            TranscriptScreen(
                title: controller.taskStore.task(t.id)?.title ?? "Task",
                subtitle: nil,
                fetch: { await controller.fetchTaskTranscript(t.id) })
        }
    }
}

/// A UUID made presentable via `.sheet(item:)`.
struct TranscriptTarget: Identifiable { let id: UUID }

/// A fetched-once transcript rendered natively — shared by a finished coding
/// task and a completed automation run. Both pull the JSONL from the host over
/// the tunnel and render it with the shared `TranscriptItemView`.
struct TranscriptScreen: View {
    let title: String
    let subtitle: String?
    let fetch: () async -> Data?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [TranscriptItem]?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let items {
                    if items.isEmpty {
                        ContentUnavailableView("Empty transcript", systemImage: "doc.text",
                            description: Text("This run captured no transcript."))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(items) { TranscriptItemView(item: $0) }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color.platformWindowBackground)
                    }
                } else if failed {
                    ContentUnavailableView("No transcript", systemImage: "doc.questionmark",
                        description: Text(subtitle?.isEmpty == false
                                          ? subtitle! : "This run's transcript couldn't be read."))
                } else {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            if let data = await fetch(), !data.isEmpty {
                items = ClaudeTranscriptParser.parse(data)
            } else {
                failed = true
            }
        }
    }
}

/// Which automation the editor sheet is on: a fresh one or an existing id.
enum AutomationEdit: Identifiable {
    case new
    case existing(UUID)
    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let u): return u.uuidString
        }
    }
    var editingID: UUID? {
        switch self {
        case .new: return nil
        case .existing(let u): return u
        }
    }
}

struct AutomationsBoardScreen: View {
    let controller: RemoteHostController
    @State private var editing: AutomationEdit?
    @State private var openedRun: AutomationRunRecord?

    var body: some View {
        AutomationKanbanView(
            store: controller.automationStore,
            model: controller.listModel,
            actions: AutomationKanbanView.Actions(
                selectAutomation: { editing = .existing($0) },
                newAutomation: { editing = .new },
                runNow: { controller.runAutomation($0) },
                toggle: { controller.toggleAutomation($0) },
                delete: { controller.deleteAutomation($0) },
                openRun: { openedRun = $0 },
                acknowledge: { controller.acknowledgeRun($0) }))
        // The board supplies the bar's title + icon (see CodingBoardScreen);
        // "+" stays here because this screen owns the editor sheet.
        .sheet(item: $openedRun) { run in
            TranscriptScreen(
                title: controller.automationStore.automation(run.automationID)?.name ?? "Automation Run",
                subtitle: run.detail,
                fetch: { await controller.fetchRunTranscript(run.id) })
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .new } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New automation")
            }
        }
        .sheet(item: $editing) { edit in
            AutomationEditorSheet(controller: controller, editing: edit.editingID) {
                editing = nil
            }
        }
    }
}

/// Wraps the shared `AutomationEditorView` in a sheet with a Cancel affordance;
/// the editor's own footer holds Delete / Run Now / Save, which route over the
/// tunnel and dismiss.
private struct AutomationEditorSheet: View {
    let controller: RemoteHostController
    let editing: UUID?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            AutomationEditorView(
                store: controller.automationStore,
                profiles: controller.profiles,
                editing: editing,
                onSave: { auto in
                    controller.upsertAutomation(auto)
                    onClose()
                },
                onRunNow: { auto in
                    controller.upsertAutomation(auto)
                    controller.runAutomation(auto.id)
                    onClose()
                },
                onDelete: { id in
                    controller.deleteAutomation(id)
                    onClose()
                },
                onEditWorkspace: { _ in })
            .navigationTitle(editing == nil ? "New Automation" : "Edit Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
            }
        }
    }
}

// MARK: - Grid (at a glance)

/// The mirrored terminal grid: each arranged cell shows its live terminal (for
/// running workspaces), so several agents are visible at once; tap a cell's
/// header to open it full-screen. Grid membership is edited on the desktop app
/// and mirrors here read-only.
struct GridScreen: View {
    let controller: RemoteHostController
    /// One live attach per cell, keyed by cell id; reconciled against the
    /// mirrored grid + run states so removed/stopped cells tear down.
    @State private var sessions: [String: AttachSession] = [:]
    /// Pinch-to-zoom magnification of the whole grid: bigger tiles / fewer
    /// columns as you pinch in, an overview of smaller tiles as you pinch out.
    /// `zoom` tracks the live gesture; `zoomBase` is the committed value.
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1

    private var cells: [GridCell] { controller.gridStore.cells }

    private let baseCellHeight: CGFloat = 200
    private let baseMinWidth: CGFloat = 300
    private var cellHeight: CGFloat { baseCellHeight * zoom }

    var body: some View {
        Group {
            if cells.isEmpty {
                ContentUnavailableView("No grid",
                    systemImage: "square.grid.2x2",
                    description: Text("Arrange a grid in the desktop app, or long-press a terminal tab and “Send to Grid.”"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: baseMinWidth * zoom,
                                                           maximum: 700), spacing: 12)],
                              spacing: 12) {
                        ForEach(cells) { cell in cellView(cell) }
                    }
                    .padding(12)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in zoom = min(2.2, max(0.55, zoomBase * v)) }
                        .onEnded { _ in zoomBase = zoom }
                )
            }
        }
        .navigationTitle("Grid")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reconcile() }
        .onChange(of: cells.map(\.id)) { reconcile() }
        .onChange(of: controller.revision) { reconcile() }
        .onDisappear {
            sessions.values.forEach { $0.stop() }
            sessions = [:]
        }
    }

    @ViewBuilder private func cellView(_ cell: GridCell) -> some View {
        let name = controller.profile(for: cell.profileID)?.name ?? "?"
        let accent = controller.profile(for: cell.profileID)?.color.hexInUI ?? "#888888"
        let state = controller.runState(for: cell.profileID)
        let running = state == .running || state == .booting
        let status = controller.tabsModel(for: cell.profileID)?.tabs
            .first { $0.index == cell.windowIndex }?.agentStatus
        // The whole tile is one tap target: the preview terminal is display
        // only (touches pass through), so tapping anywhere "focuses" it —
        // pushes the full workspace terminal for that window.
        NavigationLink {
            WorkspaceScreen(controller: controller, profileID: cell.profileID,
                            initialWindow: cell.windowIndex)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: accent)).frame(width: 8, height: 8)
                    Text(cell.label.isEmpty ? name : cell.label)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    if let status { AgentStatusDot(status: status) }
                    Spacer()
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(8)
                Divider()
                Group {
                    if running, let session = sessions[cell.id] {
                        RemoteTerminalView(session: session, interactive: false,
                                           fixedFontSize: 10)
                            .background(Color.black)
                    } else {
                        ZStack {
                            Color.platformControlBackground
                            VStack(spacing: 4) {
                                Image(systemName: running ? "hourglass" : "moon.zzz")
                                    .foregroundStyle(.secondary)
                                Text(running ? "Attaching…" : "Workspace off")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: cellHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                controller.gridStore.remove(id: cell.id)
                controller.pushGridLayout()
            } label: { Label("Remove from Grid", systemImage: "xmark") }
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(status == .needsInput ? Color.red : Color.primary.opacity(0.12),
                          lineWidth: status == .needsInput ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Attach running cells, stop + drop cells that are gone or stopped.
    private func reconcile() {
        var next: [String: AttachSession] = [:]
        for cell in cells {
            let state = controller.runState(for: cell.profileID)
            guard state == .running || state == .booting else { continue }
            next[cell.id] = sessions[cell.id]
                ?? AttachSession(host: controller.host,
                                 vmID: cell.profileID.uuidString,
                                 windowIndex: cell.windowIndex)
        }
        for (id, s) in sessions where next[id] == nil { s.stop() }
        // Only reassign when the cell set actually changed, so a routine poll
        // doesn't churn @State (and re-mount the live terminals).
        if Set(next.keys) != Set(sessions.keys) { sessions = next }
    }
}
