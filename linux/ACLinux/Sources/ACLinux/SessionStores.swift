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
    /// encodedRows' memo, per list.
    let encodedRowMemo = EncodedRowMemo()
    var taskDispatcher: TaskDispatcher?
    var switchboardEngine: SwitchboardEngine?
    /// The watch engine and its host (DaemonWatches.swift).
    var watchEngine: RepoWatchEngine?
    var watchHost: LinuxRepoWatchHost?
    /// The cluster engine and its machine host (DaemonKube.swift).
    var kubeEngine: KubeClusterEngine?
    var kubeHost: LinuxKubeHost?
    /// Streamed planning sessions (macOS: the app delegate's planStreamHub)
    /// and each running workspace's plan-stream listener (its
    /// planEventBridges), DaemonPlanStreams.swift.
    let planStreamHub = PlanStreamHub()
    var planBridges: [UUID: PlanStreamListener] = [:]

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
        wirePlanStreamHub()
    }

    /// The /state keys macOS adds on a server with the sessions-first home.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListAgentSessions h=98721b804428bec6 @b41d9876
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListDelegations h=392fda274198fde9 @d3ebbda2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListAgentRooms h=5be9e5a9c56a8a1a @d3ebbda2
    func stateEntries() -> [String: JSONValue] {
        [
            // What Squelch saved in each conversation rides along: a client
            // has no ledger of the host's (macOS: the same).
            "agentSessions": .array(encodedRows(sessions.sessions.map { s -> AgentSession in
                var s = s
                if let tid = s.agentTranscriptID { s.squelch = SquelchLedger.shared.conversation(s.profileID, tid) }
                return s
            }, "agentSessions")),
            "delegations": .array(encodedRows(delegations.delegations, "delegations")),
            "agentRooms": .array(encodedRows(rooms.rooms, "agentRooms")),
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
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onEndedRegistration h=efb9670035ce699d @d3ebbda2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onEndedRegistrations h=4db4840de7a5bde7 @d3ebbda2
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

extension SessionStores {
    /// The /state lists' rows, each reused while its item stays the same
    /// (EncodedRowMemo: /state is rebuilt for every poll and push, and
    /// almost every row is unchanged from one to the next).
    // @port ACAppDelegate.encodedRows(_: [T], _: String) h=901726a3ed0f8aa0 @641863f2
    func encodedRows<T: Encodable & Equatable & Identifiable>(_ items: [T], _ key: String) -> [JSONValue] {
        encodedRowMemo.rows(items, key, encode: JSONValue.encoding)
    }

    /// The same, as JSONSerialization's objects (the board's lists). Its
    /// keys are its own: one key keeps one kind of row.
    // @port-skip linux-only: encodedRows for the routes that answer in Foundation objects
    func encodedDicts<T: Encodable & Equatable & Identifiable>(_ items: [T], _ key: String) -> [[String: Any]] {
        encodedRowMemo.rows(items, "dict:" + key) { JSONValue.encoding($0)?.foundationObject as? [String: Any] }
    }
}
