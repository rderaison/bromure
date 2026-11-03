import Foundation
import SandboxEngine

/// Workspaces as Profiles. macOS: a workspace is a Profile that owns its VM.
/// Here the daemon's VM records are the workspaces, and each has the Profile
/// with its id in ProfileStore (`<state>/profiles/<ID>/`): the shared
/// session, task and policy code reads that Profile. A VM made before
/// profiles gets one from the preferences template, named like the VM.
extension Daemon {
    // @port-skip linux-only: the daemon's ProfileStore (ProfileStore.defaultRootDir is the state dir's)
    var profileStore: ProfileStore { ProfileStore() }

    /// The Profile of the workspace VM `rec`, made and saved if it has none.
    // @port-skip linux-only: Linux workspaces are VM records with a Profile each
    func profile(for rec: VMRecord) -> Profile? {
        guard let uuid = UUID(uuidString: rec.id) else { return nil }
        // A sign-in VM's Profile is the daemon's alone, never saved.
        if rec.registration == true { return registrationProfiles[rec.id] }
        // A cluster's machine has no workspace Profile.
        if rec.kube != nil { return nil }
        let store = profileStore
        if let p = store.loadAll().first(where: { $0.id == uuid }) { return p }
        var p = store.newProfileFromTemplate(name: rec.name)
        p.id = uuid
        p.createdAt = rec.createdAt
        return try? store.save(p)
    }

    /// The Profile and VM record for `key`: a profile id (any case), its
    /// short id, or its name.
    // @port-skip linux-only: a Linux workspace is a Profile and its VM record
    func workspace(_ key: String) -> (Profile, VMRecord)? {
        guard let rec = registry.find(key) ?? registry.records.first(where: {
            $0.id.caseInsensitiveCompare(key) == .orderedSame || $0.name.lowercased() == key.lowercased()
        }), !rec.managed, let p = profile(for: rec) else { return nil }
        return (p, rec)
    }

    /// GET /profiles: every workspace, as macOS lists them (ACAutomationProfileInfo).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListProfiles h=328eda9e2a033d62 @7dd92fdf
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/profiles"): h=5741f93279fa34e4 @7dd92fdf
    func listProfiles() -> ControlResponse {
        let rows: [JSONValue] = registry.records.compactMap { rec in
            guard !rec.managed, let p = profile(for: rec) else { return nil }
            let state: String
            switch rec.state {
            case .running: state = "running"
            case .starting: state = "booting"
            case .suspended: state = "suspended"
            case .stopped: state = "off"
            }
            return .object([
                "id": .string(p.id.uuidString), "shortId": .string(rec.shortId), "name": .string(p.name),
                "color": .string(p.color.rawValue), "tool": .string(p.tool.rawValue),
                "authMode": .string(p.authMode.rawValue),
                "mcpServerCount": .number(Double(p.mcpServers.count)), "state": .string(state),
            ])
        }
        return ControlResponse(200, ["profiles": .array(rows)])
    }

    /// `POST /profiles`: a workspace from the template, overlaid with the
    /// document (the shared save: ProfileEditHost.automationUpsertProfile),
    /// and its VM registered (stopped) with the same id. 201 with its id.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/profiles"): h=ea29b136cb0d8add @7dd92fdf
    func createProfile(_ body: JSONValue) async -> ControlResponse {
        guard case .object = body, let doc = body.foundationObject as? [String: Any] else {
            return .error(400, "Expected a JSON object")
        }
        let name = (doc["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return .error(400, "A workspace name is required.") }
        if registry.records.contains(where: { $0.name == name }) {
            return .error(409, "A workspace is already named '\(name)'")
        }
        let r: [String: Any] = await MainActor.run {
            LinuxSessionHost.shared?.automationUpsertProfile(idOrName: nil, doc: doc) ?? ["ok": false, "error": "no host"]
        }
        guard r["ok"] as? Bool == true, let id = r["id"] as? String else {
            return ControlResponse(400, JSONValue(foundation: r) ?? .object([:]))
        }
        let vm = await createVM(.object(["name": .string(name)]), id: id, boot: false)
        guard vm.status == 201 else {
            if let p = Daemon.workspace(id) { try? FileManager.default.removeItem(at: profileStore.profileDirectory(for: p)) }
            return vm
        }
        var out = r
        out["name"] = name
        out["shortId"] = String(id.lowercased().prefix(8))
        return ControlResponse(201, JSONValue(foundation: out) ?? .object([:]))
    }

    /// `PUT|PATCH /profiles/<id>`: the shared save (a full document replaces,
    /// a partial one overlays; blank secrets keep the stored ones). 404 for
    /// a missing workspace, 400 for a bad document.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleProfileRoute's PUT (the body is shared)
    func updateProfile(_ key: String, _ body: JSONValue) async -> ControlResponse {
        guard let doc = body.foundationObject as? [String: Any] else { return .error(400, "Expected a JSON object") }
        let r: [String: Any] = await MainActor.run {
            LinuxSessionHost.shared?.automationUpsertProfile(idOrName: key, doc: doc) ?? ["ok": false, "error": "no host"]
        }
        let ok = r["ok"] as? Bool == true
        let status = ok ? 200 : ((r["error"] as? String)?.contains("not found") == true ? 404 : 400)
        return ControlResponse(status, JSONValue(foundation: r) ?? .object([:]))
    }

    /// POST /sessions/<workspace>/tab {"action": new|select|close, "index"}:
    /// a command file in the workspace's outbox, which agentd acts on (as
    /// macOS does). 400 for an unknown or stopped workspace, or a bad action.
    // @port ACAppDelegate.automationTabCommand(profileNameOrID: String, action: String, index: Int) h=c2e37c629f0f1cea @7dd92fdf
    func tabCommand(_ key: String, _ body: JSONValue) -> ControlResponse {
        let action = body["action"]?.stringValue ?? "new"
        let index = body["index"]?.numberValue.map { Int($0) } ?? body["index"]?.stringValue.flatMap { Int($0) } ?? 0
        let line: String
        switch action {
        case "new": line = "new-tab"
        case "select": line = "select-tab \(index)"
        case "close": line = "close-tab \(index)"
        default: return ControlResponse(400, ["ok": false, "error": "unknown session or bad action"])
        }
        guard let rec = registry.find(key) ?? registry.records.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }),
              live[rec.id] != nil else {
            return ControlResponse(400, ["ok": false, "error": "unknown session or bad action"])
        }
        let file = vmDir(rec.id) + "/outbox/cmd-\(UUID().uuidString).txt"
        guard (try? (line + "\n").write(toFile: file, atomically: true, encoding: .utf8)) != nil else {
            return ControlResponse(500, ["ok": false, "error": "couldn't write to the workspace's outbox"])
        }
        return ControlResponse(200, ["ok": true])
    }
}
