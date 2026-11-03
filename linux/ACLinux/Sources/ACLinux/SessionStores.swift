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
    /// The repository watches and their findings (macOS: the app
    /// delegate's findingStore).
    let findings: FindingStore
    /// Kubernetes clusters and container registries (macOS: the app
    /// delegate's kubeClusterStore), at `<state>/kube/clusters.json`.
    let kube: KubeClusterStore
    /// The workspaces' instruction presets (macOS: the app delegate's store).
    let instructionPresets: InstructionPresetStore
    /// The engines over them (Daemon.startSessionEngine).
    var engine: AgentSessionEngine?
    var codingTaskEngine: CodingTaskEngine?
    var automationEngine: ScheduledAutomationEngine?
    var delegationEngine: DelegationEngine?
    var taskDispatcher: TaskDispatcher?
    /// The watch engine and its host (DaemonWatches.swift).
    var watchEngine: RepoWatchEngine?
    var watchHost: LinuxRepoWatchHost?
    /// The cluster engine and its machine host (DaemonKube.swift).
    var kubeEngine: KubeClusterEngine?
    var kubeHost: LinuxKubeHost?

    // @port-skip linux-only: daemon layout
    init(stateDir: String) {
        let dir = URL(fileURLWithPath: stateDir, isDirectory: true)
        sessions = AgentSessionStore(fileURL: dir.appendingPathComponent("sessions.json"))
        rooms = AgentRoomStore(fileURL: dir.appendingPathComponent("rooms.json"))
        delegations = DelegationStore(fileURL: dir.appendingPathComponent("delegations.json"))
        codingTasks = CodingTaskStore(fileURL: dir.appendingPathComponent("tasks.json"))
        automations = ScheduledAutomationStore(fileURL: dir.appendingPathComponent("automations.json"))
        findings = FindingStore(fileURL: dir.appendingPathComponent("findings.json"))
        kube = KubeClusterStore(fileURL: dir.appendingPathComponent("kube", isDirectory: true)
            .appendingPathComponent("clusters.json"))
        instructionPresets = InstructionPresetStore(fileURL: dir.appendingPathComponent("instruction-presets.json"))
    }

    /// The /state keys macOS adds on a server with the sessions-first home.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListAgentSessions h=8888028888b19ce0 @7dd92fdf
    func stateEntries() -> [String: JSONValue] {
        [
            "agentSessions": .array(sessions.sessions.compactMap(JSONValue.encoding)),
            "delegations": .array(delegations.delegations.compactMap(JSONValue.encoding)),
            "agentRooms": .array(rooms.rooms.compactMap(JSONValue.encoding)),
        ].merging(registrationEntries()) { a, _ in a }.merging(instructionPresetEntries()) { a, _ in a }
    }

    /// `/state`'s `instructionPresets`, as macOS lists them.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListInstructionPresets h=5b321de5628eebbb @acdf5f11
    func instructionPresetEntries() -> [String: JSONValue] {
        ["instructionPresets": JSONValue(foundation: InstructionPresetStore.wire(instructionPresets.presets)) ?? .array([])]
    }

    /// `POST /instruction-presets {presets}`: the whole list, replaced.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSetInstructionPresets h=66fc3d516770cc4e @acdf5f11
    func setInstructionPresets(_ list: [[String: Any]]) {
        instructionPresets.replace(InstructionPresetStore.fromWire(list))
    }

    /// The sign-in a client started, while it runs, and how recent ones
    /// ended (macOS: the same keys, from RemoteRegistrationBroker).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onPendingRegistration h=037369d21d9ebaf2 @dd7ba30d
    func registrationEntries() -> [String: JSONValue] {
        let broker = RemoteRegistrationBroker.shared
        var out: [String: JSONValue] = [:]
        if let p = broker.stateDict() { out["pendingRegistration"] = JSONValue(foundation: p) }
        if let e = broker.endedDict() { out["registrationEnded"] = JSONValue(foundation: e) }
        let list = broker.endedList()
        if !list.isEmpty { out["registrationsEnded"] = JSONValue(foundation: list) }
        return out
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
