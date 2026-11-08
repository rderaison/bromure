import Foundation

/// `vm run` (POST /vms) as macOS runs it: a workspace named or minted on the
/// fly, `-v` mounts as its shared folders, `--rm` workspaces deleted when
/// they stop; and the workspaces' shared folders as virtiofs shares.
extension Daemon {
    /// `POST /vms`: boot the workspace `profile` names (id, short id or
    /// name), or one minted from the template with `name`, `tool`, `auth`,
    /// `apiKey`, `memoryGB`; `mounts` (host paths) join its shared folders,
    /// up to the image's 8 slots; `rm` deletes it when it stops. The VM
    /// knobs (`machine`, `cpus`, `memoryGB`, `homeGB`) size a new one. 201
    /// `{id, shortId, name, tool, detached}`; a workspace id no workspace
    /// has is a 404 (deleted).
    // partial: no local-model download check (no MLX engine on Linux); always detached (a server has no pane)
    // @port ACAppDelegate.automationCreateVM(spec: [String:Any]) h=72b568a25237ce61 @2134fc7a
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/vms"): h=7a7b62405e4c0dbe @f127f8ab
    func createVMRoute(_ body: JSONValue) async -> ControlResponse {
        let saved: Profile, existing: VMRecord?, minted: Bool
        switch vmRunWorkspace(body) {
        case .failure(let refusal): return refusal.response
        case .success(let w): (saved, existing, minted) = w
        }
        let store = profileStore

        // 4. Boot: a new workspace's VM, or the existing one's (a running one
        //    is already detached: nothing to do).
        let id = saved.id.uuidString.lowercased()
        var r: ControlResponse
        if let rec = existing {
            r = live[rec.id] != nil ? ControlResponse(200, ["status": "running"]) : await start(rec)
        } else {
            var vm: [String: JSONValue] = ["name": .string(saved.name)]
            for k in ["machine", "cpus", "memoryGB", "homeGB"] { vm[k] = body[k] }
            r = await createVM(.object(vm), id: id)
            // A new workspace whose VM didn't come about goes with it.
            if r.status >= 300, minted, body["rm"] != .bool(true) { try? store.delete(saved) }
        }
        guard r.status < 300 else {
            // A `--rm` workspace that never booted is over.
            await dropAbandonedEphemeral(saved.id)
            return r
        }
        return ControlResponse(201, ["id": .string(id), "shortId": .string(String(id.prefix(8))),
                                     "name": .string(saved.name), "tool": .string(saved.tool.rawValue),
                                     "detached": true])
    }

    /// POST /vms's refusal before anything boots.
    struct VMRunRefusal: Error { let response: ControlResponse }

    /// POST /vms's workspace, saved (steps 1-3 of automationCreateVM): the
    /// one `profile` names, or one minted; its mounts added; a `--rm` one
    /// marked this daemon's. Its VM record when it has one already, and
    /// whether it was minted here.
    // @port-skip linux-only: automationCreateVM's steps before the boot (see createVMRoute), testable without booting
    func vmRunWorkspace(_ body: JSONValue) -> Result<(Profile, VMRecord?, Bool), VMRunRefusal> {
        let store = profileStore
        let ref = body["profile"]?.stringValue
        // 1. Resolve an existing workspace, or mint one on the fly.
        var profile: Profile
        var existing: VMRecord?
        var minted = false
        if let ref, let (p, rec) = workspace(ref) {
            profile = p
            existing = rec
        } else if let ref, let p = Self.workspace(ref) {
            profile = p                    // a workspace whose VM record is gone: a new VM for it
        } else if let refusal = Self.unknownWorkspaceRefusal(ref) {
            return .failure(VMRunRefusal(response: refusal))
        } else {
            let fallback = "cli-" + String(UUID().uuidString.prefix(8)).lowercased()
            let name = body["name"]?.stringValue ?? ref ?? fallback
            // `find` matches id, short id and name: a name equal to any of
            // them would make lookups ambiguous.
            if registry.records.contains(where: { $0.name == name || $0.id == name || $0.shortId == name }) {
                return .failure(VMRunRefusal(response: .error(409, "'\(name)' is already a VM's name or id")))
            }
            let tool = body["tool"]?.stringValue.flatMap { Profile.Tool(rawValue: $0) }
            let auth = body["auth"]?.stringValue.flatMap { Profile.AuthMode(rawValue: $0) }
            var p = store.newProfileFromTemplate(name: name, tool: tool, authMode: auth)
            if let key = body["apiKey"]?.stringValue, !key.isEmpty { p.apiKey = key }
            if let mem = body["memoryGB"]?.numberValue, mem > 0, mem == mem.rounded() { p.memoryGB = Int(mem) }
            profile = p
            minted = true
        }

        // 2. `-v` mounts (host paths → ~/<basename> in the guest), capped at
        //    the base image's 8 fstab slots.
        if case .array(let mounts) = body["mounts"] ?? .null, !mounts.isEmpty {
            var paths = profile.folderPaths
            for m in mounts.compactMap(\.stringValue) {
                let host = (m as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: host) else {
                    FileHandle.standardError.write(Data("[vm run] mount not found, skipping: \(host)\n".utf8))
                    continue
                }
                if !paths.contains(host) { paths.append(host) }
            }
            profile.folderPaths = Array(paths.prefix(8))
        }

        // 3. Persist.
        let saved: Profile
        do { saved = try store.save(profile) } catch {
            FileHandle.standardError.write(Data("[vm run] couldn't save profile: \(error)\n".utf8))
            return .failure(VMRunRefusal(response: .error(500, "Failed to create VM: couldn't save its workspace: \(error)")))
        }
        if body["rm"] == .bool(true) {
            // Another live process's --rm workspace isn't ours to boot.
            guard store.claimEphemeral(saved) else {
                return .failure(VMRunRefusal(response: .error(500, "Failed to create VM: '\(saved.name)' belongs to another Bromure process")))
            }
        }
        return .success((saved, existing, minted))
    }

