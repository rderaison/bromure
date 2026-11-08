import Foundation
import NIOConcurrencyHelpers

/// The shared agent-session engine's host on a Linux server (macOS: the app
/// delegate). A workspace is a VM record with a Profile (DaemonProfiles);
/// its guest is reached through the daemon's GuestShell; its tab roster is
/// the one agentd writes to the outbox (tabs.txt), kept as a TabsModel per
/// running workspace whenever /state is built.
// @port-skip linux-only: ACAppDelegate's AgentSessionHost conformance, for the daemon
@MainActor
final class LinuxSessionHost: AgentSessionHost {
    /// Set once, at daemon start.
    static var shared: LinuxSessionHost?
    /// The running workspaces, kept by the daemon as VMs come and go (macOS:
    /// the app's running sessions).
    nonisolated static let running = NIOLockedValueBox<Set<UUID>>([])
    /// The workspaces whose guest has stopped answering (Daemon.observeGuestLiveness).
    nonisolated static let unresponsive = NIOLockedValueBox<Set<UUID>>([])

    private(set) weak var daemon: Daemon?
    /// The registration sign-in in flight (LinuxRegistration; macOS:
    /// ACAppDelegate.claudeRegistration).
    var registration: LinuxRegistrationState?
    let stateDir: String
    /// Running workspaces' rosters (nil: not running, as macOS's "attached").
    private(set) var tabs: [UUID: TabsModel] = [:]
    /// The proxy sign-ins in flight, one per workspace (ProxySignInHost).
    var proxySignIns: [UUID: ProxySignIn] = [:]
    /// The session list as macOS's window keeps it, without the window
    /// (refreshSidebar): what the Switchboard and the dispatcher read a
    /// session's state from.
    let listModel = SessionListModel()

    // @port-skip linux-only: daemon wiring
    init(daemon: Daemon, stateDir: String) {
        self.daemon = daemon
        self.stateDir = stateDir
    }

    /// From the daemon, as it builds /state: a workspace's roster, or nil
    /// when it isn't running.
    // @port-skip linux-only: Linux keeps TabsModel from the outbox roster (macOS: the session's live model)
    func updateRoster(_ id: UUID, _ roster: [GuestTab]?) {
        guard let roster else { tabs[id] = nil; return }
        let model = tabs[id] ?? TabsModel()
        // A tab keeps its id while its index lives (macOS's sessionEntries):
        // reconcile tells tabs apart by it.
        let ids = Dictionary(model.tabs.map { ($0.index, $0.id) }, uniquingKeysWith: { a, _ in a })
        model.tabs = roster.map {
            TabsModel.Tab(label: $0.label, index: $0.index, containerID: $0.containerID, cwd: $0.cwd,
                          worktreeBranch: $0.worktreeBranch, parentBranch: $0.parentBranch,
                          rootRepo: $0.rootRepo, display: $0.display, repoRoot: $0.repoRoot,
                          id: ids[$0.index] ?? UUID())
        }
        for tab in model.tabs { tab.agentStatus = agentStatus[id]?[tab.index] ?? .done }
        model.activeIndex = roster.firstIndex(where: \.active) ?? 0
        model.rosterLive = true
        tabs[id] = model
    }

