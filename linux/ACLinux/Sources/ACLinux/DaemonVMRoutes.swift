import Foundation

extension Daemon {
    /// `POST /vms/<id>/file {"op": {...}, "timeout"}`: a guest file operation
    /// (read, write, list…) through agentd, as the chat view and the CLI
    /// use it. 409 when the VM isn't running or the guest refused.
    // @port ACAppDelegate.automationGuestFileOp(idOrName: String, op: [String:Any], timeout: Int) h=9684560563026b32 @9ece43f6
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onGuestFileOp h=d7c0b2d40da72235 @d3ebbda2
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
    // @port ACAppDelegate.automationRebootVM(idOrName: String, mode: String) h=88def92c5001a3b7 @4237c02e
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onRebootVM h=ce9c2e1d5f613661 @4237c02e
    func rebootRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        let hard = body["mode"]?.stringValue == "hard"
        guard live[rec.id] != nil else {
            return ControlResponse(409, ["ok": false, "error": .string("VM not running: \(rec.name)")])
        }
        let name = existingProfile(for: rec)?.name ?? rec.name
        // A `--rm` workspace survives this stop: it boots again.
        rebooting.insert(rec.id)
        defer { rebooting.remove(rec.id); stopsDuringReboot.remove(rec.id) }
        let stopped = await deleteVM(rec, action: hard ? "kill" : "shutdown", partOfReboot: true)
        guard stopped.status < 300 else { return ControlResponse(409, ["ok": false, "error": stopped.body["error"] ?? "couldn't stop it"]) }
        // The old session out of the way first: the next boot shares its
        // directories.
        for _ in 0..<200 where live[rec.id] != nil || stopping[rec.id] != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Cold, never from a saved state.
        try? FileManager.default.removeItem(atPath: snapshotDir(rec.id))
        if await stoppedDuringReboot(rec.id) { return ControlResponse(409, ["ok": false, "error": "stopped during the reboot"]) }
        guard var now = registry.find(rec.id) else { return ControlResponse(409, ["ok": false, "error": "the VM is gone"]) }
        if now.state == .suspended { now.state = .stopped; try? registry.upsert(now) }
        let started = await start(now, partOfReboot: true)
        if await stoppedDuringReboot(rec.id) { return ControlResponse(409, ["ok": false, "error": "stopped during the reboot"]) }
        rebooting.remove(rec.id)
        let up = started.status < 300
        // A `--rm` workspace whose reboot didn't boot is over.
        if !up, let pid = UUID(uuidString: rec.id) { await dropAbandonedEphemeral(pid) }
        var reply: [String: JSONValue] = ["ok": .bool(up), "workspace": .string(name), "mode": .string(hard ? "hard" : "soft")]
        if !up { reply["error"] = started.body["error"] ?? "the boot failed" }
        return ControlResponse(up ? 200 : 409, .object(reply))
    }

    /// `POST /vms/<id>/model {"modelID"}`: the workspace's active local
    /// model switched (saved, and the engine re-pointed); its agents keep
    /// their environment and pick the new model up on their next request.
    // @port ACAppDelegate.automationSetModel(idOrName: String, modelID: String) h=2ce6aa845ea9130e @9ece43f6
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSetModel h=61d0b9117a46b056 @d3ebbda2
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
        let active = resolved?.id ?? modelID
        do {
            if let saved = try ProfileWrites.edit(profile.id, store: profileStore, { $0.activeModelID = active; return true }) {
                profile = saved
            } else { profile.activeModelID = active }
        } catch {
            return ControlResponse(409, ["ok": false, "error": .string("couldn't save: \(error.localizedDescription)")])
        }
        let staged = await stagedProfile(profile)
        applyRouting(staged: staged)
        startLocalEngineIfNeeded(for: staged)
        return ControlResponse(200, ["ok": true, "model": .string(resolved?.id ?? modelID), "repo": .string(resolved?.repo ?? modelID)])
    }
}