    /// A `profile` that is a workspace id no workspace has: deleted, not a
    /// name to mint a workspace under. The /vms route answers 404.
    // @port ACAppDelegate.static unknownWorkspaceRefusal(_: Any?) h=78a4481151ddef9d @2134fc7a
    static func unknownWorkspaceRefusal(_ ref: String?) -> ControlResponse? {
        guard let ref, UUID(uuidString: ref) != nil else { return nil }
        return .error(404, "No workspace with id \(ref) — it was deleted.", ["notFound": .bool(true)])
    }

    /// `p` is a `vm run --rm` workspace this daemon may delete: its on-disk
    /// mark is ours, or its owner is gone, never a live other process's.
    // partial: the mark alone (macOS also keeps an in-memory one for a marker it couldn't write)
    // @port ACAppDelegate.takeEphemeral(_: Profile) h=b17be2c5a39e789b @2134fc7a
    nonisolated static func takeEphemeral(_ p: Profile, store: ProfileStore) -> Bool {
        store.isEphemeral(p) && store.mayTakeEphemeral(p)
    }

    /// A `--rm` workspace whose VM stopped, or never booted, goes: its
    /// profile, VM record, images and saved state (deleteWorkspace). Not
    /// while it runs, starts or reboots (a reboot boots it again).
    // @port ACAppDelegate.dropAbandonedEphemeral(_: Profile.ID) h=c41ef1fe55c485af @2134fc7a
    func dropAbandonedEphemeral(_ pid: Profile.ID) async {
        let key = pid.uuidString.lowercased()
        let store = profileStore
        guard live[key] == nil, !starting.contains(key), !rebooting.contains(key),
              let p = store.loadAll().first(where: { $0.id == pid }), Self.takeEphemeral(p, store: store) else { return }
        let r = await deleteWorkspace(key)
        if r["ok"] as? Bool != true {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(p.name)' (--rm): not deleted: \(r["error"] ?? "")\n".utf8))
        }
    }

    /// At start: delete the `--rm` workspaces whose owning daemon is gone
    /// and whose VM isn't running (it quit uncleanly, or crashed). Another
    /// live process's are never touched; a running one's stop deletes it.
    // partial: at start only (a daemon's stop leaves its VMs running under the fd store; each one's stop deletes it)
    // @port ACAppDelegate.sweepStoppedEphemeral(atLaunch: Bool) h=a03cb51c4cb044f4 @2134fc7a
    func sweepStoppedEphemeral() async {
        let store = profileStore
        for p in store.loadAll() where store.ephemeralSweepable(p, mine: false) {
            let key = p.id.uuidString.lowercased()
            guard live[key] == nil, !starting.contains(key) else { continue }
            _ = await deleteWorkspace(key)
        }
    }

    /// The host folders `rec`'s VM shares, in their share-<N> slots: a
    /// managed machine's own, else its workspace's shared folders
    /// (SessionDisk.sharedFolders: up to 8, as macOS attaches them).
    // @port-skip linux-only: the folder shares of UbuntuSandboxVM's configuration, from the VM record's workspace
    func shareFolders(_ rec: VMRecord) -> [String] {
        if let folders = rec.folders { return Array(folders.prefix(8)) }
        guard !rec.managed, rec.registration != true, rec.kube == nil, let p = existingProfile(for: rec) else { return [] }
        return SessionDisk.sharedFolders(p.folderPaths).map(\.url.path)
    }

    /// The workspace's shares.txt in its meta share ("<slot> <basename>"
    /// per share), which agentd turns into ~/<basename> links, as macOS's
    /// session disk writes it. Managed machines' folders are theirs alone.
    // @port-skip linux-only: the shares.txt step of SessionDisk's meta staging, into the Linux meta share
    func writeSharesFile(_ rec: VMRecord, meta: String) throws {
        guard rec.folders == nil, !rec.managed, rec.registration != true, rec.kube == nil,
              let p = existingProfile(for: rec) else { return }
        let lines = SessionDisk.sharedFolders(p.folderPaths).enumerated().map { "\($0.offset + 1) \($0.element.mountName)" }
        try (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
            .write(toFile: meta + "/shares.txt", atomically: true, encoding: .utf8)
    }
}
