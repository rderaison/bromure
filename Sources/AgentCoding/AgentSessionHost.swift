import Foundation

/// What the agent-session engine needs from the app that runs it: the
/// guest (exec, file ops, transcripts), the workspace's lifecycle and tab
/// roster, and a few bits of app state. ACAppDelegate is the macOS host; the
/// Linux daemon is another. No UI types: a host answers in model terms (the
/// tab roster is a TabsModel), so the engine builds without AppKit.
@MainActor
protocol AgentSessionHost: AnyObject {
    // The guest.
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String
    func guestFileOp(profileID: Profile.ID, op: [String: Any], timeout: Int) async throws -> [String: Any]
    func fetchSessionTranscript(_ s: AgentSession) async -> String?
    func automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) -> Bool
    @discardableResult func pushCodexAuth(profileID: UUID) async -> Bool
    @discardableResult func pushClaudeStandIn(profileID: UUID) async -> Bool

    // The workspace.
    func profile(for id: Profile.ID) -> Profile?
    func startProfile(_ id: Profile.ID)
    func startProfileQuietly(_ id: Profile.ID)
    func startProfileRemotely(_ id: Profile.ID)
    func unattendedLaunchRefusal(_ id: Profile.ID) -> String?
    /// The workspace's live tab roster; nil while it isn't attached here.
    func tabsModel(for id: Profile.ID) -> TabsModel?
    /// Whether the agent in tab `window` is working (nil: unknown).
    func chatIsWorking(profileID: Profile.ID, window: Int) -> Bool?
    /// Close tab `index` of the workspace (the agent in it with it).
    func requestCloseTab(index: Int, profileID: Profile.ID)
    /// An attached Mac (Bromure Sidecar), not a VM.
    func isAttachedMachine(_ id: Profile.ID) -> Bool
    /// A session record the store doesn't hold (an attached Mac's mirror).
    func sessionRecord(_ id: UUID) -> AgentSession?
    /// `command` run on the attached Mac that holds session `id`; nil when
    /// no attached Mac does (the caller runs it in the guest).
    func attachedMachineExec(sessionID id: UUID, command: String, timeout: Int) async throws -> String?

    // App state.
    var agentRoomStore: AgentRoomStore { get }
    /// Whether a coding task's own tab is live for `branch` in the workspace.
    func codingTaskOwnsLiveTab(profileID: Profile.ID, branch: String) -> Bool
    /// A session that was shown got succeeded by a new run: follow it.
    func followSucceededSession(old: UUID, new: UUID)
}
