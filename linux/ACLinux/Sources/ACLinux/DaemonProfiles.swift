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
        }), let p = profile(for: rec) else { return nil }
        return (p, rec)
    }

    /// GET /profiles: every workspace, as macOS lists them (ACAutomationProfileInfo).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListProfiles h=328eda9e2a033d62 @7dd92fdf
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/profiles"): h=5741f93279fa34e4 @7dd92fdf
    func listProfiles() -> ControlResponse {
        let rows: [JSONValue] = registry.records.compactMap { rec in
            guard let p = profile(for: rec) else { return nil }
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

    /// POST /profiles {document}: a new workspace from the preferences
    /// template with the document overlaid (ProfileDocument), its VM
    /// registered (stopped) with the same id. 201 with its id; 400 for a bad
    /// document or an OpenShell policy that wouldn't validate.
    // partial: no `generateSSH`, no folder shares
    // @port ACAppDelegate.automationUpsertProfile(idOrName: String?, doc: [String:Any]) h=391511fcb8407fd9 @7dd92fdf
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/profiles"): h=ea29b136cb0d8add @7dd92fdf
    func createProfile(_ body: JSONValue) async -> ControlResponse {
        guard case .object = body, var doc = body.foundationObject as? [String: Any] else {
            return .error(400, "Expected a JSON object")
        }
        for k in ["_secretsRedacted", "generateSSH", "_commentsIfStill"] { doc.removeValue(forKey: k) }
        let name = (doc["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return .error(400, "A workspace name is required.") }
        if registry.records.contains(where: { $0.name == name }) {
            return .error(409, "A workspace is already named '\(name)'")
        }
        let store = profileStore
        let minted = store.newProfileFromTemplate(name: name)
        var created: Profile
        switch ProfileDocument.merge(doc, over: minted) {
        case .success(let p): created = p
        case .failure(let e): return .error(400, e.message)
        }
        created.id = minted.id
        created.createdAt = minted.createdAt
        created.lastUsedAt = nil
        if created.usesOpenShellPolicy {
            do { _ = try OpenShellPolicy.parse(created.networkPolicy) } catch {
                return .error(400, "Invalid OpenShell policy: \(error)")
            }
            if let r = OpenShellGovernance.shared.check(policyYAML: created.networkPolicy,
                                                        providerRules: created.openShellProviderRules),
               !r.passed {
                return .error(400, "OpenShell policy is outside the organization boundary: \(r.summary)")
            }
        }
        do { created = try store.save(created) } catch { return .error(500, "Couldn't save the workspace: \(error)") }
        let vm = await createVM(.object(["name": .string(name)]), id: created.id.uuidString, boot: false)
        guard vm.status == 201 else {
            try? FileManager.default.removeItem(at: store.profileDirectory(for: created))
            return vm
        }
        return ControlResponse(201, ["ok": true, "id": .string(created.id.uuidString), "name": .string(name),
                                     "shortId": .string(String(created.id.uuidString.lowercased().prefix(8)))])
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
