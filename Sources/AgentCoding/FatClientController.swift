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

    /// Spec numbers for the VM dashboard, mirrored per workspace (available
    /// even for off/suspended VMs, which have no `vms` entry).
    struct WorkspaceSpec: Equatable {
        var memoryGB = 4
        var cpus = 0
        var diskAllocatedBytes: Int64 = 0
        var diskCapacityBytes: Int64 = 0
    }
    private(set) var specs: [Profile.ID: WorkspaceSpec] = [:]
    /// Boot time of each running VM, derived from the mirrored uptime (kept
    /// stable across polls so the dashboard's uptime doesn't jitter).
    private(set) var bootTimes: [Profile.ID: Date] = [:]
    /// Decision-prompt ids already surfaced to the user (dedupe across polls).
    private var promptedIDs: Set<String> = []
    /// Shared-folder paths per running VM (feeds the remote file browser's
    /// location list — browsed via the guest, since the host dirs live on A).
    private(set) var mounts: [Profile.ID: [String]] = [:]
    /// Last local Fusion toggle per workspace — suppresses the mirrored
    /// `fusionEngaged` for a beat so a stale poll can't flap the ⚡ button.
    private var fusionTouched: [Profile.ID: Date] = [:]

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
    /// Optional system-wide utun tunnel (any local process → remote subnet at
    /// its literal address). Off by default — the browser pane works via SOCKS
    /// without it. Enabled per host with the toolbar's network toggle (or the
    /// `BROMURE_FATCLIENT_UTUN` env for tests); needs the privileged helper,
    /// whose install/approval is guided by `startTunnelIfNeeded`.
    private var tunnel: FatClientTunnel?
    /// UI-facing tunnel state: "off" / "waiting-approval" / "active" / "failed".
    private(set) var tunnelState = "off"
    private var approvalPollTimer: Timer?
    private var tunnelDefaultsKey: String { "fatclient.tunnel.\(host.id.uuidString)" }
    /// Persisted per-host opt-in for the system-wide tunnel.
    var tunnelEnabled: Bool {
        UserDefaults.standard.bool(forKey: tunnelDefaultsKey)
            || ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_UTUN"] != nil
    }

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
        approvalPollTimer?.invalidate()
        approvalPollTimer = nil
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
            startTunnelIfNeeded()
        }

        applyWorkspaces(workspaces, vms: vms)
        applyGrid(grid)
        applyAutomations(autos)
        applyPendingPrompts((snapshot["pendingPrompts"] as? [[String: Any]]) ?? [])
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
        var newSpecs: [Profile.ID: WorkspaceSpec] = [:]
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

            var spec = WorkspaceSpec()
            spec.memoryGB = w["memoryGB"] as? Int ?? 4
            spec.cpus = w["cpuCount"] as? Int ?? 0
            spec.diskAllocatedBytes = Int64((w["diskAllocatedBytes"] as? Int) ?? 0)
            spec.diskCapacityBytes = Int64((w["diskCapacityBytes"] as? Int) ?? 0)
            newSpecs[id] = spec

            var p = Profile(
                id: id, name: name,
                tool: Profile.Tool(rawValue: w["tool"] as? String ?? "") ?? .claude,
                authMode: Profile.AuthMode(rawValue: w["authMode"] as? String ?? "") ?? .token)
            p.color = ProfileColor(rawValue: w["color"] as? String ?? "") ?? .gray
            p.memoryGB = spec.memoryGB
            newProfiles[id] = p
        }
        profilesByID = newProfiles
        specs = newSpecs
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
            if let up = vm["uptimeSeconds"] as? Int {
                let derived = Date(timeIntervalSinceNow: TimeInterval(-up))
                // Keep the previous value unless it drifted (poll jitter would
                // otherwise make the dashboard's uptime wobble).
                if let prev = bootTimes[id], abs(prev.timeIntervalSince(derived)) < 3 {
                    // stable — keep prev
                } else {
                    bootTimes[id] = derived
                }
            }
            mounts[id] = vm["mounts"] as? [String] ?? []
            // Fusion state for the toolbar's ⚡ toggle. Skip the engaged bit
            // briefly after a local toggle so an in-flight (stale) poll can't
            // flap the button before the POST lands on the remote.
            let fusionConfigurable = vm["fusionConfigurable"] as? Bool ?? false
            if model.fusionConfigurable != fusionConfigurable {
                model.fusionConfigurable = fusionConfigurable
            }
            if Date().timeIntervalSince(fusionTouched[id] ?? .distantPast) > 3 {
                let engaged = vm["fusionEngaged"] as? Bool ?? false
                if model.fusionEngaged != engaged { model.fusionEngaged = engaged }
            }
            applyRemotePorts(model, vm)
            applyRemoteDocker(model, vm)
            applyRemoteTabs(model, (vm["tabs"] as? [[String: Any]]) ?? [])
            let name = vm["name"] as? String ?? profilesByID[id]?.name ?? "?"
            entries.append(SessionListModel.VMEntry(
                id: id, name: name,
                accentHex: model.accentHex, model: model))
        }
        tabsModels = tabsModels.filter { liveIDs.contains($0.key) }
        bootTimes = bootTimes.filter { liveIDs.contains($0.key) }
        mounts = mounts.filter { liveIDs.contains($0.key) }
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

    /// Mirror the guest's listening sockets into the shared `TabsModel` (feeds
    /// the VM dashboard's ports card, exactly like `applyListeningPorts`).
    private func applyRemotePorts(_ model: TabsModel, _ vm: [String: Any]) {
        let ports = ((vm["listeningPorts"] as? [[String: Any]]) ?? []).map {
            ListeningPort(proto: $0["proto"] as? String ?? "tcp",
                          addr: $0["addr"] as? String ?? "",
                          port: $0["port"] as? Int ?? 0,
                          process: $0["process"] as? String ?? "")
        }
        if model.vmListeningPorts != ports { model.vmListeningPorts = ports }
    }

    /// Mirror the guest's docker state (containers / images / binfmt) into the
    /// shared `TabsModel` — the remote Docker dashboard renders from these.
    private func applyRemoteDocker(_ model: TabsModel, _ vm: [String: Any]) {
        let containers = ((vm["dockerContainers"] as? [[String: Any]]) ?? []).map { d -> DockerContainer in
            var c = DockerContainer(
                id: d["id"] as? String ?? "",
                name: d["name"] as? String ?? "",
                image: d["image"] as? String ?? "",
                status: d["status"] as? String ?? "",
                state: d["state"] as? String ?? "",
                ports: d["ports"] as? String ?? "",
                runningFor: d["runningFor"] as? String ?? "",
                cpuPerc: d["cpuPerc"] as? String ?? "",
                memUsage: d["memUsage"] as? String ?? "")
            c.arch = d["arch"] as? String ?? ""
            return c
        }
        if model.dockerContainers != containers { model.dockerContainers = containers }
        let images = ((vm["dockerImages"] as? [[String: Any]]) ?? []).map {
            DockerImage(id: $0["id"] as? String ?? "",
                        repository: $0["repository"] as? String ?? "<none>",
                        tag: $0["tag"] as? String ?? "<none>",
                        size: $0["size"] as? String ?? "",
                        created: $0["created"] as? String ?? "")
        }
        if model.dockerImages != images { model.dockerImages = images }
        if let arches = vm["dockerBinfmt"] as? [String], !arches.isEmpty {
            if !model.binfmtProbed { model.binfmtProbed = true }
            if model.binfmtArches != arches { model.binfmtArches = arches }
        }
    }

    /// Surface the remote's pending decision prompts (storage upgrade, drift
    /// reset, compromise wipe, …) as LOCAL alerts — the whole point of the
    /// prompt broker: the interface that initiated the action answers. The
    /// chosen button index rides back over the tunnel.
    private func applyPendingPrompts(_ prompts: [[String: Any]]) {
        // Prune answered/expired ids so the set can't grow unbounded.
        let current = Set(prompts.compactMap { $0["id"] as? String })
        promptedIDs.formIntersection(current)
        for p in prompts {
            guard let id = p["id"] as? String, !promptedIDs.contains(id) else { continue }
            promptedIDs.insert(id)
            let alert = NSAlert()
            alert.messageText = p["title"] as? String ?? "Bromure — \(host.name)"
            alert.informativeText = p["message"] as? String ?? ""
            let buttons = (p["buttons"] as? [String]) ?? ["OK"]
            for b in buttons { alert.addButton(withTitle: b) }
            // Destructive-looking prompts shouldn't confirm on a stray Return.
            if buttons.first?.lowercased().contains("wipe") == true {
                alert.buttons.first?.keyEquivalent = ""
            }
            NSApp.activate(ignoringOtherApps: true)
            let resp = alert.runModal()
            let choice = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            send("POST", "/prompts/\(ControlClient.encodeSegment(id))/answer",
                 body: ["choice": max(0, min(choice, buttons.count - 1))])
        }
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
    func hardRebootWorkspace(_ id: Profile.ID) {
        send("POST", "/vms/\(seg(id))/reboot", body: ["mode": "hard"])
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

    // MARK: System-wide tunnel (one-click, no sudo)

    /// Toggle the per-host tunnel opt-in. Enabling runs the whole guided flow
    /// (register the SMAppService daemon → walk the user through macOS's one
    /// approval toggle → start automatically); disabling stops the tunnel and
    /// unregisters the root daemon once no host wants the feature.
    func setTunnelEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: tunnelDefaultsKey)
        if on {
            startTunnelIfNeeded(interactive: true)
        } else {
            approvalPollTimer?.invalidate(); approvalPollTimer = nil
            tunnel?.stop(); tunnel = nil
            tunnelState = "off"
            let anyEnabled = RemoteHostStore.shared.hosts.contains {
                UserDefaults.standard.bool(forKey: "fatclient.tunnel.\($0.id.uuidString)")
            }
            if !anyEnabled { FatClientTunnelInstaller.unregister() }
        }
    }

    /// Start the tunnel when opted in, guiding through daemon install/approval
    /// as needed. Interactive = user-initiated (may present an alert); the
    /// non-interactive path (poll/apply) stays silent.
    func startTunnelIfNeeded(interactive: Bool = false) {
        guard tunnelEnabled, tunnel == nil else { return }
        guard let cidr = vmnetSubnet else { return }   // resumes on first /state
        switch FatClientTunnelInstaller.state {
        case .enabled:
            startTunnel(cidr: cidr)
        case .notRegistered, .requiresApproval:
            switch FatClientTunnelInstaller.ensureRegistered() {   // register is idempotent
            case .enabled:
                startTunnel(cidr: cidr)
            case .requiresApproval:
                guideThroughApproval(interactive: interactive, cidr: cidr)
            case .failed(let why):
                // register() threw — no Login Items entry exists, so don't
                // send the user there to approve nothing. Click retries.
                tunnelState = "failed"
                if interactive { presentRegistrationFailure(why) }
            }
        }
    }

    private func presentRegistrationFailure(_ why: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Couldn't install the network helper", comment: "")
        alert.informativeText = String(format: NSLocalizedString(
            "macOS refused to register Bromure's privileged network helper:\n\n%@\n\nA privileged helper can only be installed and approved from an administrator account. Bromure keeps working over its built-in per-app tunnel — this helper is only needed to reach the remote's VMs from other apps.",
            comment: ""), why)
        alert.runModal()
    }

    private func guideThroughApproval(interactive: Bool, cidr: String) {
        if FatClientTunnelInstaller.state == .enabled {
            startTunnel(cidr: cidr)
            return
        }
        tunnelState = "waiting-approval"
        if interactive {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Allow Bromure's network helper", comment: "")
            alert.informativeText = NSLocalizedString(
                "Direct network access to the remote's VMs uses a privileged helper.\n\nmacOS asks you to approve it once: System Settings → General → Login Items, then allow “Bromure Agentic Coding” (macOS asks for an administrator's credentials). The tunnel connects automatically as soon as it's approved — nothing else to do.",
                comment: "")
            alert.addButton(withTitle: NSLocalizedString("Open Login Items", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn {
                FatClientTunnelInstaller.openApprovalSettings()
            } else {
                UserDefaults.standard.set(false, forKey: tunnelDefaultsKey)
                tunnelState = "off"
                return
            }
        }
        // Watch for the approval and connect the moment it lands.
        approvalPollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(300)   // stop watching after 5 min; retried on next connect/toggle
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if FatClientTunnelInstaller.state == .enabled {
                    timer.invalidate(); self.approvalPollTimer = nil
                    if let cidr = self.vmnetSubnet { self.startTunnel(cidr: cidr) }
                } else if Date() > deadline {
                    timer.invalidate(); self.approvalPollTimer = nil
                    self.tunnelState = "off"
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        approvalPollTimer = t
    }

    private func startTunnel(cidr: String) {
        let t = FatClientTunnel(host: host, localCIDR: cidr)
        if t.start() {
            tunnel = t
            tunnelState = "active"
            FatClientLog.log("tunnel: active for \(cidr)")
        } else {
            tunnelState = "failed"
            FatClientLog.log("tunnel: start failed (helper unreachable?)")
        }
    }

    /// Fusion toggle for the toolbar's ⚡ — rides the same control verb the
    /// CLI's `vm fusion` uses. The mirrored `fusionEngaged` confirms on poll.
    func setFusion(_ id: Profile.ID, engaged: Bool) {
        fusionTouched[id] = Date()
        send("POST", "/vms/\(seg(id))/fusion", body: ["engaged": engaged])
    }

    /// Full profile document for the settings editor (secrets blanked
    /// server-side; blank fields keep their stored value on save).
    func fetchProfileDoc(_ id: Profile.ID) async throws -> [String: Any] {
        let host = self.host
        let path = "/profiles/\(seg(id))?full=1"
        let resp = try await Task.detached(priority: .userInitiated) {
            try RemoteTransport.client(for: host).request("GET", path)
        }.value
        guard resp.status == 200 else {
            throw ACAppDelegate.GuestExecError.commandFailed(
                exitCode: 1, stderr: (resp.json["error"] as? String) ?? "profile fetch failed")
        }
        return resp.json
    }

    /// Secret-preserving whole-document save (the counterpart of
    /// `fetchProfileDoc`). Returns the response body (e.g. `sshPublicKey`
    /// when the doc asked for a generated key).
    @discardableResult
    func saveProfileDoc(_ id: Profile.ID, _ doc: [String: Any]) async throws -> [String: Any] {
        let host = self.host
        let path = "/profiles/\(seg(id))"
        let resp = try await Task.detached(priority: .userInitiated) {
            try RemoteTransport.client(for: host).request("PUT", path, body: doc)
        }.value
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ACAppDelegate.GuestExecError.commandFailed(
                exitCode: 1, stderr: (resp.json["error"] as? String) ?? "save failed (HTTP \(resp.status))")
        }
        DispatchQueue.main.async { [weak self] in self?.pollOnce() }
        return resp.json
    }

    // Docker dashboard actions — validated + executed on the remote host via
    // the same outbox verbs the local dashboard sends.
    func dockerAction(_ id: Profile.ID, _ body: [String: Any]) {
        send("POST", "/vms/\(seg(id))/docker", body: body)
    }
    func setDockerWatch(_ id: Profile.ID, on: Bool) {
        send("POST", "/vms/\(seg(id))/docker", body: ["action": "watch", "on": on], then: false)
    }

    /// Run a shell command in the remote workspace's guest, over the tunnel —
    /// satisfies `GuestExecProvider` for the remote file-explorer pane.
    func guestExec(_ id: Profile.ID, command: String, timeout: Int) async throws -> String {
        let host = self.host
        let path = "/vms/\(seg(id))/exec"
        let resp = try await Task.detached(priority: .userInitiated) {
            try RemoteTransport.client(for: host)
                .request("POST", path, body: ["command": command, "timeout": timeout])
        }.value
        guard resp.status == 200 else {
            throw ACAppDelegate.GuestExecError.commandFailed(
                exitCode: 1, stderr: (resp.json["error"] as? String) ?? "exec failed")
        }
        let exitCode = resp.json["exitCode"] as? Int ?? 1
        guard exitCode == 0 else {
            throw ACAppDelegate.GuestExecError.commandFailed(
                exitCode: exitCode, stderr: resp.json["stderr"] as? String ?? "")
        }
        return resp.json["stdout"] as? String ?? ""
    }

    /// Run one native file op in the remote guest — the remote file browser's
    /// data plane (upload/download/list/delete as base64 JSON over the tunnel).
    func guestFileOp(_ id: Profile.ID, op: [String: Any], timeout: Int = 30) async throws -> [String: Any] {
        let host = self.host
        let path = "/vms/\(seg(id))/file"
        let resp = try await Task.detached(priority: .userInitiated) {
            try RemoteTransport.client(for: host)
                .request("POST", path, body: ["op": op, "timeout": timeout])
        }.value
        if let err = resp.json["error"] as? String {
            throw ACAppDelegate.GuestExecError.commandFailed(exitCode: 1, stderr: err)
        }
        guard resp.status == 200 else {
            throw ACAppDelegate.GuestExecError.connectionFailed
        }
        return resp.json
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

// MARK: - Remote window toolbar (per-selected-VM controls + IP)

/// The remote window's trailing toolbar cluster — the fat-client counterpart
/// of `UnifiedToolbarBar`, same buttons in the same order (Fusion, files,
/// reboot, settings, pop-out, browser + file-pane toggles) so a mirrored VM
/// looks and drives exactly like a local one, plus the remote-only network
/// tunnel toggle. The Docker dashboard opens from the sidebar, like local.
struct RemoteToolbarBar: View {
    @Bindable var model: SessionListModel
    let controller: RemoteHostController
    let onFiles: (Profile.ID) -> Void
    let onReboot: (Profile.ID) -> Void
    let onSettings: (Profile.ID) -> Void
    let onDetach: (Profile.ID) -> Void
    let onToggleFusion: (Profile.ID, Bool) -> Void
    let onToggleBrowser: () -> Void
    let onToggleFilePane: () -> Void
    let onToggleTunnel: () -> Void

    private var entry: SessionListModel.VMEntry? {
        model.entries.first { $0.id == model.selectedID }
    }

    private var tunnelHelp: String {
        switch controller.tunnelState {
        case "active":           "Direct network access to the remote's VMs is ON — click to turn off"
        case "waiting-approval": "Waiting for approval in System Settings › Login Items…"
        case "failed":           "Network tunnel failed — click to retry"
        default:                 "Enable direct network access to the remote's VMs (192.168.x.x from any local app)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            HeaderIcon(system: controller.tunnelState == "waiting-approval"
                           ? "network.badge.shield.half.filled"
                           : (controller.tunnelState == "active"
                              ? "point.3.filled.connected.trianglepath.dotted"
                              : "point.3.connected.trianglepath.dotted"),
                       help: tunnelHelp,
                       active: controller.tunnelState == "active") { onToggleTunnel() }
            if let entry {
                if let ip = entry.model.ipAddress { ToolbarIP(ip: ip) }
                FusionToggle(model: entry.model) { on in onToggleFusion(entry.id, on) }
                HeaderIcon(system: "folder", help: "Browse files") { onFiles(entry.id) }
                HeaderIcon(system: "arrow.clockwise.circle", help: "Reboot the VM") { onReboot(entry.id) }
                HeaderIcon(system: "gearshape", help: "Edit workspace") { onSettings(entry.id) }
                HeaderIcon(system: "rectangle.portrait.and.arrow.right", help: "Pop out to its own window") { onDetach(entry.id) }
                HeaderIcon(system: "globe", help: "Show or hide the agentic browser (⌃⌘B)",
                           active: model.browserPaneOpen) { onToggleBrowser() }
                HeaderIcon(system: "sidebar.right", help: "Show or hide repo files (⌃⌘E)",
                           active: model.filePaneOpen) { onToggleFilePane() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

@MainActor
final class RemoteToolbarDelegate: NSObject, NSToolbarDelegate {
    static let itemID = NSToolbarItem.Identifier("io.bromure.ac.remote.controls")
    private let rootView: AnyView
    init(rootView: AnyView) { self.rootView = rootView }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.itemID]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.itemID]
    }
    func toolbar(_ t: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.itemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        item.visibilityPriority = .high
        return item
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

    // Window chrome (fat-client counterparts of the local window's
    // decorations): toolbar (IP pill + controls), VM dashboard for
    // off/suspended workspaces, docker dashboard, file-explorer pane, and
    // per-VM file-browser (transfer) windows.
    private var toolbarDelegate: RemoteToolbarDelegate?
    private var dashboardHost: NSHostingView<VMDashboardView>?
    private var shownDashboard: (id: Profile.ID, state: SessionListModel.RunState)?
    private var dockerHost: NSHostingView<DockerDashboardView>?
    private var dockerShownFor: Profile.ID?
    private let fileExplorerModel = FileExplorerModel()
    private var filePaneHost: NSHostingView<FileExplorerPane>!
    private var filePaneWidthConstraint: NSLayoutConstraint!
    private var filePaneOpen = false
    private var fileBrowserWindows: [Profile.ID: NSWindow] = [:]
    /// Per-workspace settings editors (the pill's gearshape) — same
    /// `ProfileEditorView` as local, saving over the tunnel.
    private var settingsWindows: [Profile.ID: NSWindow] = [:]
    /// Popped-out workspace windows (the pill's pop-out) — an extra live view
    /// of the mirrored terminal; each owns its own attach controller.
    private var popOutWindows: [Profile.ID: NSWindow] = [:]
    private var popOutControllers: [Profile.ID: TerminalSessionController] = [:]

    // Browser pane (fat-client): a local Chromium VM per remote workspace whose
    // page traffic is tunneled to the remote subnet via the SOCKS forwarder.
    private var browserPaneHost: NSView!
    private var browserWidthConstraint: NSLayoutConstraint!
    private var browserResizeHandle: SidebarResizeHandle?
    /// Last user-chosen browser-pane width, restored the next time it opens.
    private var expandedBrowserWidth: CGFloat = 0
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
    /// Test hook: comma-separated pill actions ("settings", "popout", "files")
    /// fired 2s after the auto-selected workspace mounts — drives the toolbar
    /// headlessly for E2E.
    private let autoActions = ProcessInfo.processInfo.environment["BROMURE_FATCLIENT_ACTION"]

    init(controller: RemoteHostController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        title = "Remote — \(controller.host.name)"
        isReleasedWhenClosed = false
        buildLayout()
        buildToolbar()
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
        clearDockerDashboard()
        for (_, w) in fileBrowserWindows { w.close() }
        fileBrowserWindows.removeAll()
        for (_, w) in settingsWindows { w.close() }
        settingsWindows.removeAll()
        for id in Array(popOutWindows.keys) {
            popOutWindows[id]?.close()   // willClose → reapPopOut retires the controller
        }
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

    /// ⌃⌘B toggles the browser pane, ⌃⌘E the file-explorer pane — mirroring
    /// the local window's shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": toggleBrowser(for: nil); return true
            case "e": toggleFilePane(); return true
            default: break
            }
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
        // File-explorer pane sits between the stage and the browser pane;
        // width toggles 0 ↔ N (⌃⌘E / the toolbar's sidebar.right button).
        fileExplorerModel.execProvider = { [weak self] id, command, timeout in
            guard let self else { throw ACAppDelegate.GuestExecError.vmNotRunning }
            return try await self.controller.guestExec(id, command: command, timeout: timeout)
        }
        let filePane = FileExplorerPane(
            model: fileExplorerModel, listModel: controller.listModel,
            onAutoSetOpen: { [weak self] open in self?.setFilePaneOpen(open) })
        let fpHost = NSHostingView(rootView: filePane)
        fpHost.translatesAutoresizingMaskIntoConstraints = false
        fpHost.clipsToBounds = true   // squish cleanly during open/close
        // Our width constraint is the ONLY size authority (an NSHostingView
        // otherwise adds a required min-width that beats the width-0 close).
        fpHost.sizingOptions = []
        filePaneHost = fpHost
        content.addSubview(fpHost)
        filePaneWidthConstraint = fpHost.widthAnchor.constraint(equalToConstant: 0)
        // Pane order (left→right, matching the local window): terminal | web
        // browser | file explorer. The browser is the middle split; both right
        // panes animate width 0 ↔ N and the terminal stage fills the rest.
        let browser = NSView()
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.wantsLayer = true
        browser.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(browser)
        browserPaneHost = browser
        browserWidthConstraint = browser.widthAnchor.constraint(equalToConstant: 0)
        // 8pt drag strip over the browser pane's leading edge (terminal↔browser
        // boundary), like the local window's browserPaneResizeHandle.
        let browserHandle = SidebarResizeHandle()
        browserHandle.translatesAutoresizingMaskIntoConstraints = false
        browserHandle.isHidden = true
        content.addSubview(browserHandle)
        browserResizeHandle = browserHandle
        browserHandle.onResize = { [weak self] x in
            guard let self, self.browserWidthConstraint.constant > 0,
                  let content = self.contentView else { return }
            // Browser's right edge is the file pane's left edge, so subtract the
            // file pane width (0 when closed) from the content right edge, then
            // the handle's x, to get the proposed browser width.
            let fileW = self.filePaneOpen ? self.filePaneWidthConstraint.constant : 0
            let width = content.bounds.width - fileW - x
            if width < Self.browserPaneMinWidth {
                if let id = self.shownBrowser { self.setBrowserOpen(id, false) }
            } else {
                self.setBrowserWidth(self.clampBrowserWidth(width))
            }
        }
        browserHandle.onResizeEnd = { [weak self] in
            guard let self, self.browserWidthConstraint.constant >= Self.browserPaneMinWidth
            else { return }
            self.expandedBrowserWidth = self.browserWidthConstraint.constant
        }
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
            browser.trailingAnchor.constraint(equalTo: fpHost.leadingAnchor),
            browser.topAnchor.constraint(equalTo: content.topAnchor),
            browser.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            browserWidthConstraint,
            browserHandle.centerXAnchor.constraint(equalTo: browser.leadingAnchor),
            browserHandle.topAnchor.constraint(equalTo: content.topAnchor),
            browserHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            browserHandle.widthAnchor.constraint(equalToConstant: 8),
            fpHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fpHost.topAnchor.constraint(equalTo: content.topAnchor),
            fpHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            filePaneWidthConstraint,
            statusHost.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            statusHost.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            statusHost.topAnchor.constraint(equalTo: stage.topAnchor),
            statusHost.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
    }

    // Browser-pane width bounds (mirror the local window).
    private static let browserPaneMinWidth: CGFloat = 380
    private static let terminalSlotMinWidth: CGFloat = 400

    /// Clamp a proposed browser width so the terminal keeps its minimum and the
    /// pane never exceeds the space left of the (possibly open) file pane.
    private func clampBrowserWidth(_ desired: CGFloat) -> CGFloat {
        guard let content = contentView else { return desired }
        let fileW = filePaneOpen ? filePaneWidthConstraint.constant : 0
        // 240 sidebar + terminal minimum + file pane = the space the browser
        // may not eat into.
        let available = content.bounds.width - 240 - Self.terminalSlotMinWidth - fileW
        return max(Self.browserPaneMinWidth, min(desired, max(Self.browserPaneMinWidth, available)))
    }

    /// Set the browser-pane width and keep the drag handle shown only while the
    /// pane is open (width > 0).
    private func setBrowserWidth(_ w: CGFloat) {
        browserWidthConstraint.constant = w
        browserResizeHandle?.isHidden = w <= 0
    }

    /// The titlebar toolbar: IP pill + per-selected-VM controls, mirroring the
    /// local window's `UnifiedToolbarBar` (missing decorations issue).
    private func buildToolbar() {
        let bar = RemoteToolbarBar(
            model: controller.listModel,
            controller: controller,
            onFiles: { [weak self] id in self?.openFileBrowser(id) },
            onReboot: { [weak self] id in self?.confirmReboot(id) },
            onSettings: { [weak self] id in self?.openWorkspaceSettings(id) },
            onDetach: { [weak self] id in self?.popOutWorkspace(id) },
            onToggleFusion: { [weak self] id, on in self?.controller.setFusion(id, engaged: on) },
            onToggleBrowser: { [weak self] in self?.toggleBrowser(for: nil) },
            onToggleFilePane: { [weak self] in self?.toggleFilePane() },
            onToggleTunnel: { [weak self] in
                guard let c = self?.controller else { return }
                c.setTunnelEnabled(c.tunnelState == "off" || c.tunnelState == "failed")
            })
        let delegate = RemoteToolbarDelegate(rootView: AnyView(bar))
        toolbarDelegate = delegate
        let tb = NSToolbar(identifier: "io.bromure.ac.remote")
        tb.delegate = delegate
        tb.displayMode = .iconOnly
        tb.showsBaselineSeparator = false
        tb.allowsUserCustomization = false
        toolbarStyle = .unified
        toolbar = tb
    }

    // MARK: File-explorer pane + file-browser windows

    func toggleFilePane() { setFilePaneOpen(!filePaneOpen) }

    private func setFilePaneOpen(_ open: Bool) {
        guard open != filePaneOpen else { return }
        filePaneOpen = open
        controller.listModel.filePaneOpen = open
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            filePaneWidthConstraint.animator().constant = open ? 340 : 0
            contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Finder-like browser over the remote VM's filesystem. Every location is
    /// guest-backed (the workspace's shared folders are host dirs on the
    /// REMOTE Mac), so browsing and drag-in/drag-out transfer ride the
    /// `/vms/{id}/file` op channel over the tunnel.
    private func openFileBrowser(_ id: Profile.ID) {
        if let win = fileBrowserWindows[id] {
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let profile = controller.profile(for: id) else { return }
        var locations: [FileBrowserLocation] = [
            FileBrowserLocation(
                name: NSLocalizedString("Home", comment: ""),
                backing: .guest,
                guestPath: "/home/ubuntu",
                symbol: "house")
        ]
        for path in (controller.mounts[id] ?? []).prefix(8) {
            let base = (path as NSString).lastPathComponent
            locations.append(FileBrowserLocation(
                name: base,
                backing: .guest,
                guestPath: "/home/ubuntu/\(base)",
                symbol: "folder"))
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(
            format: NSLocalizedString("Files — %@ (%@)", comment: "remote file browser title"),
            profile.name, controller.host.name)
        win.center()
        win.animationBehavior = .none
        win.isReleasedWhenClosed = false
        let c = controller
        win.contentView = NSHostingView(rootView: FileBrowserView(
            model: FileBrowserModel(
                locations: locations,
                cacheKey: "\(c.host.id.uuidString)-\(id.uuidString)",
                guestOp: { op in
                    try await c.guestFileOp(id, op: op)
                })))
        win.makeKeyAndOrderFront(nil)
        fileBrowserWindows[id] = win
    }

    /// Local soft/hard reboot chooser (the decision belongs to the interacting
    /// client), then the verb rides the tunnel.
    private func confirmReboot(_ id: Profile.ID) {
        let name = controller.profile(for: id)?.name ?? "workspace"
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Reboot “%@”?", comment: ""), name)
        alert.informativeText = NSLocalizedString(
            "Soft reboot asks the guest to shut down cleanly. Hard reboot tears the VM down immediately.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Soft Reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Hard Reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            controller.restartWorkspace(id)
        case .alertSecondButtonReturn:
            controller.hardRebootWorkspace(id)
        default:
            break
        }
    }

    // MARK: Workspace settings (the pill's gearshape, mirroring local)

    /// The same `ProfileEditorView` the local window opens, backed by the
    /// remote document round-trip: GET `/profiles/{id}?full=1` (secrets
    /// blanked) → edit → secret-preserving PUT. Host-side-only affordances
    /// (SSH-key import, subscription registration) stay hidden — their
    /// callbacks are nil, exactly like a freshly-created local profile.
    private func openWorkspaceSettings(_ id: Profile.ID) {
        if let win = settingsWindows[id] { win.makeKeyAndOrderFront(nil); return }
        let c = controller
        Task { @MainActor [weak self] in
            guard let self else { return }
            let profile: Profile
            do {
                let doc = try await c.fetchProfileDoc(id)
                let data = try JSONSerialization.data(withJSONObject: doc)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                profile = try dec.decode(Profile.self, from: data)
            } catch {
                Self.presentRemoteError(
                    NSLocalizedString("Couldn't load the workspace settings", comment: ""), error)
                return
            }
            if let win = self.settingsWindows[id] { win.makeKeyAndOrderFront(nil); return }
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            win.title = String(
                format: NSLocalizedString("Edit workspace — %@", comment: "remote settings title"),
                c.host.name)
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: ProfileEditorView(
                profile: profile,
                isNew: false,
                terminalDefaults: TerminalAppDefaults.load(),
                storageContext: nil,
                onSave: { [weak self] edited, generateSSH in
                    self?.saveWorkspaceSettings(id, edited, generateSSH: generateSSH)
                },
                onCancel: { [weak self] in self?.closeSettingsWindow(id) }))
            win.makeKeyAndOrderFront(nil)
            self.settingsWindows[id] = win
        }
    }

    private func saveWorkspaceSettings(_ id: Profile.ID, _ edited: Profile, generateSSH: Bool) {
        guard var doc = ACAppDelegate.codableToDict(edited) else { return }
        if generateSSH { doc["generateSSH"] = true }
        let c = controller
        Task { @MainActor [weak self] in
            do {
                let resp = try await c.saveProfileDoc(id, doc)
                self?.closeSettingsWindow(id)
                if generateSSH, let pub = resp["sshPublicKey"] as? String, !pub.isEmpty {
                    let a = NSAlert()
                    a.messageText = NSLocalizedString("New SSH key generated", comment: "")
                    a.informativeText = String(format: NSLocalizedString(
                        "Add this public key to your Git host:\n\n%@", comment: ""), pub)
                    a.runModal()
                }
            } catch {
                Self.presentRemoteError(
                    NSLocalizedString("Couldn't save the workspace", comment: ""), error)
            }
        }
    }

    private func closeSettingsWindow(_ id: Profile.ID) {
        settingsWindows[id]?.close()
        settingsWindows[id] = nil
    }

    private static func presentRemoteError(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        if case ACAppDelegate.GuestExecError.commandFailed(_, let stderr) = error {
            a.informativeText = stderr
        } else {
            a.informativeText = error.localizedDescription
        }
        a.runModal()
    }

    // MARK: Pop-out workspace window (the pill's pop-out, mirroring local)

    /// An extra window onto the mirrored workspace's terminal — the remote
    /// analog of the local pill's pop-out. The mirror window keeps its 1:1
    /// sidebar; the pop-out is just another live attach, torn down when its
    /// window closes or the workspace stops running.
    private func popOutWorkspace(_ id: Profile.ID) {
        if let win = popOutWindows[id] { win.makeKeyAndOrderFront(nil); return }
        guard let profile = controller.profile(for: id) else { return }
        switch controller.runState(for: id) {
        case .running, .booting: break
        case .off, .suspended: return   // pill only shows for running VMs
        }
        let ctl = TerminalSessionController(profile: profile, remoteHost: controller.host.id)
        let idx = controller.tabsModel(for: id)?.activeTab?.index ?? 0
        guard let view = ctl.view(forWindow: idx) else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "\(profile.name) — \(controller.host.name)"
        win.center()
        win.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        win.contentView = content
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reapPopOut(id) }
        }
        win.makeKeyAndOrderFront(nil)
        popOutWindows[id] = win
        popOutControllers[id] = ctl
    }

    /// Tear down a pop-out's attach controller once its window is gone.
    private func reapPopOut(_ id: Profile.ID) {
        popOutWindows[id] = nil
        popOutControllers[id]?.retireAll()
        popOutControllers[id] = nil
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
        let profile = controller.profile(for: id)
        let c = WorkspaceBrowserController(
            model: browserModel(for: id), workspaceID: id,
            persistent: profile?.browserPersistent ?? false,
            permissions: .init(
                allowUploads: profile?.browserAllowUploads ?? true,
                allowDownloads: profile?.browserAllowDownloads ?? true,
                webcam: profile?.browserWebcam ?? false,
                microphone: profile?.browserMicrophone ?? false),
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
            let initial = expandedBrowserWidth >= Self.browserPaneMinWidth
                ? expandedBrowserWidth : max(480, frame.width * 0.42)
            setBrowserWidth(clampBrowserWidth(initial))
            ctl.setVisible(true)
            // Relay the remote agent's browser MCP to this local browser.
            if browserRelays[id] == nil {
                let relay = BrowserMCPRelayClient(
                    host: controller.host, vm: id.uuidString,
                    browser: { [weak self] in self?.browserControllers[id] })
                browserRelays[id] = relay
                relay.start()
            }
            // First browser opened this session: offer the VPN to the remote
            // host so its VMs are reachable system-wide, not just from the pane.
            offerBrowserVPNIfNeeded()
        } else {
            browserOpen.remove(id)
            if shownBrowser == id { shownBrowser = nil }
            setBrowserWidth(0)
            browserControllers[id]?.setVisible(false, teardownWhenHidden: false)
        }
    }

    /// Whether we've already offered the VPN this session (asked once, then the
    /// toolbar tunnel toggle is the way to change it).
    private var didOfferBrowserVPN = false

    /// The first time a browser is enabled in this remote window, offer to turn
    /// on the VPN — the system-wide utun tunnel to the remote host. Without it
    /// the browser still reaches the remote's workspaces over Bromure's built-in
    /// per-app tunnel; with it, this Mac routes to the remote's VMs system-wide
    /// so other apps can reach them by address too. No-op if the tunnel is
    /// already on, if we've asked before, or in headless auto-open (E2E) mode.
    private func offerBrowserVPNIfNeeded() {
        guard !didOfferBrowserVPN, !controller.tunnelEnabled, !autoBrowser else { return }
        didOfferBrowserVPN = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Turn on the VPN to “%@”?", comment: ""),
            controller.host.name)
        alert.informativeText = NSLocalizedString(
            "The browser can already reach this remote's workspaces over Bromure's built-in per-app tunnel. Turning on the VPN routes this Mac to the remote's VMs system-wide, so your other apps and terminals can reach them by address too. macOS asks you to approve a network helper once.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Turn On VPN", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            controller.setTunnelEnabled(true)
        }
    }

    /// Hide the browser pane without forgetting the workspace's open state
    /// (used when switching to the Grid or another workspace) — the browser VM
    /// stays resumable so returning re-shows it instantly.
    private func hideShownBrowser() {
        guard let prev = shownBrowser else { return }
        browserControllers[prev]?.setVisible(false, teardownWhenHidden: false)
        shownBrowser = nil
        setBrowserWidth(0)
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
            onSelectDocker: { [weak self] id in self?.showDockerDashboard(id) },
            onOpenContainer: { [weak self] id, cid in self?.showDockerDashboard(id, container: cid) },
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
        clearVMDashboard()
        clearDockerDashboard()
        // The Grid has no browser pane — collapse any shown browser (it stays
        // resumable, so returning to the workspace re-shows it).
        hideShownBrowser()
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
        clearDockerDashboard()
        // Same gate as the local window's `selectRow`: an off/suspended VM has
        // no terminal to attach — mounting one anyway left the login greeting
        // ("Last login: …") on screen while the attach pump polled a VM that
        // doesn't exist. Show the VM dashboard instead, exactly like local.
        switch controller.runState(for: id) {
        case .running, .booting:
            clearVMDashboard()
            let idx = window ?? controller.tabsModel(for: id)?.activeTab?.index ?? 0
            mountTerminal(for: id, window: idx)
        case .off, .suspended:
            unmountTerminal()
            showVMDashboard(id)
        }
        // The pane shows one workspace's browser at a time: show this one's if
        // it's open, else collapse (keeping the other's VM resumable).
        if browserOpen.contains(id) {
            setBrowserOpen(id, true)
        } else if let prev = shownBrowser, prev != id {
            hideShownBrowser()
        }
        if autoBrowser { setBrowserOpen(id, true) }
    }

    // MARK: VM dashboard (off/suspended workspaces, mirrors the local stage)

    private func showVMDashboard(_ id: Profile.ID) {
        guard let profile = controller.profile(for: id) else { return }
        let state = controller.runState(for: id)
        if shownDashboard?.id == id, shownDashboard?.state == state,
           dashboardHost?.superview === stage { return }
        let spec = controller.specs[id] ?? .init()
        let c = controller
        let view = VMDashboardView(
            model: c.tabsModel(for: id),
            profile: profile,
            accentHex: profile.color.hexInUI,
            state: state,
            vCPUs: spec.cpus,
            diskAllocatedBytes: spec.diskAllocatedBytes,
            diskCapacityBytes: spec.diskCapacityBytes,
            startedAt: c.bootTimes[id],
            onNewTerminal: { c.newTab(id) },
            onSuspend:     { c.suspendWorkspace(id) },
            onReboot:      { c.restartWorkspace(id) },
            onShutdown:    { c.shutdownWorkspace(id) },
            onResume:      { c.startWorkspace(id) })
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        dashboardHost = host
        shownDashboard = (id, state)
        mount(host)
    }

    private func clearVMDashboard() {
        dashboardHost?.removeFromSuperview()
        dashboardHost = nil
        shownDashboard = nil
    }

    // MARK: Docker dashboard (mirrors the local overlay)

    /// Docker dashboard for a running remote workspace. Data comes from the
    /// mirrored `TabsModel` (containers/images ride `/state`); actions ride
    /// `POST /vms/{id}/docker`. Opening turns on the guest's gated stats
    /// polling for the duration, like the local dashboard.
    func showDockerDashboard(_ id: Profile.ID, container: String? = nil) {
        guard let model = controller.tabsModel(for: id) else { return }   // needs a running VM
        controller.listModel.gridSelected = false
        controller.listModel.selectedID = id
        gridView?.removeFromSuperview()
        unmountTerminal()
        clearVMDashboard()
        if let prev = dockerShownFor, prev != id {
            controller.setDockerWatch(prev, on: false)
        }
        controller.listModel.dockerSelectedID = id
        let c = controller
        let view = DockerDashboardView(
            model: model,
            accentHex: c.profile(for: id)?.color.hexInUI ?? "#3B82F6",
            onRun: { spec in
                c.dockerAction(id, [
                    "action": "run", "image": spec.image, "name": spec.name,
                    "ports": spec.ports, "env": spec.env, "volumes": spec.volumes,
                    "inheritEnv": spec.inheritEnv, "inheritProxy": spec.inheritProxy,
                    "interactive": spec.interactive,
                ])
            },
            onStart:  { cid in c.dockerAction(id, ["action": "start", "container": cid]) },
            onStop:   { cid in c.dockerAction(id, ["action": "stop", "container": cid]) },
            onRemove: { cid in c.dockerAction(id, ["action": "remove", "container": cid]) },
            onAttach: { cid, shell in c.dockerAction(id, ["action": "attach", "container": cid, "shell": shell]) },
            onLogs:   { cid in c.dockerAction(id, ["action": "logs", "container": cid]) },
            onInstallBinfmt:   { c.dockerAction(id, ["action": "binfmt"]) },
            onUninstallBinfmt: { c.dockerAction(id, ["action": "binfmt-off"]) },
            initialContainerID: container)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        dockerHost = host
        dockerShownFor = id
        mount(host)
        controller.setDockerWatch(id, on: true)
    }

    private func clearDockerDashboard() {
        guard let id = dockerShownFor else { return }
        controller.setDockerWatch(id, on: false)
        dockerShownFor = nil
        controller.listModel.dockerSelectedID = nil
        dockerHost?.removeFromSuperview()
        dockerHost = nil
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
            if let actions = autoActions {
                let id = row.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    for action in actions.split(separator: ",") {
                        FatClientLog.log("auto-action: \(action)")
                        switch action {
                        case "settings": self.openWorkspaceSettings(id)
                        case "popout":   self.popOutWorkspace(id)
                        case "files":    self.openFileBrowser(id)
                        default: break
                        }
                    }
                }
            }
        }
        if let id = shownWorkspace, shownWindowIndex == nil {
            let idx = controller.tabsModel(for: id)?.activeTab?.index ?? 0
            mountTerminal(for: id, window: idx)
        }
        // Follow run-state transitions on the shown stage: an off VM's
        // dashboard becomes a terminal when it comes up (e.g. after Start),
        // and a stopped VM's terminal becomes the dashboard.
        if let d = shownDashboard, controller.runState(for: d.id) != d.state {
            showWorkspace(d.id)
        } else if let id = shownWorkspace {
            switch controller.runState(for: id) {
            case .off, .suspended: showWorkspace(id)
            default: break
            }
        }
        // Pop-outs have no dashboard fallback — close them when their
        // workspace stops (their attach pump would idle on a dead VM).
        for id in Array(popOutWindows.keys) {
            switch controller.runState(for: id) {
            case .off, .suspended: popOutWindows[id]?.close()
            default: break
            }
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

