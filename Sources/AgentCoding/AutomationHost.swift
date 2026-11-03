import Foundation

/// What the scheduled-automation engine needs from the app that runs it
/// (macOS: ACAppDelegate; the Linux daemon is another). Model terms only.
@MainActor
protocol AutomationHost: AnyObject {
    // The guest.
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String
    func automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) -> Bool
    func pullAutomationTranscript(profileID: Profile.ID, branch: String, runID: UUID, tool: Profile.Tool) async
    func waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool?,
                             quiet: Int, cap: TimeInterval) async -> Bool

    // Workspaces.
    func profile(for id: Profile.ID) -> Profile?
    func startProfileForAutomation(_ id: Profile.ID, detached: Bool)
    func unattendedLaunchRefusal(_ id: Profile.ID) -> String?
    func workspaceOpenElsewhere(_ id: Profile.ID) -> Bool
    func cloneWorkspaceForAutomation(_ baseID: Profile.ID, runSlug: String) async -> Profile?
    func destroyAutomationClone(_ id: Profile.ID)
    func openWorktreeBranches(profileID: UUID) -> [String]
    func liveWorktreeBranches(profileID: UUID) -> [String]?
    func archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String,
                                windowIDs: Set<String>?, strict: Bool)

    /// The coding-task engine's refusal bookkeeping, settled on each tick.
    func settleCodingTaskRefusals(now: Date, liveBranches: (UUID) -> [String])
}

extension AutomationHost {
    func pullAutomationTranscript(profileID: Profile.ID, branch: String, runID: UUID) async {
        await pullAutomationTranscript(profileID: profileID, branch: branch, runID: runID, tool: .claude)
    }
    func waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool? = nil) async -> Bool {
        await waitForSessionQuiet(profileID: profileID, branch: branch, tool: tool, quiet: 20, cap: 1800)
    }
    func startProfileForAutomation(_ id: Profile.ID) { startProfileForAutomation(id, detached: false) }
    func archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String) {
        archiveFinishedSession(profileID: profileID, worktreeBranch: worktreeBranch, windowIDs: nil, strict: false)
    }
}
