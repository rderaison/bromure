import Foundation

/// Rooms, delegations across hosts and the grid layout for a fat client
/// (macOS: the automation server's /agent-rooms, /delegations and
/// /grid-layout routes and the app delegate's callbacks behind them).
extension Daemon {
    /// `POST /agent-rooms/<action>` or `/agent-rooms/<id>/<action>`,
    /// `/delegations/request`, `GET /delegations/<id>/file?path=…`, `POST
    /// /delegations/<id>/<action>`, `GET|PUT /grid-layout`; nil otherwise.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    func roomsRoute(_ method: String, _ fullPath: String, _ body: JSONValue) async -> ControlResponse? {
        let pq = fullPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pq[0], query = pq.count > 1 ? pq[1] : ""
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        func reply(_ r: [String: Any]) -> ControlResponse {
            ControlResponse(r["error"] == nil ? 200 : 400, JSONValue(foundation: r) ?? .object([:]))
        }
        switch (method, path) {
        case ("POST", let p) where p.hasPrefix("/agent-rooms/"):
            let parts = String(p.dropFirst("/agent-rooms/".count))
                .split(separator: "/", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            let id = parts.count > 1 ? UUID(uuidString: parts[0]) : nil
            guard let action = parts.last, parts.count == 1 || id != nil else { return .error(400, "Bad room id or action") }
            let r = await MainActor.run { LinuxSessionHost.shared?.roomCommand(id, action, doc) ?? ["error": "no session host"] }
            return reply(r)
        case ("POST", "/delegations/request"):
            return reply(await delegationRequest(doc))
        case ("GET", let p) where p.hasPrefix("/delegations/") && p.contains("/file"):
            var q: [String: String] = [:]
            for kv in query.split(separator: "&") {
                let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { q[pair[0]] = pair[1].removingPercentEncoding ?? pair[1] }
            }
            let idStr = String(p.dropFirst("/delegations/".count)).split(separator: "/").first.map(String.init) ?? ""
            guard let did = UUID(uuidString: idStr), let file = q["path"], !file.isEmpty else {
                return .error(400, "Bad delegation id or path")
            }
            return reply(await delegationFile(did, file, Int64(q["offset"] ?? "0") ?? 0, Int(q["length"] ?? "4194304") ?? 4_194_304))
        case ("POST", let p) where p.hasPrefix("/delegations/"):
            let parts = String(p.dropFirst("/delegations/".count)).split(separator: "/", maxSplits: 1).map(String.init)
            guard let did = parts.first.flatMap({ $0.removingPercentEncoding }).flatMap(UUID.init(uuidString:)),
                  parts.count > 1 else { return .error(400, "Bad delegation id or action") }
            return reply(await delegationCommand(did, parts[1], doc))
        case ("POST", "/instruction-presets"):
            guard let list = doc["presets"] as? [[String: Any]] else { return .error(400, "presets required") }
            await MainActor.run { SessionStores.shared?.setInstructionPresets(list) }
            return ControlResponse(200, ["ok": true])
        case ("GET", "/grid-layout"):
            // A server has no window, so no grid (macOS without a window).
            // @port ACAppDelegate.automationGridLayout() h=134aaf841c464fe5 @b10aa434
            return ControlResponse(200, ["cells": .array([])])
        case ("PUT", "/grid-layout"), ("POST", "/grid-layout"):
            return ControlResponse(400, ["ok": false])
        default:
            return nil
        }
    }

    /// A fat client's session asking one of ours (RemoteDelegationLink).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDelegationRequest h=790a0580bb56c68e @b10aa434
    func delegationRequest(_ body: [String: Any]) async -> [String: Any] {
        guard let to = body["to"] as? String, let text = body["text"] as? String,
              let ps = body["parent_session"] as? String, let pid = UUID(uuidString: ps)
        else { return ["error": "to, text and parent_session required"] }
        let party = RemoteParty(host: body["parent_host"] as? String ?? "a client",
                                label: body["parent_label"] as? String ?? "a session")
        return await { @MainActor in
            guard let engine = SessionStores.shared?.delegationEngine else { return ["error": "no delegation engine"] }
            do {
                let d = try await engine.requestFromRemote(parentSessionID: pid, parent: party, to: to, text: text)
                return ["ok": true, "id": d.id.uuidString]
            } catch {
                return ["error": "\(error)"]
            }
        }()
    }

