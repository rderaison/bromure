import Foundation

/// What the coding-task engine needs from the app that runs it (macOS:
/// ACAppDelegate; the Linux daemon is another). Model terms only, no UI:
/// the tab roster is a TabsModel, the task dispatcher is behind three calls.
@MainActor
protocol CodingTaskHost: AnyObject {
    // The guest.
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String
    func automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) -> Bool
    func fetchTaskTranscriptRaw(_ task: CodingTask) async -> String?
    func pretrustGuestPath(profileID: Profile.ID, dir: String) async
    func waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool?,
                             quiet: Int, cap: TimeInterval) async -> Bool

    // The workspace.
    func profile(for id: Profile.ID) -> Profile?
    func startProfileForAutomation(_ id: Profile.ID, detached: Bool)
    func unattendedLaunchRefusal(_ id: Profile.ID) -> String?
    /// The workspace's live tab roster; nil while it isn't attached here.
    func tabsModel(for id: Profile.ID) -> TabsModel?
    func archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String,
                                windowIDs: Set<String>?, strict: Bool)

    // Plan streams (the planning chat's live channel).
    func planStreamLive(profileID: Profile.ID, branch: String) -> Bool
    func endPlanStream(profileID: Profile.ID, branch: String)

    // The agent sessions and the task dispatcher.
    var agentSessionStore: AgentSessionStore { get }
    func dispatcherSendBack(_ taskID: UUID, feedback: String) async -> Bool
    func dispatcherSteerLanding(_ taskID: UUID, text: String) async -> Bool
    func dispatcherRecall(_ taskID: UUID)
}

extension CodingTaskHost {
    /// waitForSessionQuiet with ACAppDelegate's defaults (20 s quiet, 30 min cap).
    func waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool? = nil) async -> Bool {
        await waitForSessionQuiet(profileID: profileID, branch: branch, tool: tool, quiet: 20, cap: 1800)
    }
    func startProfileForAutomation(_ id: Profile.ID) { startProfileForAutomation(id, detached: false) }
    func archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String) {
        archiveFinishedSession(profileID: profileID, worktreeBranch: worktreeBranch, windowIDs: nil, strict: false)
    }
}
