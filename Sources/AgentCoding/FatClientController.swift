import AppKit
import Foundation
import SwiftUI

// MARK: - Fat-client mirror controller

/// Drives the fat-client mirror of ONE remote bromure-ac host. It owns the same
/// model objects the local window uses — `SessionListModel`, `GridLayoutStore`,
/// `ScheduledAutomationStore`, per-workspace `TabsModel` — and keeps them in
/// sync by polling the remote's control-plane over the SSH tunnel. The remote
/// UI therefore renders 1:1 through the very same SwiftUI views
/// (`SessionSidebar`, `GridStageView`). Actions (start/stop, tab/worktree ops,
/// automation edits, layout changes) are sent back over the tunnel; the remote
/// executes them and the next poll reflects the result — so every client
/// converges on the host's authoritative state.
@MainActor
@Observable
final class RemoteHostController {
    let host: RemoteHost
    /// The reused source-list model (workspace rows + running entries).
    let listModel = SessionListModel()
    /// Mirror of the remote grid (StageLayout). Persisted to a per-host file so
    /// it never clobbers the local grid.
    let gridStore: GridLayoutStore
    /// Mirror of the remote automations.
    let automationStore: ScheduledAutomationStore

    /// Connection health, surfaced in the window chrome.
    var connected = false
    var lastError: String?

    /// Per-workspace tab models (live, shared into `VMEntry` by reference so the
    /// sidebar tab rows and the grid update together).
    private var tabsModels: [Profile.ID: TabsModel] = [:]
    /// Minimal mirrored profiles (id/name/color/tool) — the grid needs a
    /// `Profile` for appearance and the deleted-workspace check.
    private(set) var profilesByID: [Profile.ID: Profile] = [:]

    private var pollTimer: Timer?
    private let pollQueue = DispatchQueue(label: "io.bromure.fatclient.poll")
    private var polling = false
    /// Bumped every apply; the window observes it to refresh the stage.
    private(set) var revision = 0

    /// The remote's workspace subnet (CIDR, e.g. "192.168.64.0/24"), read from
    /// `/state`. Needed by the browser pane's PAC and the fleet router to decide
    /// which destinations to tunnel.
    private(set) var vmnetSubnet: String?
    /// Auto-started SOCKS5 forwarder into the remote subnet; its port feeds the
    /// browser pane's PAC and `curl --socks5`. Nil until `start()`.
    private(set) var socks: RemoteSocksForwarder?
    /// Optional system-wide utun tunnel (any local process → remote subnet at its
    /// literal address). Off unless `BROMURE_FATCLIENT_UTUN` is set (it needs the
    /// privileged helper); the browser pane works via SOCKS without it.
    private var tunnel: FatClientTunnel?

