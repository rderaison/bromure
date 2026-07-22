import SwiftUI

// MARK: - Workspace detail (iOS)
//
// One remote workspace, on a small screen: a segmented switch between the live
// terminals (SwiftTerm over the in-process attach pump), the VM dashboard,
// Docker, and the Files browser — each backed by the reused shared views and
// the mirror controller's tunnel actions.

struct WorkspaceScreen: View {
    let controller: RemoteHostController
    let profileID: Profile.ID

    enum Pane: String, CaseIterable, Identifiable {
        case terminals = "Terminals"
        case dashboard = "Info"
        case docker = "Docker"
        case files = "Files"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .terminals: "terminal"
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .docker: "shippingbox"
            case .files: "folder"
            }
        }
    }
    @State private var pane: Pane = .terminals

    private var runState: SessionListModel.RunState { controller.runState(for: profileID) }
    private var isRunning: Bool { runState == .running || runState == .booting }
    private var profileName: String {
        controller.profile(for: profileID)?.name ?? "Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $pane) {
                ForEach(availablePanes) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(profileName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isRunning) { _, running in
            if !running && pane != .dashboard { pane = .dashboard }
        }
    }

    private var availablePanes: [Pane] {
        isRunning ? Pane.allCases : [.dashboard]
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .terminals: TerminalsPane(controller: controller, profileID: profileID)
        case .dashboard: dashboard
        case .docker:    docker
        case .files:     files
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        let spec = controller.specs[profileID] ?? .init()
        let profile = controller.profile(for: profileID)
            ?? Profile(id: profileID, name: profileName, tool: .claude, authMode: .token)
        return VMDashboardView(
            model: controller.tabsModel(for: profileID),
            profile: profile,
            accentHex: profile.color.hexInUI,
            state: runState,
            vCPUs: spec.cpus,
            diskAllocatedBytes: spec.diskAllocatedBytes,
            diskCapacityBytes: spec.diskCapacityBytes,
            startedAt: controller.bootTimes[profileID],
            onNewTerminal: { controller.newTab(profileID) },
            onSuspend: { controller.suspendWorkspace(profileID) },
            onReboot: { controller.restartWorkspace(profileID) },
            onShutdown: { controller.shutdownWorkspace(profileID) },
            onResume: { controller.startWorkspace(profileID) })
    }

    // MARK: Docker

    @ViewBuilder private var docker: some View {
        if let model = controller.tabsModel(for: profileID) {
            DockerDashboardView(
                model: model,
                accentHex: controller.profile(for: profileID)?.color.hexInUI ?? "#3B82F6",
                onRun: { controller.dockerAction(profileID, dockerRunBody($0)) },
                onStart: { controller.dockerAction(profileID, ["action": "start", "id": $0]) },
                onStop: { controller.dockerAction(profileID, ["action": "stop", "id": $0]) },
                onRemove: { controller.dockerAction(profileID, ["action": "remove", "id": $0]) },
                onAttach: { id, _ in controller.dockerAction(profileID, ["action": "attach", "id": id]) },
                onLogs: { controller.dockerAction(profileID, ["action": "logs", "id": $0]) },
                onVolumeCreate: { controller.dockerAction(profileID, ["action": "volume-create", "name": $0]) },
                onVolumeRemove: { controller.dockerAction(profileID, ["action": "volume-remove", "name": $0]) },
                onInstallBinfmt: { controller.dockerAction(profileID, ["action": "binfmt-install"]) },
                onUninstallBinfmt: { controller.dockerAction(profileID, ["action": "binfmt-uninstall"]) })
        } else {
            ContentUnavailableView("Docker unavailable", systemImage: "shippingbox",
                description: Text("Start the workspace to see its containers."))
        }
    }

    private func dockerRunBody(_ spec: ACAppDelegate.DockerRunSpec) -> [String: Any] {
        var b: [String: Any] = ["action": "run", "image": spec.image]
        if !spec.name.isEmpty { b["name"] = spec.name }
        if !spec.ports.isEmpty { b["ports"] = spec.ports }
        if !spec.env.isEmpty { b["env"] = spec.env }
        if !spec.volumes.isEmpty { b["volumes"] = spec.volumes }
        b["inheritEnv"] = spec.inheritEnv
        b["inheritProxy"] = spec.inheritProxy
        b["interactive"] = spec.interactive
        return b
    }

    // MARK: Files

    private var files: some View {
        FilesPane(controller: controller, profileID: profileID,
                  mounts: controller.mounts[profileID] ?? [])
    }
}

