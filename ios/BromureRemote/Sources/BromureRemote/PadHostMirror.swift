import SwiftUI

// MARK: - iPad host mirror
//
// The iPad counterpart of the macOS `RemoteHostWindow`: a persistent sidebar
// (boards + workspaces, like the desktop's SessionSidebar) with the selected
// board / workspace filling the detail column. The same `RemoteHostController`
// mirror drives everything; the detail column hosts the same content views the
// iPhone pushes onto its stack (WorkspaceScreen, the kanbans, the grid).

/// What the detail column is showing.
enum PadSelection: Hashable {
    case coding
    case automations
    case grid
    case workspace(Profile.ID)
}

struct PadHostMirror: View {
    let controller: RemoteHostController
    let host: RemoteHost
    /// A notification tap's target — selected once the mirror knows about it.
    let openWorkspace: WorkspaceDeepLink?
    /// Back to the server list (the sidebar's "Servers" button).
    let onClose: () -> Void

    @State private var selection: PadSelection?
    @State private var workspaceEdit: WorkspaceEdit?
    @State private var didDeepLink = false
    /// The tmux window a deep-linked workspace should open on (cleared after
    /// the workspace screen consumes it via `initialWindow`).
    @State private var deepLinkWindow: Int?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack { detail }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            controller.start()   // idempotent, same as the iPhone mirror
            AppBadge.set(waitingCount)
            tryDeepLink()
        }
        .onChange(of: waitingCount) { AppBadge.set($0) }
        .onChange(of: controller.revision) { tryDeepLink() }
        // Foreground snap-back: after a long absence the P2P path is almost
        // certainly dead — drop it so the next dial re-establishes fresh.
        .onReceive(NotificationCenter.default.publisher(for: .bromureDidForeground)) { note in
            let away = (note.userInfo?["awaySeconds"] as? TimeInterval) ?? 0
            if away > 20, let pid = host.peerDeviceID {
                P2PBroker.shared.closePeer(pid)
            }
            controller.foregroundKick()
        }
        .alert(item: topPrompt) { decisionAlert($0) }
        .sheet(item: $workspaceEdit) { edit in
            WorkspaceEditorSheet(controller: controller, editing: edit.editingID) {
                workspaceEdit = nil
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if !controller.connected {
                Section {
                    Label(controller.hasSnapshot ? "Reconnecting…" : "Connecting…",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }

            Section("Boards") {
                boardRow(.coding, "Coding Tasks", icon: "checklist", tint: .blue,
                         count: controller.taskStore.tasks.count)
                boardRow(.automations, "Automations", icon: "bolt.badge.clock.fill", tint: .orange,
                         count: controller.automationStore.automations.count)
                boardRow(.grid, "Grid", icon: "square.grid.2x2.fill", tint: .purple,
                         count: controller.gridStore.cells.count)
            }

            Section {
                if controller.listModel.profileRows.isEmpty {
                    Text(controller.hasSnapshot ? "No workspaces on this server."
                                                : "Loading workspaces…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(controller.listModel.profileRows) { row in
                        workspaceRow(row)
                            .tag(PadSelection.workspace(row.id))
                            .contextMenu { workspaceMenu(row) }
                    }
                }
                // The desktop sidebar closes the list with its "+" row; same
                // affordance here (the toolbar "+" stays for muscle memory).
                Button {
                    workspaceEdit = .new
                } label: {
                    Label("New Workspace…", systemImage: "plus")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            } header: {
                HStack {
                    Text("Workspaces")
                    Spacer()
                    if runningCount > 0 {
                        Text("\(runningCount) running")
                            .font(.caption2).foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(host.name.isEmpty ? host.address : host.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onClose()
                } label: {
                    Label("Servers", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Back to servers")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { workspaceEdit = .new } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New workspace")
            }
        }
    }

    private func boardRow(_ sel: PadSelection, _ title: String,
                          icon: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .tag(sel)
    }

    private func workspaceRow(_ row: SessionListModel.ProfileRow) -> some View {
        let accent = Color(hex: row.accentHex)
        let waiting = waitingWindows(row.id).count
        return Label {
            HStack(spacing: 6) {
                Text(row.name).lineLimit(1)
                Spacer()
                if row.compromised {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                }
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(waiting) agents need input")
                } else {
                    stateDot(row.state)
                }
            }
        } icon: {
            Image(systemName: "cpu").foregroundStyle(accent)
        }
    }

    @ViewBuilder private func workspaceMenu(_ row: SessionListModel.ProfileRow) -> some View {
        Button {
            workspaceEdit = .existing(row.id)
        } label: { Label("Workspace Settings…", systemImage: "gearshape") }
        Divider()
        switch row.state {
        case .running, .booting:
            Button { controller.newTab(row.id) } label: {
                Label("New Terminal", systemImage: "plus.rectangle.on.rectangle")
            }
            Button { controller.suspendWorkspace(row.id) } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            Button { controller.restartWorkspace(row.id) } label: {
                Label("Reboot", systemImage: "arrow.clockwise.circle")
            }
            Button(role: .destructive) { controller.shutdownWorkspace(row.id) } label: {
                Label("Shut Down", systemImage: "power")
            }
        case .suspended, .off:
            Button { controller.startWorkspace(row.id) } label: {
                Label("Start", systemImage: "play.circle")
            }
        }
    }

    @ViewBuilder private func stateDot(_ s: SessionListModel.RunState) -> some View {
        switch s {
        case .running:   PulsingDot(color: .green, active: true)
        case .booting:   PulsingDot(color: .orange, active: true)
        case .suspended: PulsingDot(color: .yellow, active: false)
        case .off:       PulsingDot(color: .secondary, active: false)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .coding:
            CodingBoardScreen(controller: controller)
        case .automations:
            AutomationsBoardScreen(controller: controller)
        case .grid:
            GridScreen(controller: controller)
        case .workspace(let id):
            // .id() forces a fresh screen per workspace — its @StateObject
            // browser bridge and session caches are keyed to the profile at
            // init and must not survive a sidebar switch.
            WorkspaceScreen(controller: controller, profileID: id,
                            initialWindow: consumeDeepLinkWindow(id))
                .id(id)
        case nil:
            ContentUnavailableView("Select a workspace",
                systemImage: "cpu",
                description: Text("Pick a workspace or a board from the sidebar."))
        }
    }

    // MARK: Waiting agents / deep link

    private var runningCount: Int {
        controller.listModel.profileRows.filter { $0.state == .running }.count
    }

    /// Tab indices of agents paused on a question for one workspace.
    private func waitingWindows(_ id: Profile.ID) -> [Int] {
        controller.tabsModel(for: id)?.tabs
            .filter { $0.agentStatus == .needsInput }
            .map(\.index) ?? []
    }

    private var waitingCount: Int {
        controller.listModel.entries.reduce(0) { acc, entry in
            acc + entry.model.tabs.filter { $0.agentStatus == .needsInput }.count
        }
    }

    /// Select the deep-linked workspace the moment the mirror knows it exists.
    private func tryDeepLink() {
        guard !didDeepLink, let target = openWorkspace,
              controller.listModel.profileRows.contains(where: { $0.id == target.profileID })
        else { return }
        didDeepLink = true
        deepLinkWindow = target.window
        selection = .workspace(target.profileID)
    }

    /// Hand the pending deep-link window to its workspace exactly once.
    private func consumeDeepLinkWindow(_ id: Profile.ID) -> Int? {
        guard didDeepLink, let target = openWorkspace, target.profileID == id else { return nil }
        return deepLinkWindow
    }

    // MARK: Decision prompts (same wire as the iPhone mirror / macOS NSAlert)

    private var topPrompt: Binding<RemoteHostController.DecisionPrompt?> {
        Binding(get: { controller.decisionPrompts.first }, set: { _ in })
    }

    private func decisionAlert(_ prompt: RemoteHostController.DecisionPrompt) -> Alert {
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