extension Daemon {
    /// `POST /vms/<id>/docker {"action", ...}`: a Docker dashboard verb for
    /// the workspace's guest, validated host-side (DockerGuestVerbs) and
    /// sent as the outbox command agentd runs; "watch" toggles the guest's
    /// expensive dashboard polling. 409 when the VM isn't running or the
    /// action is refused.
    // @port ACAppDelegate.automationDockerCommand(idOrName: String, doc: [String:Any]) h=816fd9b4c7ecc817 @843e00a9
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDockerCommand h=058ab1f6e3e65ab6 @d3ebbda2
    // partial: action "attach" (DockerGuestVerbs.automationAction)
    // @port ACAppDelegate.requestDockerAttach(containerID: String, shell: String, in: SessionPane) h=9600d7d0d3c53e08 @d3ebbda2
    // partial: DockerGuestVerbs.sanitizedID, via automationAction
    // @port ACAppDelegate.sanitizedDockerID(_: String) h=2462bd4ea168de60 @d3ebbda2
    // partial: action "start"
    // @port ACAppDelegate.requestDockerStart(containerID: String, in: SessionPane) h=6d03b818b15ed3f5 @d3ebbda2
    // partial: action "stop"
    // @port ACAppDelegate.requestDockerStop(containerID: String, in: SessionPane) h=d0aeab65f2b49a3e @d3ebbda2
    // partial: action "remove"
    // @port ACAppDelegate.requestDockerRemove(containerID: String, in: SessionPane) h=5e7629def3be973b @d3ebbda2
    // partial: action "logs"
    // @port ACAppDelegate.requestDockerLogs(containerID: String, in: SessionPane) h=142e743ad02b7834 @d3ebbda2
    // partial: DockerGuestVerbs.sanitizedVolumeName, via automationAction
    // @port ACAppDelegate.static sanitizedVolumeName(_: String) h=2f7280c44e5c0c49 @d3ebbda2
    // partial: action "volume-create"
    // @port ACAppDelegate.requestDockerVolumeCreate(name: String, in: SessionPane) h=ac7ea8df7e607faf @d3ebbda2
    // partial: action "volume-remove"
    // @port ACAppDelegate.requestDockerVolumeRemove(name: String, in: SessionPane) h=ec271346e2a333c7 @d3ebbda2
    // partial: action "binfmt"
    // @port ACAppDelegate.requestDockerBinfmtInstall(in: SessionPane) h=53517416dd248b4c @d3ebbda2
    // partial: action "binfmt-off"
    // @port ACAppDelegate.requestDockerBinfmtUninstall(in: SessionPane) h=899629809a95dbc0 @d3ebbda2
    // partial: action "run"
    // @port ACAppDelegate.requestDockerRun(spec: DockerRunSpec, in: SessionPane) h=6843cf42f3e8ca9e @d3ebbda2
    // partial: DockerGuestVerbs.runVerb, via automationAction
    // @port ACAppDelegate.static dockerRunVerb(spec: DockerRunSpec) h=0eb8c74126c94439 @d3ebbda2
    func dockerRoute(_ rec: VMRecord, _ body: JSONValue) -> ControlResponse {
        guard live[rec.id] != nil else {
            return ControlResponse(409, ["ok": false, "error": .string("VM not running: \(rec.name)")])
        }
        switch DockerGuestVerbs.automationAction((body.foundationObject as? [String: Any]) ?? [:]) {
        case .send(let verb):
            guard sendGuestCommand(verb, vmID: rec.id) else {
                return ControlResponse(500, ["ok": false, "error": "couldn't write to the workspace's outbox"])
            }
        case .watch(let on):
            setDockerWatch(on, vmID: rec.id)
        case .refused(let error):
            return ControlResponse(409, ["ok": false, "error": .string(error)])
        }
        return ControlResponse(200, ["ok": true])
    }

    /// A command line for agentd: a `cmd-<uuid>.txt` file in the outbox,
    /// written whole (agentd only ever sees a complete file).
    // @port ACAppDelegate.sendGuestCommand(_: String, profileID: Profile.ID) h=0d3070fd580c2d69 @843e00a9
    // @port ACAppDelegate.sendCommand(_: String, in: SessionPane) h=6a03429e6bde7500 @d3ebbda2
    @discardableResult
    func sendGuestCommand(_ command: String, vmID: String) -> Bool {
        let file = vmDir(vmID) + "/outbox/cmd-\(UUID().uuidString).txt"
        return (try? (command + "\n").write(toFile: file, atomically: true, encoding: .utf8)) != nil
    }

    /// The guest's Docker dashboard polling (CPU/mem, images) on or off:
    /// the `.docker-watch` marker in the outbox, created atomically.
    // @port ACAppDelegate.setDockerWatch(_: Bool, profileID: Profile.ID) h=3b7141c2fabe19b6 @843e00a9
    // @port ACAppDelegate.setDockerWatch(_: Bool, in: SessionPane) h=a4e2f1f4b8db5312 @d3ebbda2
    func setDockerWatch(_ on: Bool, vmID: String) {
        let marker = vmDir(vmID) + "/outbox/.docker-watch"
        if on {
            try? Data().write(to: URL(fileURLWithPath: marker), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: marker)
        }
    }
}

extension Daemon {
    /// `POST /vms/<id>/type {target, text}`: a chat message typed into one
    /// of the workspace's panes, guarded and confirmed next to the agent
    /// (PaneTypeGuard.runType through guest exec), in one request. Every
    /// reply carries "typeRoute", so a client tells this route from an
    /// older server's 404/405 (and types step by step there); "output" is
    /// the guard's, "unreachable" when the machine couldn't be asked.
    // @port ACAutomationServer.handleType(fd: Int32, profileID: String, bodyJSON: [String:Any], gzip: Bool) h=b3d460df248c6312 @30634ab2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onTypeIntoPane h=18aff5566a6bdbe8 @d3ebbda2
    func typeRoute(_ rec: VMRecord?, _ body: JSONValue, key: String? = nil) async -> ControlResponse {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        guard let text = doc["text"] as? String,
              let raw = doc["target"],
              JSONSerialization.isValidJSONObject([raw]),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
              let target = try? JSONDecoder().decode(PaneTarget.self, from: data) else {
            return ControlResponse(400, ["typeRoute": true, "error": "target and text required"])
        }
        var out: String?
        if let rec, live[rec.id] != nil, let id = UUID(uuidString: rec.id) {
            out = await PaneTypeGuard.runType(target: target, text: text) { cmd in
                try? await self.guestExec(profileID: id, command: cmd, timeout: 20)
            }
        } else if rec == nil, let id = key.flatMap(UUID.init(uuidString:)),
                  await MainActor.run(body: { LinuxMachines.shared?.attached[id] != nil }) {
            // An attached machine's pane, typed into over its link (guestExec
            // runs it there), as macOS's onTypeIntoPane does by id.
            out = await PaneTypeGuard.runType(target: target, text: text) { cmd in
                try? await self.guestExec(profileID: id, command: cmd, timeout: 20)
            }
        }
        var reply: [String: JSONValue] = ["typeRoute": true]
        if let out { reply["output"] = .string(out) } else { reply["unreachable"] = true }
        return ControlResponse(200, .object(reply))
    }
}
