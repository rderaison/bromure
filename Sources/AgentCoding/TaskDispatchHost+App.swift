import Foundation

/// The macOS app's board dispatcher host: its window's session list and
/// its Switchboard engine.
extension ACAppDelegate: TaskDispatchHost {
    var sessionListModel: SessionListModel? { unifiedWindow?.listModel }
    func attachedMachineName(_ id: Profile.ID) -> String? { attachedMachines[id]?.name }
    func ensureSwitchboard(room: AgentRoom?) -> UUID? { switchboardEngine.ensureSwitchboard(room: room) }
}

/// And the Switchboard's host (its members are the app delegate's own).
extension ACAppDelegate: SwitchboardHost {}