// MARK: - Terminals pane

/// The workspace's tmux windows as a picker + one live SwiftTerm surface. Each
/// window index gets its own `AttachSession`, cached so switching tabs doesn't
/// re-handshake.
private struct TerminalsPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    @State private var sessions: [Int: AttachSession] = [:]
    @State private var selectedWindow: Int?

    private var model: TabsModel? { controller.tabsModel(for: profileID) }
    private var tabs: [TabsModel.Tab] { model?.tabs ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs) { tab in
                            tabChip(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                Divider()
            }
            if let win = effectiveWindow {
                RemoteTerminalView(session: session(for: win))
                    .id("\(profileID)-\(win)")
                    .background(Color.black)
            } else {
                ContentUnavailableView("No terminal", systemImage: "terminal",
                    description: Text("This workspace has no open windows yet."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { controller.newTab(profileID) } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("New terminal")
            }
        }
    }

    private var effectiveWindow: Int? {
        if let selectedWindow, tabs.contains(where: { $0.index == selectedWindow }) {
            return selectedWindow
        }
        return model?.activeTab?.index ?? tabs.first?.index
    }

    private func session(for window: Int) -> AttachSession {
        if let s = sessions[window] { return s }
        let s = AttachSession(host: controller.host, vmID: profileID.uuidString, windowIndex: window)
        sessions[window] = s
        return s
    }

    @ViewBuilder private func tabChip(_ tab: TabsModel.Tab) -> some View {
        let selected = tab.index == effectiveWindow
        Button {
            selectedWindow = tab.index
            controller.selectTab(profileID, index: tab.index)
        } label: {
            HStack(spacing: 5) {
                AgentStatusDot(status: tab.agentStatus)
                Text(tab.shownLabel.isEmpty ? "shell" : tab.shownLabel)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                controller.closeTab(profileID, index: tab.index)
                sessions[tab.index]?.stop()
                sessions[tab.index] = nil
            } label: { Label("Close", systemImage: "xmark") }
        }
    }
}

// MARK: - Files pane

/// The reused `FileBrowserView`, backed by the workspace's guest file op bridge
/// over the tunnel. Integrates with the iOS Files app via `lastDownloaded`
/// (a downloaded/opened file → share sheet → Save to Files).
private struct FilesPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    let mounts: [String]
    /// Built once (not per-render) so the browser keeps its directory + doesn't
    /// re-list on every update. The download share sheet and the upload importer
    /// live inside FileBrowserView (iOS).
    @State private var model: FileBrowserModel?

    var body: some View {
        Group {
            if let model {
                FileBrowserView(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model == nil { model = makeModel() } }
    }

    private func makeModel() -> FileBrowserModel {
        var locations: [FileBrowserLocation] = [
            FileBrowserLocation(name: "Home", backing: .guest,
                                guestPath: "/home/ubuntu", symbol: "house")
        ]
        for m in mounts {
            locations.append(FileBrowserLocation(
                name: (m as NSString).lastPathComponent, backing: .guest,
                guestPath: m, symbol: "externaldrive"))
        }
        return FileBrowserModel(
            locations: locations,
            cacheKey: profileID.uuidString,
            guestOp: { op in try await controller.guestFileOp(profileID, op: op) })
    }
}