    /// A remote party's verb on one of our delegations (files, answer, …).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDelegationCommand h=95b0622e72530bca @b10aa434
    func delegationCommand(_ id: UUID, _ action: String, _ body: [String: Any]) async -> [String: Any] {
        await { @MainActor in
            guard let engine = SessionStores.shared?.delegationEngine else { return ["error": "no delegation engine"] }
            do {
                if action == "files" {
                    guard let name = body["name"] as? String, let b64 = body["data"] as? String,
                          let data = Data(base64Encoded: b64) else { return ["error": "name and data required"] }
                    try await engine.receiveRemoteFile(delegationID: id, name: name, data: data,
                                                       append: body["append"] as? Bool ?? false,
                                                       extract: body["extract"] as? Bool ?? false)
                    return ["ok": true]
                }
                return try await engine.remoteCommand(delegationID: id, action: action, body: body)
            } catch {
                return ["error": "\(error)"]
            }
        }()
    }

    /// A piece of a file a delegation's session produced, for the far side.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDelegationFile h=5f58d3ce687279bf @b10aa434
    func delegationFile(_ id: UUID, _ path: String, _ offset: Int64, _ length: Int) async -> [String: Any] {
        await { @MainActor in
            guard let engine = SessionStores.shared?.delegationEngine else { return ["error": "no delegation engine"] }
            do {
                return try await engine.readRemoteFile(delegationID: id, path: path, offset: offset, length: length)
            } catch {
                return ["error": "\(error)"]
            }
        }()
    }
}

