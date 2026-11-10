import Foundation
import SandboxEngine

/// Kubernetes clusters and container registries on a Linux server: the
/// shared engine (KubeClusterEngine) over this daemon's VMs. A cluster's
/// node (and a registry, the connector) is a daemon VM record owned by it
/// (`VMRecord.kube`): never a workspace, never listed as one, taken back by
/// a restarted daemon like any VM. Every machine is this daemon's: its user's
/// switch and subnet, which no other user's VMs or daemon can reach.
extension Daemon {
    /// `/k8s…` and `/registries…`; nil for any other path.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    func kubeRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse? {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        switch (method, path) {
        case ("GET", "/k8s"), ("GET", "/k8s/"): return await kubeList()
        case ("GET", "/registries"), ("GET", "/registries/"): return await registryList()
        case ("POST", "/k8s"): return await kubeCreate(doc)
        case (let m, let p) where p.hasPrefix("/k8s/"): return await kubeCommand(m, p, doc)
        case ("POST", "/registries"): return await registryCreate(doc)
        case (let m, let p) where p.hasPrefix("/registries/"): return await registryCommand(m, p, doc)
        default: return nil
        }
    }

    /// The clusters, registries, connectors and their status.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/k8s"): h=dde246cbd63efa97 @f127f8ab
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListKubeClusters h=0c729e20e2122b7f @32a528c5
    func kubeList() async -> ControlResponse {
        let snap = await MainActor.run { SessionStores.shared?.kube.snapshot() ?? ["clusters": [], "status": [:]] }
        return ControlResponse(200, JSONValue(foundation: snap) ?? .object([:]))
    }

    /// `GET /registries`: the registries and their status (the same rows
    /// `GET /k8s` carries).
    // @port-skip linux-only: a read route macOS serves only through GET /k8s
    func registryList() async -> ControlResponse {
        let snap = await MainActor.run { SessionStores.shared?.kube.snapshot() ?? [:] }
        return ControlResponse(200, JSONValue(foundation: ["registries": snap["registries"] ?? [],
                                                          "status": snap["status"] ?? [:]]) ?? .object([:]))
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/k8s"): h=f99ca82a9e3186a6 @f127f8ab
    func kubeCreate(_ doc: [String: Any]) async -> ControlResponse {
        var doc = doc
        if doc["action"] == nil { doc["action"] = "create" }
        let result = await MainActor.run { [doc] in Self.kubeCommand(id: nil, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    /// `POST /k8s/{id}/{action}` (fat-client cluster verbs).
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p.hasPrefix("/k8s/"): h=ecf14d0915d2df82 @f127f8ab
    func kubeCommand(_ method: String, _ path: String, _ doc: [String: Any]) async -> ControlResponse {
        guard method == "POST" || method == "DELETE" else { return .error(405, "Method not allowed") }
        let rest = String(path.dropFirst("/k8s/".count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        let id = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
        var doc = doc
        if parts.count > 1, !parts[1].isEmpty { doc["action"] = parts[1] }
        if method == "DELETE" { doc["action"] = "delete" }
        // A node's disks under repair: its rescue would be killed mid-e2fsck
        // and the node itself (marked) left behind with its disks.
        if doc["action"] as? String == "delete", let owner = UUID(uuidString: id), kubeOwnerUnderRepair(owner) {
            return .error(409, "A node of this cluster is having its disks repaired; delete it once that's done")
        }
        let result = await MainActor.run { [doc] in Self.kubeCommand(id: id, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/registries"): h=a2c8ce826a1eaa9a @f127f8ab
    func registryCreate(_ doc: [String: Any]) async -> ControlResponse {
        var doc = doc
        if doc["action"] == nil { doc["action"] = "create" }
        let result = await MainActor.run { [doc] in Self.registryCommand(id: nil, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p.hasPrefix("/registries/"): h=52a7426dba2a3e85 @f127f8ab
    func registryCommand(_ method: String, _ path: String, _ doc: [String: Any]) async -> ControlResponse {
        guard method == "POST" || method == "DELETE" else { return .error(405, "Method not allowed") }
        let rest = String(path.dropFirst("/registries/".count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        let id = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
        var doc = doc
        if parts.count > 1, !parts[1].isEmpty { doc["action"] = parts[1] }
        if method == "DELETE" { doc["action"] = "delete" }
        // Its machine's disks under repair, as a cluster's (kubeCommand).
        if doc["action"] as? String == "delete", let owner = UUID(uuidString: id), kubeOwnerUnderRepair(owner) {
            return .error(409, "This registry's machine is having its disks repaired; delete it once that's done")
        }
        let result = await MainActor.run { [doc] in Self.registryCommand(id: id, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    /// A fat-client cluster verb (`POST /k8s` "create", or `POST
    /// /k8s/{id}/{action}`) on the engine.
    // partial: a deleted cluster's machines are removed here (macOS: with the cluster's folder)
    // @port ACAppDelegate.automationKubeCommand(id: String?, doc: [String:Any]) h=ccdfe10f6c32148f @32a528c5
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onKubeCommand h=d1063882746964c2 @d3ebbda2
    @MainActor static func kubeCommand(id: String?, doc: [String: Any]) -> [String: Any] {
        guard let stores = SessionStores.shared, let engine = stores.kubeEngine else {
            return ["ok": false, "error": "unavailable"]
        }
        let action = (doc["action"] as? String) ?? ""
        if id == nil {
            guard action == "create" else { return ["ok": false, "error": "unknown action: \(action)"] }
            guard let name = doc["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ["ok": false, "error": "missing name"]
            }
            var spec = KubeClusterSpec()
            if let raw = doc["spec"], JSONSerialization.isValidJSONObject([raw]),
               let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
               let decoded = try? JSONDecoder().decode(KubeClusterSpec.self, from: data) {
                spec = decoded
            }
            let access = decodeAccess(doc["access"]) ?? .all
            let cluster = engine.create(name: name, spec: spec, access: access,
                                        autoStart: (doc["autoStart"] as? Bool) ?? true,
                                        synologyPassword: doc["synologyPassword"] as? String)
            return ["ok": true, "id": cluster.id.uuidString]
        }
        guard let id, let uuid = UUID(uuidString: id), stores.kube.cluster(uuid) != nil else {
            return ["ok": false, "error": "no such cluster"]
        }
        switch action {
        case "start":   engine.start(uuid)
        case "stop":    Task { await engine.stop(uuid) }
        case "restart": engine.restart(uuid)
        case "delete":
            Task {
                await engine.delete(uuid)
                await LinuxKubeHost.shared?.removeMachines(ownedBy: uuid)
            }
        case "access":
            guard let access = decodeAccess(doc["access"]) else { return ["ok": false, "error": "bad access"] }
            engine.setAccess(uuid, access)
        case "autostart":
            engine.setAutoStart(uuid, (doc["on"] as? Bool) ?? true)
        case "watch":
            engine.setWatch(uuid, (doc["on"] as? Bool) ?? false)
        case "kubeconfig":
            guard let yaml = engine.kubeconfigYAML(uuid) else {
                return ["ok": false, "error": "no kubeconfig yet"]
            }
            return ["ok": true, "kubeconfig": yaml]
        default:
            return ["ok": false, "error": "unknown kube action: \(action)"]
        }
        return ["ok": true]
    }

    /// A fat-client registry verb (`POST /registries` "create", or
    /// `POST /registries/{id}/{action}`).
    // partial: a deleted registry's machine is removed here (macOS: with its folder)
    // @port ACAppDelegate.automationRegistryCommand(id: String?, doc: [String:Any]) h=769838b3e51c3441 @32a528c5
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onRegistryCommand h=413b6bcedae58870 @d3ebbda2
    @MainActor static func registryCommand(id: String?, doc: [String: Any]) -> [String: Any] {
        guard let stores = SessionStores.shared, let engine = stores.kubeEngine else {
            return ["ok": false, "error": "unavailable"]
        }
        let action = (doc["action"] as? String) ?? ""
        if id == nil {
            guard action == "create" else { return ["ok": false, "error": "unknown action: \(action)"] }
            guard let name = doc["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ["ok": false, "error": "missing name"]
            }
            let registry = engine.createRegistry(
                name: name, access: decodeAccess(doc["access"]) ?? .all,
                memoryGB: (doc["memoryGB"] as? Int) ?? 1, diskGB: (doc["diskGB"] as? Int) ?? 40,
                autoStart: (doc["autoStart"] as? Bool) ?? true)
            return ["ok": true, "id": registry.id.uuidString]
        }
        guard let id, let uuid = UUID(uuidString: id), stores.kube.registry(uuid) != nil else {
            return ["ok": false, "error": "no such registry"]
        }
        switch action {
        case "start":   engine.startRegistry(uuid)
        case "stop":    Task { await engine.stopRegistry(uuid) }
        case "restart": engine.restartRegistry(uuid)
        case "delete":
            Task {
                await engine.deleteRegistry(uuid)
                await LinuxKubeHost.shared?.removeMachines(ownedBy: uuid)
            }
        case "access":
            guard let access = decodeAccess(doc["access"]) else { return ["ok": false, "error": "bad access"] }
            engine.setRegistryAccess(uuid, access)
        case "autostart":
            engine.setRegistryAutoStart(uuid, (doc["on"] as? Bool) ?? true)
        case "watch":
            engine.setWatch(uuid, (doc["on"] as? Bool) ?? false)
        default:
            return ["ok": false, "error": "unknown registry action: \(action)"]
        }
        return ["ok": true]
    }

    // @port-skip linux-only: the access decoder automationKubeCommand / automationRegistryCommand share inline
    static func decodeAccess(_ raw: Any?) -> KubeWorkspaceAccess? {
        guard let raw, JSONSerialization.isValidJSONObject([raw]),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(KubeWorkspaceAccess.self, from: data)
    }

    // MARK: Workspaces' kubeconfigs

    /// A workspace's ~/.kube/config at launch (macOS: launch's
    /// KubeconfigMaterializer step): its own kubeconfigs with fakes, and the
    /// Bromure clusters it may use as direct contexts (real CA and admin
    /// cert, reached over the bridged switch). The bearer swaps join the
    /// proxy's map for the workspace; imported kubeconfigs' client
    /// certificates and cluster CAs go to the proxy's kube trust (presented
    /// upstream, and the only anchor of that endpoint's server certificate).
    /// `live`: the VM runs (a refresh): the swap map is merged, as macOS's
    /// pushLiveCredentials does -- an exec plugin's fetched token stays on
    /// its unchanged fake, a still-running shell's old fake keeps working.
    /// At launch the map is the fresh one.
    // @port-skip linux-only: the kubeconfig step of ACAppDelegate.launch / pushLiveCredentials, on the Linux proxy
    func kubeconfig(for profile: Profile, plan: SessionTokenPlan?, live: Bool = false) async -> String? {
        guard let mitm else { return nil }
        return await Self.kubeconfig(for: profile, plan: plan, live: live, mitm: mitm)
    }

    /// A running workspace's kubeconfig made again (the refresh's step, per
    /// workspace): its plan, then the kubeconfig with the map merged.
    // @port-skip linux-only: the per-workspace body of refreshKubeAccessForRunningWorkspaces → pushLiveCredentials
    static func liveKubeconfig(for profile: Profile, mitm: MitmProxy) async -> String? {
        await kubeconfig(for: profile, plan: makeSessionTokenPlan(for: profile, mitm: mitm), live: true, mitm: mitm)
    }

    // @port-skip linux-only: kubeconfig(for:plan:live:)'s body over a given proxy (testable)
    static func kubeconfig(for profile: Profile, plan: SessionTokenPlan?, live: Bool, mitm: MitmProxy) async -> String? {
        let pem = mitm.ca.certificatePEM
        let pid = profile.id
        let reusing = mitm.kubeExecContexts(for: pid)
        let mat = await MainActor.run {
            KubeconfigMaterializer().materialize(
                profile: profile, bromureCAPEM: pem,
                directClusters: SessionStores.shared?.kubeEngine?.directClusters(for: pid) ?? [],
                reusingExec: reusing)
        }
        var base = plan?.tokenMap()
        // Credentials the VM minted earlier (`MintedCredential`), as macOS's
        // launch and restage compose the map.
        base?.entries += MintedCredential.tokenEntries(profile.mintedCredentials, salt: mitm.fakeTokenSalt)
        mitm.awsCreds.setMinted(profile.mintedCredentials, for: pid)
        await MainActor.run { [base] in mitm.installKube(mat, base: base, profileID: pid, live: live) }
        return mat.yaml.isEmpty ? nil : mat.yaml
    }

    /// Every running workspace's credentials restaged, its ~/.kube/config
    /// among them (a cluster came up, went away, or changed who may use it),
    /// through the live refresh queue (macOS: refreshKubeAccessForRunningWorkspaces
    /// → pushLiveCredentials). Also a restarted daemon's, for its taken-back
    /// workspaces (their kube fakes were made anew). The number restaged.
    // @port-skip linux-only: refreshKubeAccessForRunningWorkspaces on the Linux daemon
    @discardableResult
    func refreshWorkspaceKubeconfigs() async -> Int {
        let tasks = registry.records.filter { $0.state == .running && !$0.managed && live[$0.id] != nil }
            .map { scheduleLiveRestage($0.id) }
        for t in tasks { await t.value }
        return tasks.count
    }

    /// The node and registry addresses a workspace reaches directly (macOS:
    /// extraNoProxy): kept off the proxy in its proxy.env.
    // @port-skip linux-only: KubeClusterEngine.extraNoProxy into the Linux proxy.env
    func kubeNoProxy(for profileID: UUID) async -> [String] {
        await MainActor.run { SessionStores.shared?.kubeEngine?.extraNoProxy(for: profileID) ?? [] }
    }

    /// The Bromure registries a workspace may push to and pull from (macOS:
    /// registryAddresses into the session disk's docker-registries.txt).
    // @port-skip linux-only: KubeClusterEngine.registryAddresses into the Linux meta share
    func kubeRegistries(for profileID: UUID) async -> [String] {
        await MainActor.run { SessionStores.shared?.kubeEngine?.registryAddresses(for: profileID) ?? [] }
    }

    // MARK: The machines, actor side

    /// A cluster machine's record, made (stopped) if it has none, with its
    /// data disk and the scripts it runs in its meta share; a suspended one
    /// that may not resume is shut down (its snapshot dropped).
    // @port-skip linux-only: the daemon side of LinuxKubeHost.startKubeMachine
    func prepareKubeMachine(id: String, name: String, owner: UUID, cpus: Int, memoryMiB: Int,
                            dataDiskGB: Int?, scripts: [(String, URL)], resume: Bool,
                            folders: [String] = [], rescueFor: String? = nil) async throws {
        if registry.find(id) == nil {
            let r = await createVM(.object(["name": .string(name), "cpus": .number(Double(cpus)),
                                            "memoryGB": .number(Double(memoryMiB) / 1024)]),
                                   id: id, boot: false, kube: owner.uuidString.lowercased(), dataDiskGB: dataDiskGB,
                                   folders: folders, rescueFor: rescueFor)
            guard r.status == 201 else {
                throw KubeClusterEngine.KubeError.message("\(name): \(r.body["error"]?.stringValue ?? "couldn't make the machine")")
            }
        }
        guard let rec = registry.find(id) else { throw KubeClusterEngine.KubeError.message("\(name): no machine") }
        let dir = vmDir(id)
        if let gb = rec.dataDiskGB {
            try Self.ensureHomeImage(atPath: dir + "/data.img", bytes: UInt64(gb) << 30)
        }
        let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (file, url) in scripts {
            let dest = meta.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest.path)
        }
        if rec.state == .suspended, !resume { _ = await deleteVM(rec, action: "stop") }
    }

    /// A VM's serial console log and its size now: a boot's scan reads from
    /// there (Firecracker appends to it).
    // @port-skip linux-only: the Linux VM layout (machineConfig's serialLog)
    func serialLog(id: String) -> (path: String, offset: UInt64)? {
        guard let rec = registry.find(id) else { return nil }
        let path = config.runtimeDir + "/vms/" + rec.shortId + "/serial.log"
        var st = stat()
        return (path, stat(path, &st) == 0 ? UInt64(st.st_size) : 0)
    }

    // @port-skip linux-only: the daemon's live table
    func kubeMachineIsLive(id: String) -> Bool { live[id] != nil }

    /// A stopped cluster machine's ext4 images for a disk repair: its
    /// system disk and, when it has one, its data disk (macOS: disk.img and
    /// data.img). nil while it runs, is starting or stopping, or another
    /// repair has it:
    /// never checked live. The machine is marked as repairing in the same
    /// step (on the actor), so no start can take it until the caller's
    /// `repairMarks.whileMarked` ends.
    // @port-skip linux-only: the Linux machine layout for ACAppDelegate.repairKubeMachineDisks
    func kubeMachineDiskImages(id: String) -> [String]? {
        guard live[id] == nil, stopping[id] == nil, !starting.contains(id), !hasRescue(for: id),
              repairMarks.insert(id) else { return nil }
        let dir = vmDir(id)
        var images = [dir + "/disk.raw"]
        if FileManager.default.fileExists(atPath: dir + "/data.img") { images.append(dir + "/data.img") }
        return images
    }

    /// Boot (or resume) a cluster machine; nil when it runs, else why not
    /// (refused while its disks are being repaired: `start`).
    /// Already running (a restarted daemon took it back): nothing to do.
    // @port-skip linux-only: the daemon side of LinuxKubeHost.startKubeMachine
    func startKubeMachineVM(id: String) async -> String? {
        guard let rec = registry.find(id) else { return "no machine" }
        if live[id] != nil { return nil }
        let r = await start(rec, unattended: true)
        return r.status == 200 ? nil : (r.body["error"]?.stringValue ?? "didn't start")
    }

    /// Shut a cluster machine down (`kill`: at once).
    // @port-skip linux-only: the daemon side of LinuxKubeHost.stopKubeMachine
    func stopKubeMachineVM(id: String, kill: Bool) async {
        guard let rec = registry.find(id) else { return }
        if kill { try? FileManager.default.removeItem(atPath: snapshotDir(id)) }
        _ = await deleteVM(rec, action: kill ? "kill" : "stop")
    }

    /// One managed machine (a disk repair's throwaway rescue): ended and
    /// removed with its files. Nothing when it's already gone.
    // @port-skip linux-only: macOS removes the rescue's folder
    func removeKubeMachine(id: String) async {
        guard let rec = registry.find(id) else { return }
        if live[id] != nil { _ = await deleteVM(rec, action: "kill") }
        if let r = registry.find(id) { _ = remove(r) }
    }

    /// A disk-repair rescue for `id` is on record (live or not).
    // @port-skip linux-only: the Linux daemon's repair gate
    func hasRescue(for id: String) -> Bool { registry.records.contains { $0.rescueFor == id } }

    /// Rescues a previous daemon left (killed mid-repair): never taken back.
    /// Each is ended -- its Firecracker, then the virtiofsds that served the
    /// damaged machine's folder -- and removed, before adoption and before
    /// any cluster starts; its machine stays marked until the rescue is gone
    /// (and refused while its record is: hasRescue).
    // @port-skip linux-only: the Linux daemon's repair gate
    func dropLeftoverRescues() async {
        for rec in registry.records {
            guard let target = rec.rescueFor else { continue }
            _ = repairMarks.insert(target)
            let ended = Self.killIfOursAndWait(rec)
                && Self.killFirecrackers(shortId: rec.shortId)
                && Self.killVirtiofsds(under: config.runtimeDir + "/vms/" + rec.shortId)
            var r = rec
            if ended {
                r.state = .stopped
                r.pid = nil
                try? registry.upsert(r)
                _ = remove(r)
            }
            if registry.find(rec.id) == nil {
                repairMarks.remove(target)
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': a disk-repair machine from before the restart, ended and removed\n".utf8))
            } else {
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': a disk-repair machine from before the restart couldn't be ended; its machine stays refused\n".utf8))
            }
        }
    }

    /// Rescues for `id` left from an earlier repair (one whose removal
    /// failed), removed before a new one; false while a repair has `id`
    /// marked (its rescue is in use) or one couldn't be removed.
    // @port-skip linux-only: the Linux daemon's repair gate
    func removeStaleRescues(for id: String) async -> Bool {
        guard !repairMarks.contains(id) else { return false }
        for rec in registry.records where rec.rescueFor == id {
            await removeKubeMachine(id: rec.id)
        }
        return !hasRescue(for: id)
    }

    /// Whether a machine of `owner` is being repaired: marked, or with a
    /// rescue on record.
    // @port-skip linux-only: the Linux daemon's repair gate
    func kubeOwnerUnderRepair(_ owner: UUID) -> Bool {
        let key = owner.uuidString.lowercased()
        return registry.records.contains { $0.kube == key && (repairMarks.contains($0.id) || hasRescue(for: $0.id)) }
    }

    /// Every machine `owner` (a deleted cluster or registry) had: ended and removed.
    // @port-skip linux-only: macOS removes them with the cluster's folder
    func removeKubeMachines(owner: UUID) async {
        let key = owner.uuidString.lowercased()
        for rec in registry.records where rec.kube == key {
            // A repair that began after the delete was accepted keeps its
            // rescue: once it ends, the startup sweep takes what's left
            // (its owner gone).
            if let target = rec.rescueFor, repairMarks.contains(target) { continue }
            if live[rec.id] != nil { _ = await deleteVM(rec, action: "kill") }
            if let r = registry.find(rec.id) { _ = remove(r) }
        }
    }

    /// Cluster machines whose owner is gone (a crash between deleting the
    /// cluster and removing its machines): ended and removed, at startup —
    /// only when the store loaded cleanly (`storeFile` read back whole); a
    /// store that's missing or didn't decode would make every machine look
    /// orphaned, so then nothing is swept, and the daemon says why.
    // @port-skip linux-only: macOS removes them with the cluster's folder
    func sweepKubeOrphans(owners: Set<String>, storeFile: String, loadedCounts: Int) async {
        guard registry.records.contains(where: { $0.kube != nil }) else { return }
        if let why = Self.kubeStoreLoadProblem(storeFile, loadedCounts: loadedCounts) {
            FileHandle.standardError.write(Data("bromure-ac daemon: cluster machines not swept: \(why)\n".utf8))
            return
        }
        for rec in registry.records {
            guard let owner = rec.kube, !owners.contains(owner) else { continue }
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': its cluster is gone, removed\n".utf8))
            if live[rec.id] != nil { _ = await deleteVM(rec, action: "kill") }
            if let r = registry.find(rec.id) { _ = remove(r) }
        }
    }

    /// Why the cluster store at `path` didn't load cleanly (nil: it did):
    /// missing, unreadable, or holding more clusters, registries and
    /// connectors than the store decoded (`loadedCounts`).
    // @port-skip linux-only: the sweep's guard
    static func kubeStoreLoadProblem(_ path: String, loadedCounts: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return "\(path) is missing" }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "\(path) isn't readable JSON"
        }
        // The store's own shape: a clusters array (registries and connectors
        // are absent in files older servers wrote, arrays when present).
        guard obj["clusters"] is [Any],
              ["registries", "connectors"].allSatisfy({ obj[$0] == nil || obj[$0] is [Any] }) else {
            return "\(path) isn't a cluster store"
        }
        let inFile = ["clusters", "registries", "connectors"].reduce(0) { $0 + (((obj[$1] as? [Any])?.count) ?? 0) }
        return inFile == loadedCounts ? nil : "\(path) has \(inFile) entries, \(loadedCounts) decoded"
    }

    /// A connection to `target` ("ip:port") from inside the machine, over
    /// its loopback relay (vsock 5010, as /fatclient/forward); -1 if none.
    // @port-skip linux-only: the daemon side of LinuxKubeHost.openKubeRelay
    func kubeRelayFD(id: String, target: String) async -> Int32 {
        guard let l = live[id] else { return -1 }
        let fd = await l.config.dialGuest(port: 5010)
        guard fd >= 0 else { return -1 }
        let header = target + "\n"
        let ok = header.utf8CString.withUnsafeBufferPointer { b in write(fd, b.baseAddress, b.count - 1) == b.count - 1 }
        guard ok else { close(fd); return -1 }
        return fd
    }
}

/// A shared (multi-user) server's load balancer: binds nothing; every
/// LoadBalancer port is reported pending (no host-IP publishing on a shared
/// server; LAN address pools come with the announcer).
// @port-skip linux-only: the multi-user rule for KubeLoadBalancer
@MainActor
final class SharedServerLoadBalancer: KubeServicePublisher {
    static let reason = "LoadBalancer services need a LAN address pool on a shared server"
    // @port-skip linux-only: a shared server answers on no host address
    var hostIP: String? { nil }

    // @port-skip linux-only: the multi-user rule
    func reconcile(services: [KubeProbe.Service]) -> [KubeLBEndpoint] {
        services.filter { !$0.isVMScoped }.flatMap { svc in
            svc.ports.map { p in
                KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port, nodePort: p.nodePort,
                               protocolName: p.protocolName, bound: false, error: Self.reason)
            }
        }
    }

    // @port-skip linux-only: nothing to stop
    func stopAll() {}
}

/// The engine's machine host on a Linux server (macOS: ACAppDelegate,
/// KubeClusterEngine+VZ.swift): each machine a VM record of this daemon.
// @port-skip linux-only: the daemon's KubeEngineHost (macOS: ACAppDelegate)
@MainActor
final class LinuxKubeHost: KubeEngineHost {
    static var shared: LinuxKubeHost?
    private weak var daemon: Daemon?
    private let session: LinuxSessionHost
    /// A deep repair's rescue node -> the machine it repairs (its record's
    /// rescueFor, written as the record is made).
    private var rescueTargets: [UUID: String] = [:]

    // @port-skip linux-only: daemon wiring
    init(daemon: Daemon, session: LinuxSessionHost) {
        self.daemon = daemon
        self.session = session
    }

    /// The host's handle on a machine: its spec, for the start.
    final class Machine {
        let spec: KubeClusterEngine.MachineSpec
        /// Where its boot's console scan reports a failed filesystem check.
        let fsFailure: KubeClusterEngine.BootFSFailure
        /// The scan of the boot under way.
        var consoleScan: Task<Void, Never>?
        // @port-skip linux-only: LinuxKubeHost's handle
        init(_ spec: KubeClusterEngine.MachineSpec, fsFailure: KubeClusterEngine.BootFSFailure) {
            self.spec = spec
            self.fsFailure = fsFailure
        }
    }

    // @port-skip linux-only: VM ids are lowercased UUIDs
    private static func vmID(_ nodeID: UUID) -> String { nodeID.uuidString.lowercased() }

    // partial: the record is made at start (the daemon's createVM is async)
    // @port ACAppDelegate.makeKubeMachine(_: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime, fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) h=c08c904270224b9d @e0cc8f0b
    func makeKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                         fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) throws {
        for (name, url) in m.scripts where url == nil {
            throw KubeClusterEngine.KubeError.message("\(name) missing from the resources")
        }
        runtime.machine = Machine(m, fsFailure: fsFailure)
    }

    // partial: the IP comes from the guest (the engine's ipCommand), not a host callback
    // @port ACAppDelegate.startKubeMachine(_: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime, repairAttempted: Bool, engine: KubeClusterEngine) h=8c8e3f0802ced39c @e0cc8f0b
    func startKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                          repairAttempted: Bool, engine: KubeClusterEngine) async throws {
        guard let daemon else { throw KubeClusterEngine.KubeError.message("the daemon is stopping") }
        let id = Self.vmID(m.record.id)
        let memMiB = m.memoryMB ?? m.memoryGB * 1024
        try await daemon.prepareKubeMachine(id: id, name: m.record.name, owner: m.ownerID, cpus: m.cpus,
                                            memoryMiB: memMiB, dataDiskGB: m.dataDiskGB,
                                            scripts: m.scripts.compactMap { n, u in u.map { (n, $0) } },
                                            resume: m.restoreSavedState && !repairAttempted,
                                            folders: m.folders, rescueFor: rescueTargets[m.record.id])
        // The console: each Firecracker starts a fresh serial.log (the last
        // one kept as serial.prev.log), so this boot's lines start at 0.
        let console = await daemon.serialLog(id: id).map { (path: $0.path, offset: UInt64(0)) }
        if let why = await daemon.startKubeMachineVM(id: id) {
            throw KubeClusterEngine.KubeError.message("\(m.record.name): \(why)")
        }
        // The console scanner (macOS: UbuntuSandboxVM.onBootFilesystemFailure):
        // a boot dying on filesystem errors drops to an emergency shell nobody
        // answers; the engine's boot wait sees fsFailure and repairs.
        if let console, let machine = runtime.machine as? Machine {
            machine.consoleScan?.cancel()
            let fsFailure = machine.fsFailure
            machine.consoleScan = Task.detached { [daemon] in
                let match = await BootConsoleScan.scan(path: console.path, from: console.offset) {
                    guard await daemon.kubeMachineIsLive(id: id) else { return false }
                    return await MainActor.run { !runtime.up && fsFailure.detail == nil }
                }
                guard let match else { return }
                FileHandle.standardError.write(Data("[kube] \(m.record.name): boot filesystem check failed: \(match)\n".utf8))
                await MainActor.run { if fsFailure.detail == nil { fsFailure.detail = match } }
            }
        }
    }

    // @port-skip linux-only: the engine's exec probe is the boot signal here
    func kubeMachineAnswers(_ nodeID: UUID) -> Bool { true }

    // @port-skip linux-only: the daemon keeps the lease itself
    func setKubeMachineIP(_ nodeID: UUID, _ ip: String) {}

    // partial: a hard stop, its snapshot dropped
    // @port ACAppDelegate.stopKubeMachineForRepair(_: KubeClusterEngine.NodeRuntime) h=5b6432b946566704 @e0cc8f0b
    func stopKubeMachineForRepair(_ runtime: KubeClusterEngine.NodeRuntime) async {
        await daemon?.stopKubeMachineVM(id: Self.vmID(runtime.record.id), kill: true)
    }

    /// Replay the journal and repair the machine's system disk -- and its
    /// data disk (Longhorn / registry storage), which the guest checks at
    /// boot too -- with the ext4 checker macOS uses (Swift, on the host: the
    /// images are guest-written, so no C parser runs on them here). True
    /// when every ext4 image came out clean or repaired.
    // @port ACAppDelegate.repairKubeMachineDisks(_: KubeClusterEngine.MachineSpec) h=963ec6e7efbbfc72 @e0cc8f0b
    func repairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec) async -> Bool {
        let ownerID = m.ownerID, name = m.record.name
        guard let daemon, let images = await daemon.kubeMachineDiskImages(id: Self.vmID(m.record.id)) else {
            SessionStores.shared?.kubeEngine?.log(ownerID, "fsck: \(name) is running or already being repaired; its disks weren't checked")
            return false
        }
        return await daemon.repairMarks.whileMarked(Self.vmID(m.record.id)) {
            var ok = true
            for path in images {
                let file = (path as NSString).lastPathComponent
                let result: Result<Ext4Fsck.Result, Error> = await SecureDir.offPool {
                    do { return .success(try Ext4Fsck.check(imagePath: path, autoFix: true)) }
                    catch { return .failure(error) }
                }
                switch result {
                case .success(let r):
                    if !(r.clean || r.repaired) { ok = false }
                    SessionStores.shared?.kubeEngine?.log(ownerID, "fsck \(file): \(r.summary)")
                    FileHandle.standardError.write(Data("[kube] fsck \(name) \(file): \(r.summary)\n\(r.output)\n".utf8))
                case .failure(let error):
                    // A data disk the guest never formatted is not ext4 yet --
                    // nothing to check there.
                    SessionStores.shared?.kubeEngine?.log(ownerID, "fsck \(file): skipped (\(error))")
                }
            }
            return ok
        }
    }

    /// The host-side checker only replays journals and clears the error flag
    /// (and on Linux the guest's own preen already does both); anything past
    /// that needs the real e2fsck. Boot a throwaway machine from the base
    /// image with the damaged machine's folder shared in (virtiofs
    /// share-1), and check its images through loop devices set up after
    /// boot -- never as block devices at boot: every machine's disk carries
    /// the base's filesystem label, so the rescue could come up on the
    /// damaged disk. The damaged machine stays repair-marked (no start, no
    /// remove) throughout; the throwaway is removed afterwards either way.
    // @port ACAppDelegate.deepRepairKubeMachineDisks(_: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) h=8d6dbd8cdffa8a36 @4ae141ef
    func deepRepairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) async throws {
        let name = m.record.name, ownerID = m.ownerID, id = Self.vmID(m.record.id)
        guard let daemon else { throw KubeClusterEngine.KubeError.message("the daemon is stopping") }
        // A rescue an earlier repair couldn't remove holds the folder: gone first.
        guard await daemon.removeStaleRescues(for: id),
              let images = await daemon.kubeMachineDiskImages(id: id) else {
            throw KubeClusterEngine.KubeError.message("\(name) is running or already being repaired")
        }
        let dir = (images[0] as NSString).deletingLastPathComponent
        let names = images.map { ($0 as NSString).lastPathComponent }
        try await daemon.repairMarks.whileMarked(id) {
            // Its own name (a leftover's can't collide) and its record marked
            // as this machine's rescue from the moment it's made.
            let rescueID = UUID()
            let rescue = KubeNodeRecord(id: rescueID, name: "rescue-\(name)-\(rescueID.uuidString.prefix(8).lowercased())",
                                        role: .agent, index: 0)
            rescueTargets[rescueID] = id
            defer { rescueTargets[rescueID] = nil }
            let scratch = KubeClusterEngine.ClusterRuntime(id: ownerID)   // keep it out of the cluster's node list
            do {
                _ = try await engine.bootMachine(KubeClusterEngine.MachineSpec(
                    ownerID: ownerID, record: rescue, cpus: 2, memoryGB: 2, dataDiskGB: nil,
                    comment: "Disk repair for \(name) — managed by Bromure, deleted when done.",
                    scripts: [], ipCommand: "hostname -I | awk '{print $1}'",
                    restoreSavedState: false, folders: [dir]), rt: scratch, repairAttempted: true)
                let args = names.map { "/mnt/bromure-share-1/\($0)" }.joined(separator: " ")
                let b64 = Data(KubeClusterEngine.rescueFsckScript.utf8).base64EncodedString()
                let out = try await engine.exec(rescue.id,
                    "echo \(b64) | base64 -d > /tmp/bromure-rescue-fsck.sh && bash /tmp/bromure-rescue-fsck.sh \(args); echo \"rc=$?\"",
                    timeout: 900)
                for line in out.split(separator: "\n") where line.hasPrefix("fsck:") { engine.log(ownerID, String(line)) }
                FileHandle.standardError.write(Data("[kube] rescue e2fsck for \(name):\n\(out)\n".utf8))
                await daemon.removeKubeMachine(id: Self.vmID(rescue.id))
                if !KubeClusterEngine.rescueRepaired(out, images: names, mayLackExt4: ["data.img"]) {
                    throw KubeClusterEngine.KubeError.message("e2fsck couldn't make \(name)'s disk consistent")
                }
            } catch {
                await daemon.removeKubeMachine(id: Self.vmID(rescue.id))
                throw error
            }
        }
    }

    // @port-skip linux-only: the daemon's shutdown of a cluster machine
    func stopKubeMachine(_ nodeID: UUID) async {
        await daemon?.stopKubeMachineVM(id: Self.vmID(nodeID), kill: false)
    }

    // @port-skip linux-only: the daemon's records follow the VM itself
    func kubeMachineStopped(_ nodeID: UUID) {}

    // @port-skip linux-only: forwards to the session host
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String {
        try await session.guestExec(profileID: profileID, command: command, timeout: timeout)
    }

    // @port-skip linux-only: forwards to the session host
    func guestFileOp(profileID: Profile.ID, op: [String: Any], timeout: Int) async throws -> [String: Any] {
        try await session.guestFileOp(profileID: profileID, op: op, timeout: timeout)
    }

    // @port ACAppDelegate.openKubeRelay(nodeID: UUID, target: String, completion: @escaping@Sendable(Int32)->Void) h=a0e0d84820001740 @e0cc8f0b
    func openKubeRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void) {
        guard let daemon else { completion(-1); return }
        let id = Self.vmID(nodeID)
        Task { completion(await daemon.kubeRelayFD(id: id, target: target)) }
    }

    // @port ACAppDelegate.refreshKubeAccessForRunningWorkspaces() h=cb265b5ee636d0b9 @d3ebbda2
    func refreshKubeAccessForRunningWorkspaces() {
        guard let daemon else { return }
        Task { await daemon.refreshWorkspaceKubeconfigs() }
    }

    // @port-skip linux-only: HostNetwork.primaryIPv4 on macOS
    func kubeHostIPv4() -> String? { Daemon.primaryIPv4() }

    // @port-skip linux-only: the load balancer's name for this host (macOS: "this Mac")
    var kubeHostDisplayName: String { "this server" }

    /// "a-b", CIDR or single dotted quads, comma-separated (≤ 1024 each),
    /// host order; nil on garbage (macOS: KubeLANPool.parse).
    // @port-skip linux-only: KubeLANPool.parse (KubeLANAnnouncer.swift is macOS-only)
    func parseKubeLANPool(_ text: String) -> [UInt32]? { Self.parsePool(text) }

    // @port-skip linux-only: KubeLANPool.parse
    nonisolated static func parsePool(_ text: String) -> [UInt32]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var out: [UInt32] = []
        for part in t.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let dash = p.firstIndex(of: "-") {
                guard let a = VMNetSwitch.parseIPv4(String(p[..<dash])),
                      let b = VMNetSwitch.parseIPv4(String(p[p.index(after: dash)...])),
                      a <= b, b - a < 1024 else { return nil }
                out.append(contentsOf: a...b)
            } else if let slash = p.firstIndex(of: "/") {
                guard let net = VMNetSwitch.parseIPv4(String(p[..<slash])),
                      let bits = Int(p[p.index(after: slash)...]), bits > 0, bits <= 32 else { return nil }
                let mask: UInt32 = bits == 32 ? 0xFFFF_FFFF : ~(0xFFFF_FFFF >> UInt32(bits))
                let base = net & mask, last = base | ~mask
                guard last - base < 1024 else { return nil }
                let lo = mask == 0xFFFF_FFFF ? base : base + 1
                let hi = mask == 0xFFFF_FFFF ? base : last - 1
                if lo <= hi { out.append(contentsOf: lo...hi) }
            } else {
                guard let a = VMNetSwitch.parseIPv4(p) else { return nil }
                out.append(a)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The cluster's Bromure load balancer: on a single-user server
    /// KubeLoadBalancer as macOS's (host listeners on 0.0.0.0), its LAN
    /// pool answered by the LAN helper (bromure-lan.service, macOS: the
    /// announcer) inside the admin's grant to this user; on a shared one no
    /// host ports at all (the user's decision): every LoadBalancer Service
    /// without a granted LAN address stays pending, saying so.
    // @port-skip linux-only: ACAppDelegate.makeKubeLoadBalancer's Linux counterpart
    func makeKubeLoadBalancer(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID,
                              serverIP: String, hostIP: String?, pool: [UInt32]) -> (any KubeServicePublisher)? {
        let multiUser = daemon?.config.multiUser == true
        let grant = (try? LANPoolsFile.load())?.addresses(ofUID: getuid()) ?? []
        let lanPool = Self.lanPool(cluster: pool, grant: grant, multiUser: multiUser,
                                   helperRunning: FileManager.default.fileExists(atPath: LANHelper.defaultSocket))
        if multiUser {
            guard let lanPool else { return SharedServerLoadBalancer() }
            return KubeLoadBalancer(engine: engine, clusterID: clusterID, serverNodeID: serverNodeID,
                                    serverIP: serverIP, hostIP: nil, pool: lanPool, lan: lanClient)
        }
        return KubeLoadBalancer(engine: engine, clusterID: clusterID, serverNodeID: serverNodeID,
                                serverIP: serverIP, hostIP: hostIP, pool: lanPool ?? pool, lan: lanPool == nil ? nil : lanClient)
    }

    /// The LAN addresses the cluster's Services may take through the LAN
    /// helper, or nil (none: no helper, or no grant). Shared server: the
    /// admin's grant to this user, which the cluster's lanPool, when set,
    /// narrows. Single-user server: the cluster's lanPool, within the
    /// grant, once the helper runs (it publishes only inside a grant);
    /// without one the pool's Services stay pending, as macOS's without an
    /// announcer.
    // @port-skip linux-only: the LAN helper's share of makeKubeLoadBalancer
    nonisolated static func lanPool(cluster pool: [UInt32], grant: Set<UInt32>, multiUser: Bool, helperRunning: Bool) -> [UInt32]? {
        if multiUser {
            let mine = pool.isEmpty ? grant.sorted() : pool.filter { grant.contains($0) }
            return mine.isEmpty ? nil : mine
        }
        guard helperRunning, !pool.isEmpty else { return nil }
        let mine = pool.filter { grant.contains($0) }
        return mine.isEmpty ? nil : mine
    }

    // @port-skip linux-only: the resource bundle's script (macOS: ACAppDelegate's lazy kubeNodeScriptURL)
    var kubeNodeScriptURL: URL? { acResourceBundle.url(forResource: "vm-setup/bromure-k8s-node", withExtension: "sh") }
    // @port-skip linux-only: the resource bundle's script (macOS: ACAppDelegate's lazy kubeProbeScriptURL)
    var kubeProbeScriptURL: URL? { acResourceBundle.url(forResource: "vm-setup/bromure-k8s-probe", withExtension: "py") }
    // @port-skip linux-only: the resource bundle's script (macOS: ACAppDelegate's lazy kubeRegistryScriptURL)
    var kubeRegistryScriptURL: URL? { acResourceBundle.url(forResource: "vm-setup/bromure-registry", withExtension: "sh") }
    // @port-skip linux-only: the resource bundle's script (macOS: ACAppDelegate's lazy connectorScriptURL)
    var connectorScriptURL: URL? { acResourceBundle.url(forResource: "vm-setup/bromure-msgbridge", withExtension: "sh") }
    // @port-skip linux-only: the resource bundle's script (macOS: ACAppDelegate's lazy connectorRelayURL)
    var connectorRelayURL: URL? { acResourceBundle.url(forResource: "vm-setup/bromure-msgbridge", withExtension: "py") }

    /// The shared server's LAN helper connection, made on first use.
    // @port-skip linux-only: the daemon's client of bromure-lan
    private(set) lazy var lanClient = LANHelperClient(opener: { nodeID, header, done in
        MainActor.assumeIsolated {
            guard let engine = SessionStores.shared?.kubeEngine else { done(-1); return }
            engine.openRelay(nodeID: nodeID, target: header, completion: done)
        }
    })

    /// A deleted cluster's or registry's machines, ended and removed.
    // @port-skip linux-only: macOS removes them with the cluster's folder
    func removeMachines(ownedBy owner: UUID) async {
        await daemon?.removeKubeMachines(owner: owner)
    }
}

/// The machines whose disks the host is repairing: never started meanwhile
/// (Firecracker would attach disk.raw while the checker writes it). Marked
/// on the Daemon actor with its live/stopping check (kubeMachineDiskImages),
/// checked by `start` on the actor, unmarked however the repair ends.
// @port-skip linux-only: the Linux daemon's repair gate
final class RepairMarks: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    // @port-skip linux-only: the Linux daemon's repair gate
    init() {}

    /// False when `id` was marked already (a repair has it).
    // @port-skip linux-only: the Linux daemon's repair gate
    func insert(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }

    // @port-skip linux-only: the Linux daemon's repair gate
    func remove(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }

    // @port-skip linux-only: the Linux daemon's repair gate
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }

    /// Runs `body` for a machine already marked, and unmarks it however
    /// `body` ends (a throw too).
    // @port-skip linux-only: the Linux daemon's repair gate
    func whileMarked<T>(_ id: String, _ body: () async throws -> T) async rethrows -> T {
        defer { remove(id) }
        return try await body()
    }
}

extension Daemon {
    /// The cluster engine is up: every known cluster's MetalLB range is kept
    /// out of the DHCP at once. macOS reserves them once the switch is up,
    /// when a cluster starts; a restarted daemon here takes its clusters'
    /// nodes back running, so no start comes, and the range stayed open to
    /// the next VM's lease until one did.
    // @port-skip linux-only: the Linux daemon's moment for reserveKnownMetalLBRanges (its switch is up before the engine)
    @MainActor static func kubeEngineReady(_ kube: KubeClusterEngine) {
        kube.reserveKnownMetalLBRanges()
    }

    /// A cluster node's port may answer for its cluster's allocated
    /// LoadBalancer range (InterimSwitch.speaksAsItself); a cluster with none
    /// allocated (yet, or any more), nothing.
    // @port-skip linux-only: the Linux switch's source pinning for a cluster's nodes
    func allowLoadBalancerClaims(_ rec: VMRecord) async {
        guard let cluster = rec.kube else { return }
        let text = await MainActor.run {
            SessionStores.shared?.kube.clusters.first { $0.id.uuidString.caseInsensitiveCompare(cluster) == .orderedSame }?.metallbRange
        }
        let parts = (text ?? "").split(separator: "-").map(String.init)
        guard parts.count == 2, let a = VMNetSwitch.parseIPv4(parts[0]), let b = VMNetSwitch.parseIPv4(parts[1]), a <= b
        else { sw.withdrawReservedClaims(mac: rec.mac); return }
        sw.allowReservedClaims(mac: rec.mac, cluster: cluster, range: a...b)
    }

    /// The running cluster nodes' claims, kept in step with their clusters'
    /// ranges: the engine reserves a cluster's range once its nodes are up
    /// (after they attached), and releases it when the cluster goes.
    // @port-skip linux-only: the Linux switch's source pinning for a cluster's nodes
    func startLoadBalancerClaimRefresh() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.refreshLoadBalancerClaims()
            }
        }
    }

    // @port-skip linux-only: the Linux switch's source pinning for a cluster's nodes
    func refreshLoadBalancerClaims() async {
        for rec in registry.records where rec.kube != nil && live[rec.id] != nil {
            await allowLoadBalancerClaims(rec)
        }
    }
}
