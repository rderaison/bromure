import Foundation

/// Machines attached to this server (a Bromure Agent Host or Sidecar dials
/// in and parks links: MachineLinks.swift, shared as it is). The control
/// routes and /state are the daemon's; the roster of attached machines,
/// their session mirrors and delegation relays are LinuxMachines' (macOS:
/// ACAutomationServer's /machines routes, ACAppDelegate's attachedMachines).
extension Daemon {
    /// The /machines routes, and any request aimed at an attached machine
    /// (proxied down one of its links); nil when it's neither. Every
    /// control connection here is the owner's (SO_PEERCRED), as macOS's
    /// isTrustedLocal; an agent host's key comes in through the SSH
    /// server's link verb, which writes the owner itself.
    // @port-skip linux-only: the /machines block of ACAutomationServer.route (inside its isTrustedLocal branch, not a segment of its own), over the Linux router
    func machineRoute(_ req: ControlRequest, _ path: String) -> ControlResponse? {
        let hub = MachineLinkHub.shared
        let body = req.body.foundationObject as? [String: Any] ?? [:]
        let uuid = { (k: String) in (body[k] as? String).flatMap(UUID.init(uuidString:)) }
        switch (req.method, path) {
        case ("POST", "/machines/link"):
            guard let id = uuid("id") else { return .error(400, "id required") }
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
            let owner = body["owner"] as? String
            // A machine may not take the id of a workspace or VM here: their
            // traffic would be routed to it.
            let reserved = Set(records.compactMap { UUID(uuidString: $0.id) })
            let verdict = hub.admit(id: id, owner: owner, reserved: reserved)
            if case .refused(let why) = verdict { return .error(403, why) }
            // The 200 first: once parked, a verb may follow at any moment. A
            // machine the user hasn't let in yet hears that it waits.
            let fleet = verdict == .pending ? "X-Bromure-Fleet: pending\r\n" : ""
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\(fleet)\r\n"
            return .descriptor(head: head, closeWithClient: true) { fd in
                if !hub.park(fd: fd, id: id, name: String(name.prefix(80)), owner: owner, reserved: reserved) { close(fd) }
            }
        case ("POST", "/machines/approve"):
            // The user's answer to a machine asking to join (or a listed /
            // blocked one): {id, allow}.
            guard let id = uuid("id"), let allow = body["allow"] as? Bool else {
                return .error(400, "id and allow required")
            }
            guard hub.decide(id: id, allow: allow) else { return .error(404, "No such machine") }
            return ControlResponse(200, ["ok": true])
        case ("POST", "/machines/forget"):
            // Unblock: the machine asks again next time it dials.
            guard let id = uuid("id") else { return .error(400, "id required") }
            hub.forget(id: id)
            return ControlResponse(200, ["ok": true])
        case ("POST", "/machines/detach"):
            if let id = uuid("id"), !hub.detach(id: id, owner: body["owner"] as? String) {
                return .error(403, "That machine is attached by another device")
            }
            return ControlResponse(200, ["ok": true])
        default:
            if req.method == "POST", Self.isTypeRoute(path) { return nil }
            guard let machine = hub.target(method: req.method, path: req.path, body: body) else { return nil }
            let gzip = req.headers["x-bromure-gzip"] == "1" || (req.headers["accept-encoding"] ?? "").contains("gzip")
            let method = req.method, full = req.path
            return .descriptor(head: "") { fd in
                hub.proxy(clientFD: fd, machine: machine, method: method, path: full, body: body, gzip: gzip)
            }
        }
    }

    /// POST /vms/<id>/type (macOS: ACAutomationServer.typeRouteID), which a
    /// machine's pane is typed into on this host, not proxied.
    // @port ACAutomationServer.static typeRouteID(_: String) h=cde069cfd214d422 @7dd92fdf
    static func isTypeRoute(_ path: String) -> Bool {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard bare.hasPrefix("/vms/"), bare.hasSuffix("/type") else { return false }
        let id = String(bare.dropFirst("/vms/".count).dropLast("/type".count))
        return !id.isEmpty && !id.contains("/")
    }

    /// The machines' part of /state: those asking to join and the blocked
    /// ones, and each attached machine as one more workspace + VM, with its
    /// sessions.
    // @port-skip linux-only: the machines' lines of ACAutomationServer.buildStateSnapshot, for the Linux /state (Daemon.stateBody)
    static func withMachines(_ state: [String: JSONValue]) -> [String: JSONValue] {
        var s = state
        let admissions = MachineLinkHub.shared.admissionState()
        if !admissions.pending.isEmpty { s["pendingMachines"] = JSONValue(foundation: admissions.pending) }
        if !admissions.blocked.isEmpty { s["blockedMachines"] = JSONValue(foundation: admissions.blocked) }
        let machines = MachineLinkHub.shared.stateAdditions()
        guard !machines.workspaces.isEmpty else { return s }
        func plus(_ key: String, _ more: [[String: Any]]) {
            guard case .array(let have)? = s[key] ?? .array([]), case .array(let add)? = JSONValue(foundation: more) else { return }
            s[key] = .array(have + add)
        }
        plus("workspaces", machines.workspaces)
        plus("vms", machines.vms)
        if s["agentSessions"] != nil { plus("agentSessions", machines.sessions) }
        return s
    }
}