/// Rooms on the daemon (macOS: ACAppDelegate's room* members): the room
/// store and the sessions in them, this server's and attached machines'.
/// No Switchboard.
extension LinuxSessionHost {
    // partial: no Switchboard for a room on Linux yet
    // @port ACAppDelegate.roomCommand(_: UUID?, _: String, _: [String:Any]) h=980cca82c30fb700 @b10aa434
    func roomCommand(_ id: UUID?, _ action: String, _ body: [String: Any]) -> [String: Any] {
        func uuid(_ k: String) -> UUID? { (body[k] as? String).flatMap(UUID.init(uuidString:)) }
        let rooms = agentRoomStore
        switch (id, action) {
        case (nil, "create"):
            let ids = ((body["sessions"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
            return ["ok": true, "id": roomCreate(name: (body["name"] as? String) ?? "", sessions: ids).id.uuidString]
        case (nil, "move"):
            guard let sid = uuid("session") else { return ["error": "session required"] }
            roomMove(sid, to: uuid("room"))
            return ["ok": true]
        case (nil, "group"):
            guard let a = uuid("dragged"), let b = uuid("onto"), let rid = roomGroup(dragged: a, onto: b)
            else { return ["error": "those sessions can't share a room"] }
            return ["ok": true, "id": rid.uuidString]
        case (let rid?, _) where rooms.room(rid) == nil:
            return ["error": "unknown room"]
        case (let rid?, "rename"):
            rooms.rename(rid, to: (body["name"] as? String) ?? "")
            return ["ok": true]
        case (let rid?, "color"):
            guard let hex = body["hex"] as? String else { return ["error": "hex required"] }
            rooms.setColor(rid, hex)
            return ["ok": true]
        case (let rid?, "layout"):
            rooms.setLayout(rid, (body["layout"] as? String).flatMap(RoomLayout.init)?.string)
            return ["ok": true]
        case (let rid?, "delete"):
            roomDelete(rid)
            return ["ok": true]
        case (let rid?, "ungroup"):
            roomUngroup(rid)
            return ["ok": true]
        case (let rid?, "archive"):
            roomArchive(rid)
            return ["ok": true]
        case (let rid?, "unarchive"):
            roomUnarchive(rid)
            return ["ok": true]
        case (_?, "switchboard"):
            return ["error": "This server can't run a room's Switchboard yet."]
        default:
            return ["error": "unknown room action"]
        }
    }

    // @port ACAppDelegate.roomCreate(name: String, sessions: [UUID]) h=df5dc1bb0ecbc31d @b10aa434
    func roomCreate(name: String, sessions: [UUID] = []) -> AgentRoom {
        let r = agentRoomStore.create(name: name)
        for id in sessions { roomMove(id, to: r.id) }
        return r
    }

    /// Into a room, or out of any (nil). A Switchboard never moves. An
    /// attached machine's session too: its room is kept here, not on the
    /// machine (LinuxMachines.sessionRooms).
    // @port ACAppDelegate.roomMove(_: UUID, to: UUID?) h=cbdf2c070e68527c @b10aa434
    func roomMove(_ sid: UUID, to room: UUID?) {
        guard let s = sessionRecord(sid), !s.isSwitchboard,
              room == nil || agentRoomStore.room(room) != nil else { return }
        setRoom(sid, room)
    }

    /// One session dropped on another: into the other's room, or a new room
    /// (named after it) holding both.
    // @port ACAppDelegate.roomGroup(dragged: UUID, onto: UUID) h=27733cfa54b5cfee @b10aa434
    func roomGroup(dragged: UUID, onto: UUID) -> UUID? {
        guard let target = sessionRecord(onto), let moved = sessionRecord(dragged),
              !target.isSwitchboard, !moved.isSwitchboard, dragged != onto else { return nil }
        if let rid = target.roomID, agentRoomStore.room(rid) != nil {
            roomMove(dragged, to: rid)
            return rid
        }
        let base = target.nickname.map { "@" + $0 } ?? target.title
        let name = base.count > 32 ? String(base.prefix(31)) + "…" : base
        return roomCreate(name: name, sessions: [onto, dragged]).id
    }

    /// The room goes; its sessions stay, its Switchboard is archived.
    // @port ACAppDelegate.roomUngroup(_: UUID) h=402cf5259b8dff07 @b10aa434
    func roomUngroup(_ id: UUID) {
        for s in allSessionRecords where s.roomID == id {
            if s.isSwitchboard { SessionStores.shared?.engine?.archive(s.id) }
            setRoom(s.id, nil)
        }
        agentRoomStore.remove(id)
    }

    /// Put the room away with every session in it.
    // @port ACAppDelegate.roomArchive(_: UUID) h=ec026fb0e975fa0c @b10aa434
    func roomArchive(_ id: UUID) {
        for s in allSessionRecords where s.roomID == id && !s.isDeleted && !s.isArchived {
            sessionAction(s.id, "archive")
        }
        agentRoomStore.setArchived(id, true)
    }

    /// Bring an archived room back, with its sessions.
    // @port ACAppDelegate.roomUnarchive(_: UUID) h=46e2d33c0aa70cc0 @b10aa434
    func roomUnarchive(_ id: UUID) {
        for s in allSessionRecords where s.roomID == id && s.isArchived && !s.isDeleted {
            sessionAction(s.id, "unarchive")
        }
        agentRoomStore.setArchived(id, false)
    }

    /// Delete the room and every session in it.
    // @port ACAppDelegate.roomDelete(_: UUID) h=d8eb693198e25857 @b10aa434
    func roomDelete(_ id: UUID) {
        for s in allSessionRecords where s.roomID == id && !s.isDeleted {
            sessionAction(s.id, "delete")
            if LinuxMachines.shared?.machine(forSession: s.id) != nil { setRoom(s.id, nil) }
        }
        agentRoomStore.remove(id)
    }

    /// A session's room, wherever the session lives.
    // @port ACAppDelegate.setRoom(_: UUID, _: UUID?) h=ab9fdf6cf4f2c477 @d2db8346
    func setRoom(_ sid: UUID, _ room: UUID?) {
        if let machines = LinuxMachines.shared, let m = machines.machine(forSession: sid) {
            machines.setSessionRoom(sid, room)
            m.sessionStore.mutate(sid) { $0.roomID = room }   // at once; the next poll agrees
            return
        }
        agentSessionStore.mutate(sid) { $0.roomID = room }
    }

    /// archive / unarchive / delete, on this server's engine or the machine's.
    // @port ACAppDelegate.sessionAction(_: UUID, _: String) h=d51c6211e992559f @d2db8346
    func sessionAction(_ sid: UUID, _ action: String) {
        if let m = LinuxMachines.shared?.machine(forSession: sid) { m.hostSessionCommand(sid, action, [:]); return }
        let engine = SessionStores.shared?.engine
        switch action {
        case "archive": engine?.archive(sid)
        case "unarchive": engine?.unarchive(sid)
        case "delete": engine?.delete(sid)
        default: break
        }
    }
}