    init(host: RemoteHost) {
        self.host = host
        let base = RemoteTransport.dir
            .appendingPathComponent("hosts", isDirectory: true)
            .appendingPathComponent(host.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        gridStore = GridLayoutStore(saveURL: base.appendingPathComponent("grid-layout.json"))
        automationStore = ScheduledAutomationStore(fileURL: base.appendingPathComponent("automations.json"))
    }

    // MARK: Polling

    func start() {
        pollOnce()
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        // Stand up the subnet tunnel entry point (SOCKS) so the browser pane and
        // `curl --socks5` can reach the remote guests as soon as the host is up.
        if socks == nil {
            socks = RemoteSocksForwarder(host: host)
            if let p = socks?.port {
                FatClientLog.log("socks: 127.0.0.1:\(p) → \(host.connectLabel) (remote subnet)")
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        socks?.stop()
        socks = nil
        tunnel?.stop()
        tunnel = nil
    }

    private func pollOnce() {
        if polling { return }   // don't stack requests if the link is slow
        polling = true
        let host = self.host
        pollQueue.async { [weak self] in
            let client = RemoteTransport.client(for: host)
            let resp = try? client.request("GET", "/state")
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                if let resp, resp.status == 200 {
                    if !self.connected { FatClientLog.log("poll: connected, status 200") }
                    self.connected = true
                    self.lastError = nil
                    self.apply(resp.json)
                } else {
                    if self.connected || self.revision == 0 {
                        FatClientLog.log("poll: FAILED status=\(resp?.status ?? -1)")
                    }
                    self.connected = false
                    self.lastError = "not reachable"
                }
            }
        }
    }

    /// Fire an arbitrary control-plane request off-main (ssh blocks), then poll.
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil,
                      then refresh: Bool = true) {
        let host = self.host
        pollQueue.async { [weak self] in
            let client = RemoteTransport.client(for: host)
            _ = try? client.request(method, path, body: body)
            if refresh {
                DispatchQueue.main.async { self?.pollOnce() }
            }
        }
    }

    // MARK: Apply snapshot → models

    private func apply(_ snapshot: [String: Any]) {
        let workspaces = (snapshot["workspaces"] as? [[String: Any]]) ?? []
        let vms = (snapshot["vms"] as? [[String: Any]]) ?? []
        let grid = (snapshot["gridLayout"] as? [String: Any]) ?? ["cells": []]
        let autos = (snapshot["automations"] as? [String: Any]) ?? [:]

        if let cidr = snapshot["vmnetSubnet"] as? String, cidr != vmnetSubnet {
            vmnetSubnet = cidr
            FatClientLog.log("apply: remote vmnet subnet = \(cidr)")
            // Optional system-wide tunnel: route the remote subnet literally to a
            // utun (needs the privileged helper; degrades to SOCKS if unavailable).
            if tunnel == nil, ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_UTUN"] != nil {
                let t = FatClientTunnel(host: host, localCIDR: cidr)
                tunnel = t.start() ? t : nil
            }
        }

        applyWorkspaces(workspaces, vms: vms)
        applyGrid(grid)
        applyAutomations(autos)
        revision &+= 1
        if revision == 1 {
            FatClientLog.log("apply: \(workspaces.count) workspaces, \(vms.count) running, "
                + "\(gridStore.cells.count) grid cells, \(automationStore.automations.count) automations")
        }
    }

