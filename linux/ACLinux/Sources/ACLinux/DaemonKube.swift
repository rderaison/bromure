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
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/k8s"): h=dde246cbd63efa97 @7dd92fdf
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

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/k8s"): h=f99ca82a9e3186a6 @7dd92fdf
    func kubeCreate(_ doc: [String: Any]) async -> ControlResponse {
        var doc = doc
        if doc["action"] == nil { doc["action"] = "create" }
        let result = await MainActor.run { [doc] in Self.kubeCommand(id: nil, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    /// `POST /k8s/{id}/{action}` (fat-client cluster verbs).
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case (let m, let p) where p.hasPrefix("/k8s/"): h=ecf14d0915d2df82 @7dd92fdf
    func kubeCommand(_ method: String, _ path: String, _ doc: [String: Any]) async -> ControlResponse {
        let rest = String(path.dropFirst("/k8s/".count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        let id = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
        var doc = doc
        if parts.count > 1, !parts[1].isEmpty { doc["action"] = parts[1] }
        if method == "DELETE" { doc["action"] = "delete" }
        let result = await MainActor.run { [doc] in Self.kubeCommand(id: id, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/registries"): h=a2c8ce826a1eaa9a @7dd92fdf
    func registryCreate(_ doc: [String: Any]) async -> ControlResponse {
        var doc = doc
        if doc["action"] == nil { doc["action"] = "create" }
        let result = await MainActor.run { [doc] in Self.registryCommand(id: nil, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case (let m, let p) where p.hasPrefix("/registries/"): h=52a7426dba2a3e85 @7dd92fdf
    func registryCommand(_ method: String, _ path: String, _ doc: [String: Any]) async -> ControlResponse {
        let rest = String(path.dropFirst("/registries/".count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        let id = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
        var doc = doc
        if parts.count > 1, !parts[1].isEmpty { doc["action"] = parts[1] }
        if method == "DELETE" { doc["action"] = "delete" }
        let result = await MainActor.run { [doc] in Self.registryCommand(id: id, doc: doc) }
        return ControlResponse((result["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: result) ?? .object([:]))
    }

    /// A fat-client cluster verb (`POST /k8s` "create", or `POST
    /// /k8s/{id}/{action}`) on the engine.
    // partial: a deleted cluster's machines are removed here (macOS: with the cluster's folder)
    // @port ACAppDelegate.automationKubeCommand(id: String?, doc: [String:Any]) h=ccdfe10f6c32148f @32a528c5
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

    // MARK: The machines, actor side

    /// A cluster machine's record, made (stopped) if it has none, with its
    /// data disk and the scripts it runs in its meta share; a suspended one
    /// that may not resume is shut down (its snapshot dropped).
    // @port-skip linux-only: the daemon side of LinuxKubeHost.startKubeMachine
    func prepareKubeMachine(id: String, name: String, owner: UUID, cpus: Int, memoryMiB: Int,
                            dataDiskGB: Int?, scripts: [(String, URL)], resume: Bool) async throws {
        if registry.find(id) == nil {
            let r = await createVM(.object(["name": .string(name), "cpus": .number(Double(cpus)),
                                            "memoryGB": .number(Double(memoryMiB) / 1024)]),
                                   id: id, boot: false, kube: owner.uuidString.lowercased(), dataDiskGB: dataDiskGB)
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

    /// Boot (or resume) a cluster machine; nil when it runs, else why not.
    /// Already running (a restarted daemon took it back): nothing to do.
    // @port-skip linux-only: the daemon side of LinuxKubeHost.startKubeMachine
    func startKubeMachineVM(id: String) async -> String? {
        guard let rec = registry.find(id) else { return "no machine" }
        if live[id] != nil { return nil }
        let r = await start(rec)
        return r.status == 200 ? nil : (r.body["error"]?.stringValue ?? "didn't start")
    }

    /// Shut a cluster machine down (`kill`: at once).
    // @port-skip linux-only: the daemon side of LinuxKubeHost.stopKubeMachine
    func stopKubeMachineVM(id: String, kill: Bool) async {
        guard let rec = registry.find(id) else { return }
        if kill { try? FileManager.default.removeItem(atPath: snapshotDir(id)) }
        _ = await deleteVM(rec, action: kill ? "kill" : "stop")
    }

    /// Every machine `owner` (a deleted cluster or registry) had: ended and removed.
    // @port-skip linux-only: macOS removes them with the cluster's folder
    func removeKubeMachines(owner: UUID) async {
        let key = owner.uuidString.lowercased()
        for rec in registry.records where rec.kube == key {
            if live[rec.id] != nil { _ = await deleteVM(rec, action: "kill") }
            if let r = registry.find(rec.id) { _ = remove(r) }
        }
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

/// The engine's machine host on a Linux server (macOS: ACAppDelegate,
/// KubeClusterEngine+VZ.swift): each machine a VM record of this daemon.
// @port-skip linux-only: the daemon's KubeEngineHost (macOS: ACAppDelegate)
@MainActor
final class LinuxKubeHost: KubeEngineHost {
    static var shared: LinuxKubeHost?
    private weak var daemon: Daemon?
    private let session: LinuxSessionHost

    // @port-skip linux-only: daemon wiring
    init(daemon: Daemon, session: LinuxSessionHost) {
        self.daemon = daemon
        self.session = session
    }

    /// The host's handle on a machine: its spec, for the start.
    final class Machine {
        let spec: KubeClusterEngine.MachineSpec
        // @port-skip linux-only: LinuxKubeHost's handle
        init(_ spec: KubeClusterEngine.MachineSpec) { self.spec = spec }
    }

    // @port-skip linux-only: VM ids are lowercased UUIDs
    private static func vmID(_ nodeID: UUID) -> String { nodeID.uuidString.lowercased() }

    // partial: the record is made at start (the daemon's createVM is async); a boot-time filesystem failure isn't detected on Linux yet
    // @port ACAppDelegate.makeKubeMachine(_: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime, fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) h=c08c904270224b9d @e0cc8f0b
    func makeKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                         fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) throws {
        for (name, url) in m.scripts where url == nil {
            throw KubeClusterEngine.KubeError.message("\(name) missing from the resources")
        }
        guard m.folders.isEmpty else {
            throw KubeClusterEngine.KubeError.message("\(m.record.name): shared folders aren't available for cluster machines on Linux yet")
        }
        runtime.machine = Machine(m)
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
                                            resume: m.restoreSavedState && !repairAttempted)
        if let why = await daemon.startKubeMachineVM(id: id) {
            throw KubeClusterEngine.KubeError.message("\(m.record.name): \(why)")
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

    // partial: no host-side disk repair on Linux yet
    // @port ACAppDelegate.repairKubeMachineDisks(_: KubeClusterEngine.MachineSpec) h=963ec6e7efbbfc72 @e0cc8f0b
    func repairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec) async -> Bool { false }

    // partial: refused (no e2fsck rescue on Linux yet)
    // @port ACAppDelegate.deepRepairKubeMachineDisks(_: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) h=e0bac9aee8e9dff0 @e0cc8f0b
    func deepRepairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) async throws {
        throw KubeClusterEngine.KubeError.message("\(m.record.name): disk repair isn't available on this Linux server yet")
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

    // partial: kubeconfigs aren't staged into workspaces on Linux yet (round b)
    // @port-skip linux-only: ACAppDelegate.refreshKubeAccessForRunningWorkspaces's Linux stand-in
    func refreshKubeAccessForRunningWorkspaces() {}

    // @port-skip linux-only: HostNetwork.primaryIPv4 on macOS
    func kubeHostIPv4() -> String? { Daemon.primaryIPv4() }

    /// "a-b", CIDR or single dotted quads, comma-separated (≤ 1024 each),
    /// host order; nil on garbage (macOS: KubeLANPool.parse).
    // @port-skip linux-only: KubeLANPool.parse (KubeLANAnnouncer.swift is macOS-only)
    func parseKubeLANPool(_ text: String) -> [UInt32]? { Self.parsePool(text) }

    // @port-skip linux-only: KubeLANPool.parse
    static func parsePool(_ text: String) -> [UInt32]? {
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

    // partial: no Bromure load balancer on Linux yet (round b): LoadBalancer services stay pending
    // @port-skip linux-only: KubeLoadBalancer is macOS-only for now
    func makeKubeLoadBalancer(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID,
                              serverIP: String, hostIP: String?, pool: [UInt32]) -> (any KubeServicePublisher)? { nil }

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

    /// A deleted cluster's or registry's machines, ended and removed.
    // @port-skip linux-only: macOS removes them with the cluster's folder
    func removeMachines(ownedBy owner: UUID) async {
        await daemon?.removeKubeMachines(owner: owner)
    }
}