    /// Bind launching sessions to their tabs, end those whose tab went away,
    /// adopt unregistered agent tabs (AgentSessionStore.reconcile), from the
    /// running workspaces' rosters; macOS does it from its session list.
    /// Then the liveness probe (which agent runs in which tab: what a
    /// delegation notice waits for before it's typed), as macOS's session
    /// list timer does (UnifiedSessionWindow.startSessionReconcile).
    // @port ACAppDelegate.sessionEntries(for: SessionListModel) h=f7d00b98aad3ae2a @9936e30c
    func reconcileSessions() {
        let all = ProfileStore().loadAll()
        let profiles = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entries: [SessionListModel.VMEntry] = Self.running.withLockedValue { $0 }.sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                guard let p = profiles[id], let model = tabsModel(for: id), !model.tabs.isEmpty else { return nil }
                return SessionListModel.VMEntry(id: id, name: p.name, accentHex: p.color.hexInUI, model: model)
            }
        SessionStores.shared?.sessions.reconcile(entries: entries)
        SessionStores.shared?.engine?.probeLiveness(entries: entries)
        scanLiveSessions()
        refreshSidebar(workspaces: entries, profiles: all)
    }

    /// The list model's rows (every workspace and its run state, and the
    /// attached machines, a row always) and its tab entries (the running
    /// workspaces', and a connected machine's roster). An entry keeps its
    /// object while its roster does.
    // partial: a workspace runs or it doesn't (no booting or suspended: both read as asleep); no compromised, squelch or notes; no window
    // @port ACAppDelegate.refreshSidebar() h=9e7c2076375bb24a @f127f8ab
    func refreshSidebar(workspaces: [SessionListModel.VMEntry], profiles: [Profile], machines: [AttachedMachine]? = nil) {
        let running = Self.running.withLockedValue { $0 }
        let machines = machines ?? (LinuxMachines.shared?.attached.values).map(Array.init) ?? []
        let sorted = machines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rows = profiles.map { p in
            SessionListModel.ProfileRow(id: p.id, name: p.name, accentHex: p.color.hexInUI,
                                        state: running.contains(p.id) ? .running : .off,
                                        compromised: Daemon.isCompromised(p, store: ProfileStore()))
        } + sorted.map { m in
            SessionListModel.ProfileRow(id: m.id, name: m.name, accentHex: m.accentHex,
                                        state: m.connected ? .running : .off, compromised: false)
        }
        if listModel.profileRows != rows { listModel.profileRows = rows }
        refreshShieldState(profiles)
        let ids = Set(sorted.map(\.id))
        if listModel.machineIDs != ids { listModel.machineIDs = ids }
        let old = Dictionary(listModel.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = workspaces + sorted.filter(\.connected).map {
            SessionListModel.VMEntry(id: $0.id, name: $0.name, accentHex: $0.accentHex, model: $0.tabsModel)
        }
        let entries = wanted.map { e in old[e.id].flatMap { $0.model === e.model ? $0 : nil } ?? e }
        if listModel.entries.map(ObjectIdentifier.init) != entries.map(ObjectIdentifier.init) { listModel.entries = entries }
    }

    /// What the workspace's guest last said of its memory (`vmstat.txt` in its
    /// outbox, as GuestOutbox reads it for /state), when it said it (the
    /// file's date); nil while it isn't running here.
    // @port-skip linux-only: macOS reads the VM's RunningSession fields (AgentSessionHost+App.swift)
    func guestMemoryReport(for id: Profile.ID) -> GuestMemoryReport? {
        guard Self.running.withLockedValue({ $0.contains(id) }) else { return nil }
        let path = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/vmstat.txt"
        guard let raw = GuestOutbox.read(path),
              let at = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        var used = 0, total = 0, some = 0.0, full = 0.0
        for line in raw.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ")
            guard p.count == 2 else { continue }
            switch p[0] {
            case "mem_used_kb": used = Int(p[1]) ?? 0
            case "mem_total_kb": total = Int(p[1]) ?? 0
            case "mem_psi_some": some = Double(p[1]) ?? 0
            case "mem_psi_full": full = Double(p[1]) ?? 0
            default: break
            }
        }
        guard total > 0 else { return nil }
        return GuestMemoryReport(unresponsive: Self.unresponsive.withLockedValue { $0.contains(id) }, at: at,
                                 snapshot: GuestMemorySnapshot(availableKB: total - used, totalKB: total,
                                                               pressureSome: some, pressureFull: full))
    }

    /// Which workspaces run unsandboxed (no egress policy), for the list's
    /// shield (macOS: refreshShieldState, also on every governance change).
    // @port ACAppDelegate.refreshShieldState() h=906ffb641e9b8c4e @f127f8ab
    func refreshShieldState(_ profiles: [Profile]) {
        let unsandboxed = Self.unsandboxedIDs(profiles)
        if listModel.unsandboxedProfileIDs != unsandboxed { listModel.unsandboxedProfileIDs = unsandboxed }
    }

    // @port ACAppDelegate.static unsandboxedIDs(_: [Profile]) h=9612b35dbe87e5fd @f127f8ab
    nonisolated static func unsandboxedIDs(_ profiles: [Profile]) -> Set<Profile.ID> {
        Set(profiles.filter { !$0.restrictsEgress }.map(\.id))
    }

    /// What the guest's hooks last said per workspace and window (macOS:
    /// RunningSession.agentStatus).
    private var agentStatus: [UUID: [Int: AgentStatus]] = [:]

    /// The guest's hook reports, `agent-status-<window>.txt` in the outbox or
    /// its hooks' folder (one-shot: read, then removed): line 1 the signal, line 2 the hook's
    /// conversation, which may move the report to its own tab (Codex's
    /// shared server). macOS: UbuntuSandboxVM's outbox poll + onAgentStatus.
    // @port-skip linux-only: the outbox poll of UbuntuSandboxVM.startOutboxPolling for agent-status files, on the host
    func readAgentStatus() {
        guard let store = SessionStores.shared?.sessions else { return }
        let fm = FileManager.default
        for id in Self.running.withLockedValue({ $0 }) {
            let outbox = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/"
            let files = HomeSeed.outboxFolders(outbox, SessionDisk.outboxAgentFolder).flatMap { dir in
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { (dir, $0) }
            }
            for (dir, name) in files where name.hasPrefix("agent-status-") && name.hasSuffix(".txt") {
                let raw = GuestOutbox.read(dir + name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(atPath: dir + name)
                guard let index = Int(name.dropFirst("agent-status-".count).dropLast(".txt".count)), !raw.isEmpty,
                      let status = AgentStatus(signal: raw) else { continue }
                let lines = raw.split(whereSeparator: \.isNewline)
                let conversation = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : nil
                guard let w = AgentSessionStore.statusWindow(index: index, conversation: conversation,
                                                             profileID: id, sessions: store.sessions) else { continue }
                setTabAgentStatus(id, index: w, status, turnEnded: AgentStatus.endsTurn(signal: raw))
            }
        }
    }

    /// A tab's hook status, with what the macOS app delegate does around it:
    /// a turn that ended or a question is a reply (unread on clients), and a
    /// new turn means no dialog waits any more. `turnEnded` false: a done
    /// that is only the agent idle at its prompt (an interrupt, a session
    /// end, an idle notification): the tab shows it, no run or task finishes.
    // @port ACAppDelegate.setTabAgentStatus(_: Profile.ID, index: Int, _: AgentStatus, turnEnded: Bool) h=122def8726c0a46e @5f46a841
    func setTabAgentStatus(_ id: UUID, index: Int, _ status: AgentStatus, turnEnded: Bool = true) {
        guard let store = SessionStores.shared?.sessions else { return }
        let before = agentStatus[id]?[index]
        agentStatus[id, default: [:]][index] = status
        let s = store.session(profileID: id, windowIndex: index)
        if Self.isReply(from: before, to: status), let s { store.noteReply(s.id) }
        if status == .working, let s, s.awaitingAnswer == true { _ = store.setAwaitingAnswer(s.id, false) }
        guard let tab = tabsModel(for: id)?.tabs.first(where: { $0.index == index }) else { return }
        tab.agentStatus = status
        // A finished tab may be an automation run (its transcript is saved,
        // its tab closed) or a coding task, which moves to Testing.
        if status == .done, let stores = SessionStores.shared {
            if turnEnded {
                stores.automationEngine?.agentFinished(profileID: id, worktreeBranch: tab.worktreeBranch)
                stores.codingTaskEngine?.agentFinished(profileID: id, worktreeBranch: tab.worktreeBranch)
            }
            // A request or a reply held while this agent worked goes now.
            stores.delegationEngine?.promptFreed(profileID: id, window: index)
        }
    }

    /// ACAppDelegate.isReply: a turn ended, or the agent started asking.
    // @port-skip linux-only: ACAppDelegate.isReply (a static in the app delegate)
    static func isReply(from before: AgentStatus?, to now: AgentStatus) -> Bool {
        switch now {
        case .done: return before == .working
        case .needsInput: return before != .needsInput
        case .working: return false
        }
    }

    /// The hook statuses, for /state's tabs (macOS's automationVMList).
    // @port-skip linux-only: daemon /state plumbing
    func tabStatuses() -> [UUID: [Int: String]] { agentStatus.mapValues { $0.mapValues(\.rawValue) } }

    /// When each session's tab was last read (capped, a few seconds apart).
    private var lastScan: [UUID: Date] = [:]
    private var scanning: Set<UUID> = []

    /// What the beautified view tells the store on macOS, from the tab's
    /// screen (TerminalScan): an agent waiting on its sign-in screen
    /// (needsSignIn), or on a dialog (awaiting an answer). On a server no
    /// pane is attached, so the host reads the tab itself.
    // @port-skip linux-only: the server-side half of the beautified view's loginPromptChanged / dialogPromptChanged
    private func scanLiveSessions(now: Date = Date()) {
        guard let store = SessionStores.shared?.sessions else { return }
        let up = Self.running.withLockedValue { $0 }
        for s in store.sessions where up.contains(s.profileID) && !s.hasEnded && !s.isArchived && !s.isDeleted {
            guard let w = s.windowIndex, !scanning.contains(s.id),
                  now.timeIntervalSince(lastScan[s.id] ?? .distantPast) >= 4 else { continue }
            lastScan[s.id] = now
            scanning.insert(s.id)
            let id = s.id, tool = s.tool.rawValue
            Task { [weak self] in
                let screen = try? await self?.guestExec(profileID: s.profileID,
                                                        command: "tmux capture-pane -p -J -t bromure:\(w) | tail -n 45", timeout: 10)
                guard let self else { return }
                self.scanning.remove(id)
                guard let screen else { return }
                var prompt: TerminalPrompt?
                if case .prompt(let p)? = TerminalScan.classify(screen, agent: tool) { prompt = p }
                store.setNeedsSignIn(id, prompt?.kind == .login)
                _ = store.setAwaitingAnswer(id, Self.isDialog(prompt))
            }
        }
        lastScan = lastScan.filter { k, _ in store.session(k) != nil }
    }

    /// The prompts that wait on an answer (BeautifiedSessionView.isDialog).
    // @port-skip linux-only: BeautifiedSessionView.isDialog, which is in a SwiftUI file
    static func isDialog(_ p: TerminalPrompt?) -> Bool {
        switch p?.kind {
        case .picker?, .checklist?, .trust?: return true
        default: return false
        }
    }

    // MARK: The guest

    // @port-skip linux-only: AgentSessionHost over the daemon (ACAppDelegate.guestExec)
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String {
        guard let daemon else { throw Daemon.GuestCommandError.unavailable("the daemon is stopping") }
        return try await daemon.guestExec(profileID: profileID, command: command, timeout: timeout)
    }

    // @port-skip linux-only: AgentSessionHost over the daemon (ACAppDelegate.guestFileOp)
    func guestFileOp(profileID: Profile.ID, op: [String: Any], timeout: Int) async throws -> [String: Any] {
        guard let daemon else { throw Daemon.GuestCommandError.unavailable("the daemon is stopping") }
        return try await daemon.guestFileOp(profileID: profileID, op: op, timeout: timeout)
    }

    /// The session's transcript from the guest, or from the attached
    /// machine it runs on.
    // @port ACAppDelegate.fetchSessionTranscript(_: AgentSession) h=fc500b26504a893e @9936e30c
    func fetchSessionTranscript(_ s: AgentSession) async -> String? {
        let cwd = SessionHome.guestPath(s.cwd)
        var pin = TranscriptPin.conversation(tool: s.tool.rawValue, id: s.agentTranscriptID)
        if s.tool == .kimi, let id = s.agentTranscriptID, AgentSessionLocator.isKimiSessionID(id) {
            pin.kimiSession = id
        } else if s.tool == .kimi, let store = LinuxMachines.shared?.attached[s.profileID]?.sessionStore ?? SessionStores.shared?.sessions {
            // Not pinned: at least never another session's own journal.
            pin.kimiExclude = store.kimiSessionsClaimed(profileID: s.profileID, besides: s.id)
        }
        guard let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 0,
                                                               agent: s.tool.rawValue, pin: pin) else { return nil }
        guard let out = try? await guestExec(profileID: s.profileID, command: cmd, timeout: 20), !out.isEmpty else { return nil }
        return out
    }

    /// A worktree command for the guest, queued in the outbox as macOS does.
    // @port ACAppDelegate.automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) h=671dcd9c1a40fa03 @9936e30c
    func automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) -> Bool {
        guard let id = UUID(uuidString: profileNameOrID) ?? profileID(named: profileNameOrID),
              Self.running.withLockedValue({ $0.contains(id) }),
              let line = GuestCommand.line(action: action, args: args) else { return false }
        let file = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/cmd-\(UUID().uuidString).txt"
        return (try? (line + "\n").write(toFile: file, atomically: true, encoding: .utf8)) != nil
    }

    // @port-skip linux-only: AgentSessionHost over the daemon
    func pushCodexAuth(profileID: UUID) async -> Bool { await daemon?.pushCodexAuth(profileID: profileID) ?? false }

    // @port-skip linux-only: AgentSessionHost over the daemon
    func pushClaudeStandIn(profileID: UUID) async -> Bool { await daemon?.pushClaudeStandIn(profileID: profileID) ?? false }

    // MARK: The workspace

    // @port-skip linux-only: ProfileStore lookup (macOS: the app's profile list)
    func profile(for id: Profile.ID) -> Profile? { ProfileStore().loadAll().first { $0.id == id } }

    // @port-skip linux-only: a profile id by name
    private func profileID(named name: String) -> UUID? {
        ProfileStore().loadAll().first { $0.name.lowercased() == name.lowercased() }?.id
    }

    /// Boots the workspace (all three: a server has no screen to ask on).
    // @port-skip linux-only: Daemon.startWorkspace
    func startProfile(_ id: Profile.ID) { boot(id) }
    // @port-skip linux-only: Daemon.startWorkspace
    func startProfileQuietly(_ id: Profile.ID) { boot(id) }
    // @port-skip linux-only: Daemon.startWorkspace
    func startProfileRemotely(_ id: Profile.ID) { boot(id) }
    /// Boots the workspace; a boot that fails is the workspace's refusal
    /// (unattendedLaunchRefusal) until the next attempt.
    // @port-skip linux-only: Daemon.startWorkspace
    func boot(_ id: UUID) {
        launchRefusals[id] = nil
        Task { @MainActor [weak self, weak daemon] in
            guard let why = await daemon?.startWorkspace(id) else { return }
            self?.launchRefusals[id] = why
            FileHandle.standardError.write(Data("bromure-ac daemon: workspace \(id.uuidString.prefix(8)) didn't start: \(why)\n".utf8))
        }
    }

    /// Why a workspace's last start failed, by workspace (macOS: a boot
    /// that needed a question nobody was there to answer): the engines
    /// fail at once on it rather than wait out the boot timeout.
    private var launchRefusals: [Profile.ID: String] = [:]

    // @port-skip linux-only: Linux's refusals are failed boots (macOS: refused prompts)
    func unattendedLaunchRefusal(_ id: Profile.ID) -> String? { launchRefusals[id] }

    /// The running workspace's roster, read now from its outbox (what agentd
    /// wrote last); nil when it isn't running.
    // @port-skip linux-only: the outbox roster (updateRoster)
    func tabsModel(for id: Profile.ID) -> TabsModel? {
        guard Self.running.withLockedValue({ $0.contains(id) }) else { tabs[id] = nil; return nil }
        let file = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/tabs.txt"
        updateRoster(id, GuestOutbox.parseRoster(GuestOutbox.read(file) ?? ""))
        return tabs[id]
    }

    /// Unknown here (macOS reads it from the attached pane's chat view).
    // @port-skip linux-only: no attached pane on a server
    func chatIsWorking(profileID: Profile.ID, window: Int) -> Bool? { nil }

    // @port-skip linux-only: tmux kill-window in the guest (macOS: the pane's close)
    func requestCloseTab(index: Int, profileID: Profile.ID) {
        Task { [weak daemon] in
            _ = try? await daemon?.guestExec(profileID: profileID, command: "tmux kill-window -t bromure:\(index)", timeout: 10)
        }
    }

    // @port ACAppDelegate.isAttachedMachine(_: Profile.ID) h=aa5e35128f21b4d7 @d2e3e97f
    func isAttachedMachine(_ id: Profile.ID) -> Bool { LinuxMachines.shared?.attached[id] != nil }
    // @port ACAppDelegate.sessionRecord(_: UUID) h=d3c22e99cc85bf05 @d2db8346
    func sessionRecord(_ id: UUID) -> AgentSession? {
        SessionStores.shared?.sessions.session(id)
            ?? LinuxMachines.shared?.attached.values.lazy.compactMap { $0.sessionStore.session(id) }.first
    }
    // @port ACAppDelegate.attachedMachineExec(sessionID: UUID, command: String, timeout: Int) h=9198a0e7c4994035 @d2e3e97f
    func attachedMachineExec(sessionID id: UUID, command: String, timeout: Int) async throws -> String? {
        guard let machine = LinuxMachines.shared?.machine(forSession: id) else { return nil }
        return try await machine.hostExec(command, timeout: timeout)
    }

    // MARK: App state

    // @port-skip linux-only: the daemon's room store
    var agentRoomStore: AgentRoomStore { SessionStores.shared!.rooms }
    // @port-skip linux-only: the daemon's coding-task engine (ACAppDelegate.codingTaskOwnsLiveTab)
    func codingTaskOwnsLiveTab(profileID: Profile.ID, branch: String) -> Bool {
        SessionStores.shared?.codingTaskEngine?.ownsLiveTab(profileID: profileID, branch: branch) ?? false
    }
    /// A server has no window following a session.
    // @port-skip linux-only: no window to follow a session on a server
    func followSucceededSession(old: UUID, new: UUID) {}
}
