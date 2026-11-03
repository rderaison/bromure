import Foundation

/// The shared session model's stores, kept in the daemon's state dir (macOS:
/// the app delegate's, in Application Support): agent sessions, rooms and
/// delegations. /state carries them as macOS's does; the session engine
/// reads and writes them.
// @port-skip linux-only: the daemon's holder for stores the macOS app delegate owns
@MainActor
final class SessionStores {
    /// Set once, at daemon start.
    static var shared: SessionStores?

    let sessions: AgentSessionStore
    let rooms: AgentRoomStore
    let delegations: DelegationStore
    let codingTasks: CodingTaskStore
    let automations: ScheduledAutomationStore
    /// The engines over them (Daemon.startSessionEngine).
    var engine: AgentSessionEngine?
    var codingTaskEngine: CodingTaskEngine?
    var automationEngine: ScheduledAutomationEngine?

    // @port-skip linux-only: daemon layout
    init(stateDir: String) {
        let dir = URL(fileURLWithPath: stateDir, isDirectory: true)
        sessions = AgentSessionStore(fileURL: dir.appendingPathComponent("sessions.json"))
        rooms = AgentRoomStore(fileURL: dir.appendingPathComponent("rooms.json"))
        delegations = DelegationStore(fileURL: dir.appendingPathComponent("delegations.json"))
        codingTasks = CodingTaskStore(fileURL: dir.appendingPathComponent("tasks.json"))
        automations = ScheduledAutomationStore(fileURL: dir.appendingPathComponent("automations.json"))
    }

    /// The /state keys macOS adds on a server with the sessions-first home.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListAgentSessions h=8888028888b19ce0 @7dd92fdf
    func stateEntries() -> [String: JSONValue] {
        [
            "agentSessions": .array(sessions.sessions.compactMap(JSONValue.encoding)),
            "delegations": .array(delegations.delegations.compactMap(JSONValue.encoding)),
            "agentRooms": .array(rooms.rooms.compactMap(JSONValue.encoding)),
        ]
    }
}

extension JSONValue {
    /// A Codable value as macOS's control API sends it (ISO-8601 dates).
    // @port-skip linux-only: ACAppDelegate.codableToDict for JSONValue
    static func encoding<T: Encodable>(_ value: T) -> JSONValue? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
