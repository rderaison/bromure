import SwiftUI

// MARK: - Host mirror (iOS)
//
// Owns a `RemoteHostController` — the SAME poll/reconcile engine the macOS
// mirror window uses — and renders its live state on a small screen: the
// workspace list, the automation and coding-task boards, and per-workspace
// detail (terminals, dashboard, docker, files). Every list here is driven by
// the reused mirror stores, refreshed by the 0.75 s /state poll.

struct HostMirrorScreen: View {
    let host: RemoteHost
    @State private var controller: RemoteHostController

    init(host: RemoteHost) {
        self.host = host
        _controller = State(initialValue: RemoteHostController(host: host))
    }

    var body: some View {
        List {
            if !controller.connected {
                Section {
                    Label(controller.hasSnapshot ? "Reconnecting…" : "Connecting…",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                    if let err = controller.lastError, !controller.connected, controller.hasSnapshot {
                        Text(err).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Boards") {
                NavigationLink {
                    CodingBoardScreen(controller: controller)
                } label: {
                    Label("Coding Tasks", systemImage: "checklist")
                        .badge(controller.taskStore.tasks.count)
                }
                NavigationLink {
                    AutomationsBoardScreen(controller: controller)
                } label: {
                    Label("Automations", systemImage: "bolt.badge.clock")
                        .badge(controller.automationStore.automations.count)
                }
            }

            Section {
                NavigationLink {
                    GridScreen(controller: controller)
                } label: {
                    Label("Grid", systemImage: "square.grid.2x2")
                        .badge(controller.gridStore.cells.count)
                }
                if waitingAgents.isEmpty {
                    Label("No agents need input", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(waitingAgents) { agent in
                        NavigationLink {
                            WorkspaceScreen(controller: controller,
                                            profileID: agent.profileID,
                                            initialWindow: agent.windowIndex)
                        } label: {
                            waitingAgentRow(agent)
                        }
                    }
                }
            } header: {
                Text("At a Glance")
            } footer: {
                if !waitingAgents.isEmpty {
                    Text("These coding agents are paused waiting for your answer — tap to reply.")
                }
            }

            Section("Workspaces") {
                if controller.listModel.profileRows.isEmpty && controller.hasSnapshot {
                    Text("No workspaces on this server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.listModel.profileRows) { row in
                    NavigationLink {
                        WorkspaceScreen(controller: controller, profileID: row.id)
                    } label: {
                        workspaceRow(row)
                    }
                }
            }
        }
        .navigationTitle(host.name.isEmpty ? host.address : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            controller.start()
            AppBadge.set(waitingAgents.count)
        }
        .onDisappear { controller.stop() }
        // Mirror the "agents waiting for input" count onto the app-icon badge.
        .onChange(of: waitingAgents.count) { AppBadge.set($0) }
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

    private func waitingAgentRow(_ agent: WaitingAgent) -> some View {
        HStack(spacing: 10) {
            AgentStatusDot(status: .needsInput)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.tabLabel).font(.body)
                Text(agent.workspaceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.red)
        }
    }

    private func workspaceRow(_ row: SessionListModel.ProfileRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: row.accentHex))
                .frame(width: 10, height: 10)
                .overlay(stateRing(row.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.body)
                Text(stateLabel(row.state)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if row.compromised {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func stateRing(_ s: SessionListModel.RunState) -> some View {
        switch s {
        case .running:   Circle().stroke(.green, lineWidth: 2).frame(width: 16, height: 16)
        case .booting:   Circle().stroke(.orange, lineWidth: 2).frame(width: 16, height: 16)
        case .suspended: Circle().stroke(.yellow, lineWidth: 2).frame(width: 16, height: 16)
        case .off:       EmptyView()
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
                openTranscript: { _ in }))
        .navigationTitle("Coding Tasks")
        .navigationBarTitleDisplayMode(.inline)
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
                openRun: { _ in },
                acknowledge: { controller.acknowledgeRun($0) }))
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
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

    private var cells: [GridCell] { controller.gridStore.cells }

    var body: some View {
        Group {
            if cells.isEmpty {
                ContentUnavailableView("No grid",
                    systemImage: "square.grid.2x2",
                    description: Text("Arrange a grid in the desktop app — it mirrors here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 700), spacing: 12)],
                              spacing: 12) {
                        ForEach(cells) { cell in cellView(cell) }
                    }
                    .padding(12)
                }
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
        VStack(spacing: 0) {
            NavigationLink {
                WorkspaceScreen(controller: controller, profileID: cell.profileID,
                                initialWindow: cell.windowIndex)
            } label: {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            if running, let session = sessions[cell.id] {
                RemoteTerminalView(session: session)
                    .frame(height: 220)
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
                .frame(height: 220)
            }
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
