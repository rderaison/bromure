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

    private weak var daemon: Daemon?
    private let stateDir: String
    /// Running workspaces' rosters (nil: not running, as macOS's "attached").
    private var tabs: [UUID: TabsModel] = [:]

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
        model.tabs = roster.map {
            TabsModel.Tab(label: $0.label, index: $0.index, containerID: $0.containerID, cwd: $0.cwd,
                          worktreeBranch: $0.worktreeBranch, parentBranch: $0.parentBranch,
                          rootRepo: $0.rootRepo, display: $0.display, repoRoot: $0.repoRoot)
        }
        model.activeIndex = roster.firstIndex(where: \.active) ?? 0
        model.rosterLive = true
        tabs[id] = model
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

    /// The session's transcript from the guest (macOS's body, without the
    /// attached-machine branch).
    // partial: no attached machines on Linux
    // @port ACAppDelegate.fetchSessionTranscript(_: AgentSession) h=fc500b26504a893e @9936e30c
    func fetchSessionTranscript(_ s: AgentSession) async -> String? {
        let cwd = SessionHome.guestPath(s.cwd)
        var pin = TranscriptPin.conversation(tool: s.tool.rawValue, id: s.agentTranscriptID)
        if s.tool == .kimi, let id = s.agentTranscriptID, AgentSessionLocator.isKimiSessionID(id) {
            pin.kimiSession = id
        } else if s.tool == .kimi, let store = SessionStores.shared?.sessions {
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
    // @port-skip linux-only: Daemon.startWorkspace
    private func boot(_ id: UUID) {
        Task { [weak daemon] in
            if let why = await daemon?.startWorkspace(id) {
                FileHandle.standardError.write(Data("bromure-ac daemon: workspace \(id.uuidString.prefix(8)) didn't start: \(why)\n".utf8))
            }
        }
    }

    /// No launch is refused unattended here (macOS: a boot that needed a
    /// question nobody was there to answer).
    // @port-skip linux-only: no unattended-launch refusals on a server
    func unattendedLaunchRefusal(_ id: Profile.ID) -> String? { nil }

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

    // @port-skip linux-only: no attached machines on Linux
    func isAttachedMachine(_ id: Profile.ID) -> Bool { false }
    // @port-skip linux-only: the daemon's session store
    func sessionRecord(_ id: UUID) -> AgentSession? { SessionStores.shared?.sessions.session(id) }
    // @port-skip linux-only: no attached machines on Linux
    func attachedMachineExec(sessionID id: UUID, command: String, timeout: Int) async throws -> String? { nil }

    // MARK: App state

    // @port-skip linux-only: the daemon's room store
    var agentRoomStore: AgentRoomStore { SessionStores.shared!.rooms }
    /// No coding tasks on Linux yet.
    // partial: no coding tasks yet
    // @port-skip linux-only: no coding tasks yet
    func codingTaskOwnsLiveTab(profileID: Profile.ID, branch: String) -> Bool { false }
    /// A server has no window following a session.
    // @port-skip linux-only: no window to follow a session on a server
    func followSucceededSession(old: UUID, new: UUID) {}
}
