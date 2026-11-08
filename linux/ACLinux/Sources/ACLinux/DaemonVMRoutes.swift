import Foundation

extension Daemon {
    /// `POST /vms/<id>/file {"op": {...}, "timeout"}`: a guest file operation
    /// (read, write, list…) through agentd, as the chat view and the CLI
    /// use it. 409 when the VM isn't running or the guest refused.
    // @port ACAppDelegate.automationGuestFileOp(idOrName: String, op: [String:Any], timeout: Int) h=9684560563026b32 @9ece43f6
    func guestFileRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        guard live[rec.id] != nil, let pid = UUID(uuidString: rec.id) else {
            return ControlResponse(409, ["error": .string("VM not running: \(rec.name)")])
        }
        let op = body["op"]?.foundationObject as? [String: Any] ?? [:]
        let timeout = body["timeout"]?.numberValue.map { Int($0) } ?? 30
        do {
            let r = try await guestFileOp(profileID: pid, op: op, timeout: timeout)
            return ControlResponse(200, JSONValue(foundation: r) ?? .object([:]))
        } catch {
            return ControlResponse(409, ["error": .string(String(describing: error))])
        }
    }

    /// `POST /vms/<id>/reboot {"mode": soft|hard}`: the VM stopped (a clean
    /// shutdown, or at once) and booted fresh, as its workspace is saved now
    /// (an edit that needs a reboot takes effect), never resumed.
    // @port ACAppDelegate.rebootMachine(_: Profile.ID, force: Bool, remoteInitiated: Bool) h=ffe69fc7d5a5ac71 @9ece43f6
    func rebootRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        let hard = body["mode"]?.stringValue == "hard"
        guard live[rec.id] != nil else {
            return ControlResponse(409, ["ok": false, "error": .string("VM not running: \(rec.name)")])
        }
        let name = existingProfile(for: rec)?.name ?? rec.name
        let stopped = await deleteVM(rec, action: hard ? "kill" : "shutdown")
        guard stopped.status < 300 else { return ControlResponse(409, ["ok": false, "error": stopped.body["error"] ?? "couldn't stop it"]) }
        // The old session out of the way first: the next boot shares its
        // directories.
        for _ in 0..<200 where live[rec.id] != nil || stopping[rec.id] != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Cold, never from a saved state.
        try? FileManager.default.removeItem(atPath: snapshotDir(rec.id))
        guard var now = registry.find(rec.id) else { return ControlResponse(409, ["ok": false, "error": "the VM is gone"]) }
        if now.state == .suspended { now.state = .stopped; try? registry.upsert(now) }
        let started = await start(now)
        let up = started.status < 300
        var reply: [String: JSONValue] = ["ok": .bool(up), "workspace": .string(name), "mode": .string(hard ? "hard" : "soft")]
        if !up { reply["error"] = started.body["error"] ?? "the boot failed" }
        return ControlResponse(up ? 200 : 409, .object(reply))
    }

    /// `POST /vms/<id>/model {"modelID"}`: the workspace's active local
    /// model switched (saved, and the engine re-pointed); its agents keep
    /// their environment and pick the new model up on their next request.
    // partial: no routing step (Local/Hybrid rerouting isn't on Linux yet)
    // @port ACAppDelegate.automationSetModel(idOrName: String, modelID: String) h=2ce6aa845ea9130e @9ece43f6
    func setModelRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        let modelID = body["modelID"]?.stringValue ?? ""
        guard live[rec.id] != nil, var profile = existingProfile(for: rec) else {
            return ControlResponse(409, ["ok": false, "error": .string("VM not found: \(rec.name)")])
        }
        let resolved = await MainActor.run { CatalogStore.shared.resolve(modelID).map { (id: $0.id, repo: $0.repo) } }
        // On an external engine the id namespace is that server's, not the
        // catalog's: any id, and the engine rejects unknowns.
        if resolved == nil, profile.localEngineBaseURL == nil {
            return ControlResponse(409, ["ok": false, "error": .string("Unknown model '\(modelID)'. Try `model catalog`.")])
        }
        profile.activeModelID = resolved?.id ?? modelID
        do { try profileStore.update(profile) } catch {
            return ControlResponse(409, ["ok": false, "error": .string("couldn't save: \(error.localizedDescription)")])
        }
        startLocalEngineIfNeeded(for: await stagedProfile(profile))
        return ControlResponse(200, ["ok": true, "model": .string(resolved?.id ?? modelID), "repo": .string(resolved?.repo ?? modelID)])
    }
}
