import Foundation

/// What the board's dispatcher (TaskDispatcher) needs from its host: the
/// board and its engines, the sessions it can hand a task to, and the
/// Switchboard that takes a room's. The macOS app delegate is one
/// (TaskDispatchHost+App.swift).
@MainActor
protocol TaskDispatchHost: AgentSessionHost {
    var codingTaskStore: CodingTaskStore { get }
    var codingTaskEngine: CodingTaskEngine { get }
    var delegationEngine: DelegationEngine { get }
    /// This host's sessions and its attached machines'.
    var allSessionRecords: [AgentSession] { get }
    /// The session list's model, for whether a session is working or waits
    /// on the user; nil when there's no window (every live session is then
    /// free unless its agent is mid-turn).
    var sessionListModel: SessionListModel? { get }
    /// An attached machine's name (a Bromure Sidecar), nil for a workspace.
    func attachedMachineName(_ id: Profile.ID) -> String?
    /// The Switchboard's session (the room's, with `room`), started if it
    /// isn't running; nil when there's nowhere to run it.
    func ensureSwitchboard(room: AgentRoom?) -> UUID?
}
