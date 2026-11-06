#if os(macOS)
import Foundation

/// The macOS app as the agent-session engine's host: the members the engine
/// uses that ACAppDelegate doesn't spell this way already.
extension ACAppDelegate: AgentSessionHost {
    func tabsModel(for id: Profile.ID) -> TabsModel? { pane(for: id)?.model }

    func guestMemoryReport(for id: Profile.ID) -> GuestMemoryReport? {
        guard let vm = runningSessions[id] else { return nil }
        return GuestMemoryReport(
            unresponsive: vm.guestUnresponsive, at: vm.vmStatsAt,
            snapshot: GuestMemorySnapshot(availableKB: vm.vmMemTotalKB - vm.vmMemUsedKB, totalKB: vm.vmMemTotalKB,
                                          pressureSome: vm.vmMemPressureSome, pressureFull: vm.vmMemPressureFull))
    }

    func chatIsWorking(profileID: Profile.ID, window: Int) -> Bool? {
        pane(for: profileID)?.chatIsWorking(window: window)
    }

    func requestCloseTab(index: Int, profileID: Profile.ID) {
        guard let pane = pane(for: profileID) else { return }
        requestCloseTab(index: index, in: pane)
    }

    func isAttachedMachine(_ id: Profile.ID) -> Bool { attachedMachines[id] != nil }

    func attachedMachineExec(sessionID id: UUID, command: String, timeout: Int) async throws -> String? {
        guard let machine = machine(forSession: id) else { return nil }
        return try await machine.hostExec(command, timeout: timeout)
    }

    func codingTaskOwnsLiveTab(profileID: Profile.ID, branch: String) -> Bool {
        codingTaskEngine.ownsLiveTab(profileID: profileID, branch: branch)
    }

    func followSucceededSession(old: UUID, new: UUID) {
        guard let w = unifiedWindow, w.selectedSessionID == old else { return }
        w.selectSession(new)
    }
}
#endif
