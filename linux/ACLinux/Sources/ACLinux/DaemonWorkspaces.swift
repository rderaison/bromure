import Foundation

/// A fat client's view of one workspace (macOS: the automation server's
/// /profiles/<id> and /agent-sessions/folders, and the app delegate's
/// describe / export / folder listing behind them).
extension Daemon {
    /// `GET /profiles/<id>` (`?full=1`: the whole Profile, secrets blanked;
    /// `?storage=1`: its disk sizes; else the compact describe), a workspace's
    /// firewall (`POST …/firewall`, `…/firewall-edit`), and `POST
    /// /agent-sessions/folders`; nil for any other path.
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) h=59e55ae73cdc6185 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/squelch"): h=7683b90b12a0dc9b @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p.hasPrefix("/profiles/"): h=da0189f989a394c5 @f127f8ab
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "GET": h=2480df5b415bae78 @f127f8ab
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "PUT", "PATCH": h=f633e99ddcbde1c8 @f127f8ab
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / case "DELETE": h=94bd44937ab2cb14 @f127f8ab
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) / default: h=a378a9dda33ea55e @f127f8ab
    // partial: "policy" sub-resource → shared ProfileSubRoutes.policyRevisionsRoute
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onProfilePolicyRevisions h=1d67c3b6786f6c3d @d3ebbda2
    // partial: resolves key, then listGuestFolders
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onAgentSessionFolders h=e9329a5c8e54c647 @d3ebbda2
    // partial: calls shared ProfileSubRoutes directly (the macOS one is only a forwarder)
    // @port ACAppDelegate.static policyRevisionsRoute(directory: URL, method: String, sub: [String]) h=e8b92416b6853e60 @d3ebbda2
    func workspaceRoute(_ method: String, _ fullPath: String, _ body: JSONValue) async -> ControlResponse? {
        let parts = fullPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0], query = parts.count > 1 ? parts[1] : ""
        switch (method, path) {
        case ("GET", "/squelch"):
            return ControlResponse(200, JSONValue(foundation: Self.squelchStats()) ?? ["workspaces": [:]])
        case ("POST", "/agent-sessions/folders"):
            guard let key = body["profile"]?.stringValue, !key.isEmpty else { return .error(400, "profile required") }
            guard let p = Self.workspace(key) else { return .error(404, "The machine's folders can't be read right now") }
            guard let folders = await listGuestFolders(p, path: body["path"]?.stringValue ?? "~") else {
                return .error(404, "The machine's folders can't be read right now")
            }
            return ControlResponse(200, ["folders": .array(folders.map { .string($0) })])
        case ("GET", let p) where p.hasPrefix("/profiles/") && !p.dropFirst("/profiles/".count).contains("/"):
            let raw = String(p.dropFirst("/profiles/".count))
            guard let prof = Self.workspace(raw.removingPercentEncoding ?? raw) else { return .error(404, "Profile not found") }
            if query.contains("storage=1") { return ControlResponse(200, storage(prof)) }
            let d: [String: Any]? = query.contains("full=1") || query.contains("full=true")
                ? Self.profileExport(prof) : describe(prof)
            guard let d, let v = JSONValue(foundation: d) else { return .error(404, "Profile not found") }
            return ControlResponse(200, v)
        case ("POST", let p) where p.hasPrefix("/profiles/") && p.hasSuffix("/firewall-edit"):
            let raw = String(p.dropFirst("/profiles/".count).dropLast("/firewall-edit".count))
            return firewallEditRoute(raw.removingPercentEncoding ?? raw, body)
        case ("POST", let p) where p.hasPrefix("/profiles/") && p.hasSuffix("/firewall"):
            let raw = String(p.dropFirst("/profiles/".count).dropLast("/firewall".count))
            return firewallRoute(raw.removingPercentEncoding ?? raw, body)
        case ("POST", let p) where p.hasPrefix("/profiles/") && p.hasSuffix("/squelch"):
            let raw = String(p.dropFirst("/profiles/".count).dropLast("/squelch".count))
            guard case .bool(let enabled)? = body["enabled"] else { return .error(400, "enabled required") }
            guard let prof = Self.workspace(raw.removingPercentEncoding ?? raw), setSquelch(prof.id, enabled) else {
                return ControlResponse(404, ["ok": false, "error": "unknown workspace"])
            }
            return ControlResponse(200, ["ok": true, "enabled": .bool(enabled)])
        case ("POST", let p) where p.hasPrefix("/profiles/") && p.hasSuffix("/compromised"):
            let raw = String(p.dropFirst("/profiles/".count).dropLast("/compromised".count))
            return await resolveCompromise(raw.removingPercentEncoding ?? raw, action: body["action"]?.stringValue ?? "")
        // Sub-resources: /profiles/{id}/policy/revisions…, /proposals…, the
        // Sandbox drawer's decisions.
        case (_, let p) where p.hasPrefix("/profiles/") && p.dropFirst("/profiles/".count).contains("/"):
            let segments = p.dropFirst("/profiles/".count).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            guard segments.count >= 2, let prof = Self.workspace(segments[0]) else { return .error(404, "Profile not found") }
            let sub = Array(segments.dropFirst())
            let r: (status: Int, body: [String: Any])
            switch sub[0] {
            case "policy":
                r = ProfileSubRoutes.policyRevisionsRoute(directory: profileStore.profileDirectory(for: prof), method: method, sub: sub)
            case "ssh-keys":
                return await sshKeysRoute(prof, method: method, sub: sub, body: body)
            case "proposals", "openshell-allow", "sandbox-path":
                r = await Self.advisorSubRoute(prof.id, method: method, sub: sub,
                                               body: body.foundationObject as? [String: Any] ?? [:])
            default:
                return .error(404, "Unknown profile resource")
            }
            return ControlResponse(r.status, JSONValue(foundation: r.body) ?? .object([:]))
        case ("DELETE", let p) where p.hasPrefix("/profiles/"):
            let raw = String(p.dropFirst("/profiles/".count))
            let r = await deleteWorkspace(raw.removingPercentEncoding ?? raw)
            return ControlResponse(r["ok"] as? Bool == true ? 200 : 409, JSONValue(foundation: r) ?? .object([:]))
        case ("PUT", let p) where p.hasPrefix("/profiles/"), ("PATCH", let p) where p.hasPrefix("/profiles/"):
            let raw = String(p.dropFirst("/profiles/".count))
            return await updateProfile(raw.removingPercentEncoding ?? raw, body)
        default:
            return nil
        }
    }

    /// Squelch on or off for a workspace (the sidebar's switch), saved and
    /// applied to its traffic at once. False for an unknown workspace or a
    /// failed save.
    // @port ACAppDelegate.setSquelch(_: Profile.ID, _: Bool) h=95dbcd51ff8ff787 @2134fc7a
    @discardableResult
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSetSquelch h=461b4c02c7a43b84 @d3ebbda2
    func setSquelch(_ id: Profile.ID, _ on: Bool) -> Bool {
        var changed = false
        do {
            let saved = try ProfileWrites.edit(id, store: profileStore) { p in
                guard p.squelch.enabled != on else { return false }
                p.squelch.enabled = on
                changed = true
                return true
            }
            guard saved != nil else { return false }
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: squelch: couldn't save profile: \(error)\n".utf8))
            return false
        }
        guard changed else { return true }
        Self.refreshSquelchSettings()
        return true
    }

    /// Delete a workspace: its profile, and its VM's record, images and
    /// saved state. Refused while its VM runs or its disks are in use.
    // @port ACAppDelegate.automationDeleteProfile(_: String) h=bfe7e40435bea98c @2134fc7a
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDeleteProfile h=965e61b752c9fc5b @d3ebbda2
    // partial: no confirm dialog (client side). Refuses while running, deletes the VM, profile and passphrases, kube workspaceDeleted
    // @port ACAppDelegate.deleteProfile(_: Profile) h=7412eb8304eea968 @d3ebbda2
    func deleteWorkspace(_ key: String) async -> [String: Any] {
        guard let p = Self.workspace(key) else { return ["ok": false, "error": "Workspace not found: \(key)"] }
        let vmKey = p.id.uuidString.lowercased()
        if live[vmKey] != nil || starting.contains(vmKey) {
            // Read by the CLI and by a fat client's "Delete workspace".
            return ["ok": false, "error": "“\(p.name)” is running — shut it down (or `vm kill` it), then delete it."]
        }
        if let rec = registry.find(vmKey) {
            let r = remove(rec)
            guard r.status == 200 else {
                return ["ok": false, "error": "Couldn't delete '\(p.name)': " + (r.body["error"]?.stringValue ?? "its VM is busy")]
            }
        }
        do {
            try profileStore.delete(p)
        } catch {
            return ["ok": false, "error": "Couldn't delete '\(p.name)': \(error.localizedDescription)"]
        }
        // Its imported keys' passphrases leave the vault with it.
        for key in p.importedSSHKeys where key.hasPassphrase && !key.filename.isEmpty {
            PassphraseKeychain.delete(profileID: p.id, filename: key.filename)
        }
        // As the sidebar's own delete does: its cluster access goes too.
        await MainActor.run { SessionStores.shared?.kubeEngine?.workspaceDeleted(p.id) }
        Self.refreshSquelchSettings()
        return ["ok": true, "name": p.name]
    }

    /// A workspace by id or name (macOS: profileByNameOrID).
    // partial: resolves any workspace, not only running ones
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onResolveProfileID h=186f6b4db7c29a4d @d3ebbda2
    // partial: no short-id prefix match
    // @port ACAppDelegate.profileByNameOrID(_: String) h=826632f9403037ab @d3ebbda2
    static func workspace(_ key: String) -> Profile? {
        let all = ProfileStore().loadAll()
        return all.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }
            ?? all.first { $0.name.lowercased() == key.lowercased() }
    }

    /// The compact summary a client's workspace list and CLI read.
    // partial: the MAC is the VM record's (macOS: MACBindings)
    // @port ACAppDelegate.automationProfileDescribe(_: String) h=f0e4c0339194b0f0 @b10aa434
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDescribeProfile h=4d057509dc3dc017 @d3ebbda2
    func describe(_ p: Profile) -> [String: Any]? {
        let rec = registry.find(p.id.uuidString.lowercased())
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": p.id.uuidString,
            "shortId": String(p.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)),
            "name": p.name,
            "color": p.color.rawValue,
            "tool": p.tool.rawValue,
            "authMode": p.authMode.rawValue,
            "apiKeySet": (p.apiKey?.isEmpty == false),
            "memoryGB": p.memoryGB,
            "networkMode": p.networkMode.rawValue,
            "macAddress": rec?.mac ?? "",
            "closeAction": p.closeAction.rawValue,
            "bootAtStartup": p.bootAtStartup,
            "folderPaths": p.folderPaths,
            "mcpServers": p.mcpServers.map { $0.name },
            "sshKeySet": (p.sshPublicKey?.isEmpty == false),
            "importedSSHKeys": p.importedSSHKeys.count,
            "running": live[p.id.uuidString.lowercased()] != nil,
            "comments": p.comments,
            "createdAt": iso.string(from: p.createdAt),
            "squelch": p.squelch.enabled,
        ]
        if let last = p.lastUsedAt { d["lastUsedAt"] = iso.string(from: last) }
        // What Squelch saved here (macOS: the workspace row's squelchSummary).
        if let sum = SquelchLedger.shared.summary(p.id), let v = JSONValue.encoding(sum) { d["squelchSummary"] = v.foundationObject }
        return d
    }

    /// The whole Profile with every secret blanked (kube contexts as their
    /// redacted identity, model keys as the stand-in), for an editor's
    /// round-trip.
    // @port ACAppDelegate.automationProfileExport(_: String) h=c3bd6cf97c423366 @b10aa434
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onExportProfile h=45bcd0825d999f58 @d3ebbda2
    static func profileExport(_ p: Profile) -> [String: Any]? {
        var stripped = p
        _ = ProfileSecrets.extract(stripping: &stripped)   // blank all secrets
        stripped.kubeconfigs = p.kubeconfigs.map { $0.redactedIdentity() }
        markRedactedModelKeys(&stripped, from: p)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(stripped),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        dict["_secretsRedacted"] = true
        dict["configuredCredentialRefs"] = p.configuredCredentials().map(\.id)
        return dict
    }

    /// `?storage=1`: what the workspace's disks take (allocated bytes), as
    /// macOS's StorageSizes reports them.
    // partial: Linux VM disk layout
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onDescribeStorage h=220dcc14c9608a58 @d3ebbda2
    func storage(_ p: Profile) -> JSONValue {
        let dir = vmDir(p.id.uuidString.lowercased())
        func allocated(_ path: String) -> Int64? {
            var st = stat()
            return stat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : nil
        }
        func size(_ path: String) -> Int64? {
            var st = stat()
            return stat(path, &st) == 0 ? Int64(st.st_size) : nil
        }
        let base = (try? config.checkedImage())?.baseImage ?? config.imageDir + "/base.img"
        var body: [String: JSONValue] = [
            "baseBytes": .number(Double(allocated(base) ?? 0)),
            "diskBytes": .number(Double(allocated(dir + "/disk.raw") ?? 0)),
            "homeBytes": .number(Double(allocated(dir + "/home.img") ?? 0)),
            "homeCapacity": .number(Double(size(dir + "/home.img") ?? 0)),
            "hasDisk": .bool(FileManager.default.fileExists(atPath: dir + "/disk.raw")),
            "hasHome": .bool(FileManager.default.fileExists(atPath: dir + "/home.img")),
            "homeIsImage": true,
            "isRunning": .bool(live[p.id.uuidString.lowercased()] != nil),
            // What a home made here now gets (no image yet / erased): this
            // host's free space and setting, not the client's.
            "defaultHomeGB": .number(Double(newHomeDefaultGB())),
        ]
        if let m = try? FileManager.default.attributesOfItem(atPath: dir + "/home.img")[.modificationDate] as? Date {
            body["homeModified"] = .string(ISO8601DateFormatter().string(from: m))
        }
        return .object(body)
    }

    /// The folders inside `path` ("~", "~/proj", an absolute guest path) on
    /// a workspace, for the new-session folder browser: asked of the guest
    /// while it runs, read from its ext4 home image (HomeImageReader) when it's off.
    /// Dotfolders are left out; nil when it can't be read now.
    // @port ACAppDelegate.listGuestFolders(profileID: UUID, path: String) h=64115e569c42caf3 @b10aa434
    // partial: the key resolution (id or name) is in workspaceRoute's POST /agent-sessions/folders
    // @port ACAppDelegate.listGuestFolders(profileKey: String, path: String) h=4c46ad77a88df496 @d3ebbda2
    // partial: calls HomeImageReader.folders inline
    // @port ACAppDelegate.static ext4Folders(imagePath: String, path: String) h=ca3e8b921fc2cb85 @d3ebbda2
    func listGuestFolders(_ profile: Profile, path: String) async -> [String]? {
        let guestPath = SessionHome.guestPath(path)
        let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if live[profile.id.uuidString.lowercased()] != nil,
           let out = try? await guestExec(
                profileID: profile.id,
                command: "if [ -d \(q) ]; then find \(q) -mindepth 1 -maxdepth 1 -type d "
                    + "! -name '.*' -printf '%f\\n' 2>/dev/null | sort -f; fi; true",
                timeout: 10) {
            return out.split(whereSeparator: \.isNewline).map(String.init)
        }
        // The host folders the machine mounts: in the guest they're ~/<name>
        // symlinks into /mnt/bromure-share-N, which only exist while it runs:
        // off, they're read straight from this server.
        let shares = SessionDisk.sharedFolders(profile.folderPaths)
        if let dir = Self.hostShareDirectory(guestPath: guestPath, shares: shares) {
            return Self.hostFolders(in: dir)
        }
        let home = "/home/ubuntu"
        guard guestPath == home || guestPath.hasPrefix(home + "/") else { return nil }
        let rel = guestPath == home ? "/" : String(guestPath.dropFirst(home.count))
        let img = vmDir(profile.id.uuidString.lowercased()) + "/home.img"
        var names: [String]?
        if FileManager.default.fileExists(atPath: img) {
            names = await Task.detached(priority: .userInitiated) { HomeImageReader.folders(imagePath: img, path: rel) }.value
        }
        guard rel == "/", !shares.isEmpty else { return names }
        // The home lists the shares too (a home never booted has none of
        // their symlinks yet).
        let all = Set(names ?? []).union(shares.map(\.mountName))
        return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The host folder behind a guest path inside a shared folder
    /// (~/<name>/… or /mnt/bromure-share-N/…), nil for any other path.
    // @port ACAppDelegate.static hostShareDirectory(guestPath: String, shares: [SessionDisk.SharedFolder]) h=ce221fc59a21099d @d3ebbda2
    nonisolated static func hostShareDirectory(guestPath: String, shares: [SessionDisk.SharedFolder]) -> URL? {
        for (i, share) in shares.enumerated() {
            for root in ["/home/ubuntu/" + share.mountName, "/mnt/bromure-share-\(i + 1)"] {
                if guestPath == root { return share.url }
                if guestPath.hasPrefix(root + "/") {
                    return share.url.appendingPathComponent(String(guestPath.dropFirst(root.count + 1)))
                }
            }
        }
        return nil
    }

    /// A host folder's subfolders (no dotfolders), sorted as Finder does.
    // @port ACAppDelegate.static hostFolders(in: URL) h=0794a33ec83a0c6d @d3ebbda2
    nonisolated static func hostFolders(in dir: URL) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                && isDir.boolValue
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// `GET /squelch`: each workspace's Squelch setting and what it saved
    /// over its last 30 commands / 30 days (macOS: onSquelchStats).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSquelchStats h=d6dd55f18cba5011 @d3ebbda2
    static func squelchStats() -> [String: Any] {
        var out: [String: Any] = [:]
        for p in ProfileStore().loadAll() {
            var row: [String: Any] = ["name": p.name, "enabled": p.squelch.enabled]
            if let sum = SquelchLedger.shared.summary(p.id, commands: 30, days: 30),
               let v = JSONValue.encoding(sum)?.foundationObject { row["summary"] = v }
            out[p.id.uuidString] = row
        }
        return ["workspaces": out]
    }

}
