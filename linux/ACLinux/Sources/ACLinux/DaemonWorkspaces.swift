import Foundation

/// A fat client's view of one workspace (macOS: the automation server's
/// /profiles/<id> and /agent-sessions/folders, and the app delegate's
/// describe / export / folder listing behind them).
extension Daemon {
    /// `GET /profiles/<id>` (`?full=1`: the whole Profile, secrets blanked;
    /// `?storage=1`: its disk sizes; else the compact describe), a workspace's
    /// firewall (`POST …/firewall`, `…/firewall-edit`), and `POST
    /// /agent-sessions/folders`; nil for any other path.
    // partial: no squelch, proposals, policy revisions, OpenShell/sandbox-path decisions or DELETE sub-routes yet
    // @port ACAutomationServer.handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String:Any]) h=59e55ae73cdc6185 @f127f8ab
    func workspaceRoute(_ method: String, _ fullPath: String, _ body: JSONValue) async -> ControlResponse? {
        let parts = fullPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0], query = parts.count > 1 ? parts[1] : ""
        switch (method, path) {
        case ("POST", "/agent-sessions/folders"):
            guard let key = body["profile"]?.stringValue, !key.isEmpty else { return .error(400, "profile required") }
            guard let p = Self.workspace(key) else { return .error(404, "The machine's folders can't be read right now") }
            guard let folders = await listGuestFolders(p, path: body["path"]?.stringValue ?? "~") else {
                return .error(404, "The machine's folders can't be read right now")
            }
            return ControlResponse(200, ["folders": .array(folders.map { .string($0) })])
        case ("GET", let p) where p.hasPrefix("/profiles/"):
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
        case ("POST", let p) where p.hasPrefix("/profiles/") && p.hasSuffix("/compromised"):
            let raw = String(p.dropFirst("/profiles/".count).dropLast("/compromised".count))
            return await resolveCompromise(raw.removingPercentEncoding ?? raw, action: body["action"]?.stringValue ?? "")
        case ("PUT", let p) where p.hasPrefix("/profiles/"), ("PATCH", let p) where p.hasPrefix("/profiles/"):
            let raw = String(p.dropFirst("/profiles/".count))
            return await updateProfile(raw.removingPercentEncoding ?? raw, body)
        default:
            return nil
        }
    }

    /// A workspace by id or name (macOS: profileByNameOrID).
    // @port-skip linux-only: ProfileStore lookup (macOS: the app's profile list)
    static func workspace(_ key: String) -> Profile? {
        let all = ProfileStore().loadAll()
        return all.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }
            ?? all.first { $0.name.lowercased() == key.lowercased() }
    }

    /// The compact summary a client's workspace list and CLI read.
    // partial: the MAC is the VM record's (macOS: MACBindings)
    // @port ACAppDelegate.automationProfileDescribe(_: String) h=f0e4c0339194b0f0 @b10aa434
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
    // @port-skip linux-only: the Linux VM layout's sizes (macOS: makeStorageContext + StorageSizes.measure)
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
        let base = config.imageDir + "/base.img"
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
    // partial: no shared host folders on Linux workspaces
    // @port ACAppDelegate.listGuestFolders(profileID: UUID, path: String) h=64115e569c42caf3 @b10aa434
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
        let home = "/home/ubuntu"
        guard guestPath == home || guestPath.hasPrefix(home + "/") else { return nil }
        let rel = guestPath == home ? "/" : String(guestPath.dropFirst(home.count))
        let img = vmDir(profile.id.uuidString.lowercased()) + "/home.img"
        guard FileManager.default.fileExists(atPath: img) else { return nil }
        return await Task.detached(priority: .userInitiated) { HomeImageReader.folders(imagePath: img, path: rel) }.value
    }

}