/// The machines attached here: each one's session mirror and delegation
/// relay, made as it joins and stopped as it leaves (macOS: ACAppDelegate's
/// attachedMachines and watchAttachedMachines).
// @port-skip linux-only: the daemon's holder for what the macOS app delegate keeps
@MainActor
final class LinuxMachines {
    /// Set once, at daemon start.
    static var shared: LinuxMachines?
    private(set) var attached: [UUID: AttachedMachine] = [:]
    private var observer: NSObjectProtocol?
    /// Session -> room for sessions on attached machines. This server decides
    /// them (a machine's own word isn't taken: it could seat itself in any
    /// room) and stamps them on what it reads from the machine.
    private(set) var sessionRooms: [UUID: UUID] = [:]
    private let sessionRoomsURL: URL

    /// Follow machines attaching and detaching; the user's answers to
    /// machines asking to join are kept in the state dir.
    // @port ACAppDelegate.watchAttachedMachines() h=4225ae8ed5d459db @d2db8346
    init(stateDir: String) {
        let dir = URL(fileURLWithPath: stateDir, isDirectory: true)
        MachineLinkHub.shared.storeURL = dir.appendingPathComponent("machines.json")
        sessionRoomsURL = dir.appendingPathComponent("machine-session-rooms.json")
        sessionRooms = Self.loadSessionRooms(sessionRoomsURL)
        // A session a remote client starts on a machine straight into a room
        // ("Add to Room"): the room is recorded here.
        MachineLinkHub.shared.onSessionStarted = { sid, body in
            let room = (body["room"] as? String).flatMap(UUID.init(uuidString:))
            Task { @MainActor in LinuxMachines.shared?.assignRoom(sid, room) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: MachineLinkHub.machinesChanged, object: nil, queue: nil) { note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in LinuxMachines.shared?.changed(id) }
        }
    }

    // @port-skip linux-only: watchAttachedMachines' observer body (the function's own @port is on init)
    private func changed(_ id: UUID) {
        if let name = MachineLinkHub.shared.name(id) {
            guard attached[id] == nil else { return }
            FatClientLog.log("machines: \(name) attached")
            let m = AttachedMachine(id: id, name: name) { m in
                DelegationMCPServer(profileID: m.id,
                                    sessions: { [weak m] in m?.sessionStore },
                                    engine: { SessionStores.shared?.delegationEngine })
            }
            // A session id this host (or another machine) owns can't be
            // claimed by this one.
            m.foreignSessionIDs = { [weak m] in
                guard let shared = LinuxMachines.shared else { return [] }
                var ids = Set(SessionStores.shared?.sessions.sessions.map(\.id) ?? [])
                for (other, o) in shared.attached where other != m?.id {
                    ids.formUnion(o.sessionStore.sessions.map(\.id))
                }
                return ids
            }
            // Its sessions' rooms are this server's to say.
            m.roomOf = { sid in
                guard let r = LinuxMachines.shared?.sessionRooms[sid], SessionStores.shared?.rooms.room(r) != nil
                else { return nil }
                return r
            }
            attached[id] = m
        } else if let m = attached.removeValue(forKey: id) {
            m.stop()
        }
    }

    /// The attached machine a session runs on, if it isn't one of ours.
    // @port ACAppDelegate.machine(forSession: UUID) h=0569693be05282e2 @d2db8346
    func machine(forSession id: UUID) -> AttachedMachine? {
        guard SessionStores.shared?.sessions.session(id) == nil else { return nil }
        return attached.values.first { $0.sessionStore.session(id) != nil }
    }

    /// A machine session's room (nil: none), kept across restarts.
    // @port-skip linux-only: setRoom's machine branch, the store half (macOS: machineSessionRooms + saveMachineSessionRooms)
    func setSessionRoom(_ sid: UUID, _ room: UUID?) {
        sessionRooms[sid] = room
        save()
    }

    /// A session just started on an attached machine, into `room`: recorded
    /// at once (the machine's mirror may not list it yet; the next poll
    /// stamps it).
    // @port ACAppDelegate.assignMachineRoom(_: UUID, _: UUID?) h=04712b4dc53c7211 @d2db8346
    func assignRoom(_ sid: UUID, _ room: UUID?) {
        guard let room, SessionStores.shared?.rooms.room(room) != nil else { return }
        setSessionRoom(sid, room)
        for m in attached.values where m.sessionStore.session(sid) != nil {
            m.sessionStore.mutate(sid) { $0.roomID = room }
        }
    }

    // @port-skip linux-only: machineSessionRooms' lazy initializer (not a function portmap tracks), at the state dir
    private static func loadSessionRooms(_ url: URL) -> [UUID: UUID] {
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in
            UUID(uuidString: k).flatMap { key in UUID(uuidString: v).map { (key, $0) } }
        })
    }

    // @port ACAppDelegate.saveMachineSessionRooms() h=fa53d569bfb04b21 @d2db8346
    private func save() {
        // Rooms that no longer exist drop out.
        let live = Set(SessionStores.shared?.rooms.rooms.map(\.id) ?? [])
        sessionRooms = sessionRooms.filter { live.contains($0.value) }
        let d = Dictionary(uniqueKeysWithValues: sessionRooms.map { ($0.key.uuidString, $0.value.uuidString) })
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: sessionRoomsURL, options: .atomic) }
    }

    /// `command` on the attached machine `profileID`; nil when it isn't one.
    // @port-skip linux-only: the attached-machine branch of ACAppDelegate.guestExec, for the daemon actor
    static func exec(profileID: UUID, command: String, timeout: Int) async throws -> String? {
        guard let m = shared?.attached[profileID] else { return nil }
        return try await m.hostExec(command, timeout: timeout)
    }
}