    private func applyWorkspaces(_ workspaces: [[String: Any]], vms: [[String: Any]]) {
        // ProfileRows (all workspaces) + minimal mirrored Profiles.
        var rows: [SessionListModel.ProfileRow] = []
        var newProfiles: [Profile.ID: Profile] = [:]
        for w in workspaces {
            guard let idStr = w["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            let name = w["name"] as? String ?? "?"
            let accentHex = w["accentHex"] as? String ?? "#888888"
            let state: SessionListModel.RunState
            switch w["state"] as? String {
            case "running":   state = .running
            case "booting":   state = .booting
            case "suspended": state = .suspended
            default:          state = .off
            }
            rows.append(SessionListModel.ProfileRow(
                id: id, name: name, accentHex: accentHex, state: state,
                compromised: (w["compromised"] as? Bool) ?? false))

            var p = Profile(
                id: id, name: name,
                tool: Profile.Tool(rawValue: w["tool"] as? String ?? "") ?? .claude,
                authMode: Profile.AuthMode(rawValue: w["authMode"] as? String ?? "") ?? .token)
            p.color = ProfileColor(rawValue: w["color"] as? String ?? "") ?? .gray
            newProfiles[id] = p
        }
        profilesByID = newProfiles
        if listModel.profileRows != rows { listModel.profileRows = rows }

        // Running entries: one VMEntry per running VM, carrying a live TabsModel.
        var entries: [SessionListModel.VMEntry] = []
        var liveIDs = Set<Profile.ID>()
        for vm in vms {
            guard let idStr = vm["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            liveIDs.insert(id)
            let model = tabsModels[id] ?? {
                let m = TabsModel(); tabsModels[id] = m; return m
            }()
            model.accentHex = vm["accentHex"] as? String
                ?? profilesByID[id]?.color.hexInUI ?? "#3B82F6"
            model.ipAddress = (vm["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            model.vmCPU = vm["cpu"] as? Double ?? 0
            model.vmMemUsedKB = vm["memUsedKB"] as? Int ?? 0
            model.vmMemTotalKB = vm["memTotalKB"] as? Int ?? 0
            model.vmLoad = vm["load"] as? Double ?? 0
            model.vmDiskUsedKB = vm["diskUsedKB"] as? Int ?? 0
            model.vmDiskTotalKB = vm["diskTotalKB"] as? Int ?? 0
            applyRemoteTabs(model, (vm["tabs"] as? [[String: Any]]) ?? [])
            let name = vm["name"] as? String ?? profilesByID[id]?.name ?? "?"
            entries.append(SessionListModel.VMEntry(
                id: id, name: name,
                accentHex: model.accentHex, model: model))
        }
        tabsModels = tabsModels.filter { liveIDs.contains($0.key) }
        // Rebuild entries only when the id set changes (the shared TabsModels
        // update in place, so the sidebar tab rows still refresh live).
        if Set(listModel.entries.map(\.id)) != liveIDs {
            listModel.entries = entries
        }
    }

    /// Reconcile a remote roster (array of tab dicts) into a `TabsModel`.
    /// Mirrors `SessionPane.applyTabList` but operates on the model directly.
    private func applyRemoteTabs(_ model: TabsModel, _ tabs: [[String: Any]]) {
        if model.tabs.count > tabs.count {
            model.tabs.removeLast(model.tabs.count - tabs.count)
        }
        while model.tabs.count < tabs.count {
            model.tabs.append(TabsModel.Tab(label: "", index: 0))
        }
        var activePos = model.activeIndex
        for (i, t) in tabs.enumerated() {
            let tab = model.tabs[i]
            let idx = t["index"] as? Int ?? i
            let title = t["title"] as? String ?? "shell"
            if tab.index != idx { tab.index = idx }
            if tab.label != title { tab.label = title }
            // `title` is already display-or-label; mirror it into `display` so
            // `shownLabel`, worktree ordering and the Merge-tab check all work.
            let display: String? = title
            if tab.display != display { tab.display = display }
            let wb = t["worktreeBranch"] as? String
            if tab.worktreeBranch != wb { tab.worktreeBranch = wb }
            let pb = t["parentBranch"] as? String
            if tab.parentBranch != pb { tab.parentBranch = pb }
            let rr = t["rootRepo"] as? String
            if tab.rootRepo != rr { tab.rootRepo = rr }
            let repoRoot = t["repoRoot"] as? String
            if tab.repoRoot != repoRoot { tab.repoRoot = repoRoot }
            let cwd = t["cwd"] as? String
            if tab.cwd != cwd { tab.cwd = cwd }
            let containerID = t["containerID"] as? String
            if tab.containerID != containerID { tab.containerID = containerID }
            if let s = t["agentStatus"] as? String, let st = AgentStatus(rawValue: s) {
                if tab.agentStatus != st { tab.agentStatus = st }
            } else if tab.agentStatus != .done {
                tab.agentStatus = .done
            }
            if (t["active"] as? Bool) == true { activePos = i }
        }
        if activePos >= model.tabs.count { activePos = max(0, model.tabs.count - 1) }
        if model.activeIndex != activePos { model.activeIndex = activePos }
    }

    private func applyGrid(_ grid: [String: Any]) {
        let cells = (grid["cells"] as? [[String: Any]]) ?? []
        let parsed: [GridCell] = cells.compactMap { c in
            guard let pidStr = c["profileID"] as? String, let pid = UUID(uuidString: pidStr),
                  let idx = c["windowIndex"] as? Int else { return nil }
            return GridCell(profileID: pid, windowIndex: idx, label: c["label"] as? String ?? "")
        }
        if gridStore.cells != parsed { gridStore.replaceAll(parsed) }
        gridStore.focusedCellID = grid["focusedCellID"] as? String
        gridStore.zoomedCellID = grid["zoomedCellID"] as? String
    }

    private func applyAutomations(_ autos: [String: Any]) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        func decode<T: Decodable>(_ arr: [[String: Any]], _ type: T.Type) -> [T] {
            arr.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? dec.decode(T.self, from: data)
            }
        }
        let automations = decode((autos["automations"] as? [[String: Any]]) ?? [], ScheduledAutomation.self)
        let runs = decode((autos["runs"] as? [[String: Any]]) ?? [], AutomationRunRecord.self)
        automationStore.mirror(automations: automations, runs: runs)
    }

    // MARK: Actions (client → remote), routed over the tunnel

    /// This client's public key, to authorize on the remote's `authorized_keys`.
    var clientPublicKey: String? { RemoteTransport.clientPublicKey() }
    /// True once a snapshot has been applied at least once (distinguishes the
    /// first "Connecting…" from a genuine "no workspaces on the remote").
    var hasSnapshot: Bool { revision > 0 }

    func profile(for id: Profile.ID) -> Profile? { profilesByID[id] }
    func tabsModel(for id: Profile.ID) -> TabsModel? { tabsModels[id] }
    func runState(for id: Profile.ID) -> SessionListModel.RunState {
        listModel.profileRows.first { $0.id == id }?.state ?? .off
    }

    private func seg(_ id: Profile.ID) -> String { ControlClient.encodeSegment(id.uuidString) }

    func startWorkspace(_ id: Profile.ID) {
        send("POST", "/vms", body: ["profile": id.uuidString, "detach": true])
    }
    func shutdownWorkspace(_ id: Profile.ID) {
        send("DELETE", "/vms/\(seg(id))", body: ["action": "shutdown"])
    }
    func suspendWorkspace(_ id: Profile.ID) {
        send("DELETE", "/vms/\(seg(id))", body: ["action": "suspend"])
    }
    func restartWorkspace(_ id: Profile.ID) {
        send("POST", "/vms/\(seg(id))/reboot", body: ["mode": "soft"])
    }
    func selectTab(_ id: Profile.ID, index: Int) {
        // Optimistic local echo; the roster confirms.
        if let m = tabsModels[id], let pos = m.tabs.firstIndex(where: { $0.index == index }) {
            m.activeIndex = pos
        }
        send("POST", "/sessions/\(seg(id))/tab", body: ["action": "select", "index": index])
    }
    func newTab(_ id: Profile.ID) {
        send("POST", "/sessions/\(seg(id))/tab", body: ["action": "new"])
    }
    func closeTab(_ id: Profile.ID, index: Int) {
        send("POST", "/sessions/\(seg(id))/tab", body: ["action": "close", "index": index])
    }
    /// Worktree actions that are fully derivable from the mirrored tab
    /// (remove / attach-terminal). Prompt-driven ones (new worktree, merge,
    /// resolve, seed-automation) open a flow that isn't mirrored in v1 and are
    /// left to the host's own GUI. The mirror still DISPLAYS all worktrees 1:1.
    func worktree(_ id: Profile.ID, index: Int, action: TabAction) {
        guard let m = tabsModels[id], let tab = m.tabs.first(where: { $0.index == index }) else { return }
        let root = tab.rootRepo ?? tab.repoRoot ?? ""
        let branch = tab.worktreeBranch ?? ""
        let a: String
        switch action {
        case .removeWorktree: a = "remove"
        case .attachTerminal: a = "terminal"
        default: return
        }
        guard !root.isEmpty, !branch.isEmpty else { return }
        send("POST", "/sessions/\(seg(id))/worktree", body: ["action": a, "args": [root, branch]])
    }

    // Grid edits (last-writer-wins whole-layout replacement).
    func pushGridLayout() {
        let cells: [[String: Any]] = gridStore.cells.map {
            ["profileID": $0.profileID.uuidString, "windowIndex": $0.windowIndex, "label": $0.label]
        }
        var body: [String: Any] = ["cells": cells]
        if let f = gridStore.focusedCellID { body["focusedCellID"] = f }
        send("POST", "/grid-layout", body: body, then: false)
    }

    // Automation edits.
    func runAutomation(_ id: UUID) { send("POST", "/automations/\(ControlClient.encodeSegment(id.uuidString))/run") }
    func toggleAutomation(_ id: UUID) { send("POST", "/automations/\(ControlClient.encodeSegment(id.uuidString))/toggle") }
    func deleteAutomation(_ id: UUID) { send("DELETE", "/automations/\(ControlClient.encodeSegment(id.uuidString))") }
    func upsertAutomation(_ automation: ScheduledAutomation) {
        guard let doc = ACAppDelegate.codableToDict(automation) else { return }
        send("POST", "/automations", body: doc)
    }
}

// MARK: - Connection status overlay

/// Shown over the stage while the mirror isn't connected, so an empty sidebar
/// reads as "not connected yet" (and how to fix it) instead of "no workspaces".
/// The fat client authenticates by SSH public key only — no password prompt —
/// so the common first-run failure is simply that this Mac's key hasn't been
/// authorized on the remote.
struct RemoteConnectionStatusView: View {
    @Bindable var controller: RemoteHostController

    var body: some View {
        VStack(spacing: 16) {
            if !controller.connected {
                ProgressView().controlSize(.large)
                Text(controller.hasSnapshot || controller.lastError == nil
                     ? "Connecting to \(controller.host.connectLabel)…"
                     : "Can't reach \(controller.host.connectLabel)")
                    .font(.headline)
                if controller.lastError != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This Mac authenticates to the remote Bromure by SSH key. If the remote has remote access enabled, authorize this Mac's key on it:")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Text(authorizeCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(authorizeCommand, forType: .string)
                            }
                        }
                        Text("Enable remote access on the remote with: bromure-ac remote enable")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: 460)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var authorizeCommand: String {
        "bromure-ac remote key add '\(controller.clientPublicKey ?? "<generating key…>")'"
    }
}

// MARK: - Fat-client mirror window

/// The fat-client window for one remote host. Reuses the EXACT same
/// `SessionSidebar` and `GridStageView` the local window uses, driven by a
/// `RemoteHostController`, so a remote bromure-ac renders 1:1. The stage shows
/// the mirrored grid, or a selected workspace's terminal — both attaching over
/// the SSH tunnel via `__attach-window --remote`.
@MainActor
final class RemoteHostWindow: NSWindow {
    let controller: RemoteHostController

    private let stage = NSView()
    private var sidebarHost: NSHostingView<SessionSidebar>!
    private var statusHost: NSHostingView<RemoteConnectionStatusView>!
    private var gridView: GridStageView?
    private var termControllers: [Profile.ID: TerminalSessionController] = [:]
    private var mountedTermView: TerminalSurfaceView?
    private var shownWorkspace: Profile.ID?
    private var shownWindowIndex: Int?

    // Browser pane (fat-client): a local Chromium VM per remote workspace whose
    // page traffic is tunneled to the remote subnet via the SOCKS forwarder.
    private var browserPaneHost: NSView!
    private var browserWidthConstraint: NSLayoutConstraint!
    private var browserControllers: [Profile.ID: WorkspaceBrowserController] = [:]
    private var browserModels: [Profile.ID: BrowserPaneModel] = [:]
    /// Relays the remote agent's browser MCP to the local pane's browser.
    private var browserRelays: [Profile.ID: BrowserMCPRelayClient] = [:]
    private var browserOpen: Set<Profile.ID> = []
    private var shownBrowser: Profile.ID?
    /// Test hook: auto-open the browser pane once a workspace is selected.
    private let autoBrowser = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_BROWSER"] != nil
    private var lastRevision = -1
    private var refreshTimer: Timer?
    /// Test hook: name of a workspace to auto-select once it's running (mounts
    /// its remote terminal in the stage without needing a curated grid).
    private let autoSelectName = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_SELECT"]
    private var didAutoSelect = false

    init(controller: RemoteHostController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        title = "Remote — \(controller.host.name)"
        isReleasedWhenClosed = false
        buildLayout()
        showGrid()
        controller.start()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStageIfNeeded() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    override func close() {
        refreshTimer?.invalidate(); refreshTimer = nil
        controller.stop()
        gridView?.retireAll()
        for (_, c) in termControllers { c.retireAll() }
        termControllers.removeAll()
        for (_, r) in browserRelays { r.stop() }
        browserRelays.removeAll()
        for (_, c) in browserControllers { c.stop() }
        browserControllers.removeAll()
        super.close()
    }

    /// ⌃⌘B toggles the browser pane for the shown workspace (mirrors the local
    /// window's shortcut).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control],
           event.charactersIgnoringModifiers?.lowercased() == "b" {
            toggleBrowser(for: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func buildLayout() {
        guard let content = contentView else { return }
        let sidebar = makeSidebar()
        sidebarHost = NSHostingView(rootView: sidebar)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(sidebarHost)
        content.addSubview(stage)
        // Browser pane sits to the right of the stage; width animates 0 ↔ N.
        let browser = NSView()
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.wantsLayer = true
        browser.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(browser)
        browserPaneHost = browser
        browserWidthConstraint = browser.widthAnchor.constraint(equalToConstant: 0)
        // Connection-status overlay covers the stage until we're connected.
        statusHost = NSHostingView(rootView: RemoteConnectionStatusView(controller: controller))
        statusHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusHost)
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarHost.widthAnchor.constraint(equalToConstant: 240),
            stage.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            stage.trailingAnchor.constraint(equalTo: browser.leadingAnchor),
            stage.topAnchor.constraint(equalTo: content.topAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            browser.topAnchor.constraint(equalTo: content.topAnchor),
            browser.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            browserWidthConstraint,
            statusHost.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            statusHost.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            statusHost.topAnchor.constraint(equalTo: stage.topAnchor),
            statusHost.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
    }

    // MARK: Browser pane

    private func browserModel(for id: Profile.ID) -> BrowserPaneModel {
        if let m = browserModels[id] { return m }
        let m = BrowserPaneModel(); browserModels[id] = m; return m
    }

    /// Lazily create the workspace's browser controller in remote-proxy mode.
    /// Nil until the remote subnet + SOCKS port are both known (first `/state`).
    private func browserController(for id: Profile.ID) -> WorkspaceBrowserController? {
        if let c = browserControllers[id] { return c }
        guard let subnet = controller.vmnetSubnet, let port = controller.socks?.port else { return nil }
        let persistent = controller.profile(for: id)?.browserPersistent ?? false
        let c = WorkspaceBrowserController(
            model: browserModel(for: id), workspaceID: id, persistent: persistent,
            remoteProxy: .init(subnetCIDR: subnet, socksPort: port))
        browserControllers[id] = c
        return c
    }

    /// Toggle the browser pane for the shown workspace (⌃⌘B), or open it for a
    /// specific workspace. Needs the tunnel up (subnet + SOCKS), so it no-ops
    /// until the first `/state` arrives.
    func toggleBrowser(for id: Profile.ID?) {
        guard let id = id ?? shownWorkspace else { return }
        if browserOpen.contains(id) { setBrowserOpen(id, false) }
        else { setBrowserOpen(id, true) }
    }

    private func setBrowserOpen(_ id: Profile.ID, _ open: Bool) {
        if open {
            if shownBrowser == id, browserWidthConstraint.constant > 0 { return }   // already shown
            guard let ctl = browserController(for: id) else {
                FatClientLog.log("browser: tunnel not ready (no subnet/socks yet)"); return
            }
            browserOpen.insert(id)
            shownBrowser = id
            let host = NSHostingView(rootView: BrowserPaneView(model: browserModel(for: id)))
            host.translatesAutoresizingMaskIntoConstraints = false
            for sub in browserPaneHost.subviews { sub.removeFromSuperview() }
            browserPaneHost.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: browserPaneHost.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: browserPaneHost.trailingAnchor),
                host.topAnchor.constraint(equalTo: browserPaneHost.topAnchor),
                host.bottomAnchor.constraint(equalTo: browserPaneHost.bottomAnchor),
            ])
            browserWidthConstraint.constant = max(480, frame.width * 0.42)
            ctl.setVisible(true)
            // Relay the remote agent's browser MCP to this local browser.
            if browserRelays[id] == nil {
                let relay = BrowserMCPRelayClient(
                    host: controller.host, vm: id.uuidString,
                    browser: { [weak self] in self?.browserControllers[id] })
                browserRelays[id] = relay
                relay.start()
            }
        } else {
            browserOpen.remove(id)
            if shownBrowser == id { shownBrowser = nil }
            browserWidthConstraint.constant = 0
            browserControllers[id]?.setVisible(false, teardownWhenHidden: false)
        }
    }

    private func makeSidebar() -> SessionSidebar {
        let c = controller
        return SessionSidebar(
            model: c.listModel,
            gridStore: c.gridStore,
            onSelectGrid: { [weak self] in self?.showGrid() },
            onRemoveGridCell: { [weak self] id in
                self?.controller.gridStore.remove(id: id); self?.controller.pushGridLayout()
            },
            onFocusGridCell: { [weak self] id in
                self?.showGrid(); self?.controller.gridStore.focusedCellID = id; self?.controller.pushGridLayout()
            },
            onDropGridPayload: { [weak self] payload in
                guard let self, let d = GridDragPayload.decode(payload) else { return false }
                _ = self.controller.gridStore.add(profileID: d.profileID, windowIndex: d.windowIndex, label: d.label)
                self.controller.pushGridLayout()
                return true
            },
            onAddAllToGrid: { _ in },
            onSelect: { [weak self] id in self?.showWorkspace(id) },
            onSelectTab: { [weak self] id, idx in
                self?.controller.selectTab(id, index: idx); self?.showWorkspace(id, window: idx)
            },
            onNewTab: { [weak self] id in self?.controller.newTab(id) },
            onCloseTab: { [weak self] id, idx in self?.controller.closeTab(id, index: idx) },
            onTabAction: { [weak self] id, idx, action in self?.controller.worktree(id, index: idx, action: action) },
            onSelectDocker: { _ in },
            onOpenContainer: { _, _ in },
            onDetachVM: { _ in },
            onCloseVM: { _ in },
            onStart: { [weak self] id in self?.controller.startWorkspace(id) },
            onShutdown: { [weak self] id in self?.controller.shutdownWorkspace(id) },
            onSuspend: { [weak self] id in self?.controller.suspendWorkspace(id) },
            onRestart: { [weak self] id in self?.controller.restartWorkspace(id) },
            onEdit: { _ in },
            onDuplicate: { _ in },
            onReset: { _ in },
            onDelete: { _ in },
            onNewProfile: { },
            automationStore: c.automationStore,
            onSelectAutomation: { _ in },
            onNewAutomation: { },
            onRunAutomation: { [weak self] id in self?.controller.runAutomation(id) },
            onToggleAutomation: { [weak self] id in self?.controller.toggleAutomation(id) },
            onDeleteAutomation: { [weak self] id in self?.controller.deleteAutomation(id) })
    }

    // MARK: Stage

    private func showGrid() {
        controller.listModel.gridSelected = true
        controller.listModel.selectedID = nil
        unmountTerminal()
        if gridView == nil {
            let ds = GridStageView.DataSource(
                profile: { [weak self] pid in self?.controller.profile(for: pid) },
                tabsModel: { [weak self] pid in self?.controller.tabsModel(for: pid) },
                runState: { [weak self] pid in self?.controller.runState(for: pid) ?? .off },
                onStart: { [weak self] pid in self?.controller.startWorkspace(pid) },
                onJump: { [weak self] pid, idx in self?.showWorkspace(pid, window: idx) },
                remoteHost: controller.host.id)
            let v = GridStageView(store: controller.gridStore, dataSource: ds)
            v.translatesAutoresizingMaskIntoConstraints = false
            gridView = v
        }
        mount(gridView!)
    }

    private func showWorkspace(_ id: Profile.ID, window: Int? = nil) {
        controller.listModel.gridSelected = false
        controller.listModel.selectedID = id
        // Detach the grid so its surfaces don't fight for the stage.
        gridView?.removeFromSuperview()
        let idx = window ?? controller.tabsModel(for: id)?.activeTab?.index ?? 0
        mountTerminal(for: id, window: idx)
        // The pane shows one workspace's browser at a time: show this one's if
        // it's open, else collapse (keeping the other's VM resumable).
        if browserOpen.contains(id) {
            setBrowserOpen(id, true)
        } else if let prev = shownBrowser, prev != id {
            browserControllers[prev]?.setVisible(false, teardownWhenHidden: false)
            shownBrowser = nil
            browserWidthConstraint.constant = 0
        }
        if autoBrowser { setBrowserOpen(id, true) }
    }

    private func mountTerminal(for id: Profile.ID, window idx: Int) {
        guard let profile = controller.profile(for: id) else {
            unmountTerminal(); return
        }
        // Same workspace + window already mounted → nothing to do.
        if shownWorkspace == id, shownWindowIndex == idx, mountedTermView?.window != nil { return }
        unmountTerminal()
        let ctl = termControllers[id] ?? {
            let c = TerminalSessionController(profile: profile, remoteHost: controller.host.id)
            termControllers[id] = c
            return c
        }()
        guard let view = ctl.view(forWindow: idx) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        mount(view)
        mountedTermView = view
        shownWorkspace = id
        shownWindowIndex = idx
    }

    private func unmountTerminal() {
        mountedTermView?.removeFromSuperview()
        mountedTermView = nil
        shownWorkspace = nil
        shownWindowIndex = nil
    }

    private func mount(_ view: NSView) {
        // Remove any current stage occupant except the one we're mounting.
        for sub in stage.subviews where sub !== view { sub.removeFromSuperview() }
        if view.superview !== stage {
            view.removeFromSuperview()
            stage.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                view.topAnchor.constraint(equalTo: stage.topAnchor),
                view.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
    }

    /// When the selected workspace's active tab changes on the remote, follow it.
    private func refreshStageIfNeeded() {
        // Toggle the "not connected" overlay on/off (independent of revision so
        // it clears as soon as the first poll succeeds and re-shows on drop).
        statusHost?.isHidden = controller.connected
        stage.subviews.forEach { $0.isHidden = !controller.connected }
        guard controller.revision != lastRevision else { return }
        lastRevision = controller.revision
        // Test hook: auto-select a named workspace once it's running.
        if !didAutoSelect, let name = autoSelectName,
           let row = controller.listModel.profileRows.first(where: { $0.name == name && $0.state == .running }) {
            didAutoSelect = true
            FatClientLog.log("auto-selecting running workspace \(name)")
            showWorkspace(row.id)
        }
        if let id = shownWorkspace, shownWindowIndex == nil {
            let idx = controller.tabsModel(for: id)?.activeTab?.index ?? 0
            mountTerminal(for: id, window: idx)
        }
        // Debug: dump the rendered window to a PNG (works offscreen, so the
        // two-instance test can verify 1:1 even when the display is asleep).
        if let path = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_SHOT"] {
            writeSnapshot(to: path)
        }
    }

    /// Render the window's content view (sidebar + stage) to a PNG offscreen.
    func writeSnapshot(to path: String) {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

