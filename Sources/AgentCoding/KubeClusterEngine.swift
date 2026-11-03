import Foundation
import SandboxEngine

// MARK: - Kubernetes cluster engine (host side)
//
// Boots the node VMs of a `KubeCluster` next to the workspaces, provisions
// k3s (+ Longhorn / MetalLB) inside them over the vsock shell channel, keeps
// a status probe running, publishes LoadBalancer services on the Mac's LAN
// address, and hands every allowed workspace the cluster's kubeconfig.
//
// A node is a *synthetic profile* (never in `ACAppDelegate.profiles`, so it
// never shows up as a workspace) booted through the same SessionDisk +
// UbuntuSandboxVM path as a workspace, registered in `runningSessions` so the
// CLI (`vm exec k8s-dev-1 -- kubectl get nodes`), the forward resolver and
// the quit drain all see it. Node state lives under
// ~/Library/Application Support/BromureAC/kube/<cluster-id>/nodes/<node-id>/.

/// What the cluster engine needs from the machine host: booting and
/// stopping the managed machines (nodes, registries, the connector),
/// reaching into them, and the scripts they run (macOS: ACAppDelegate over
/// UbuntuSandboxVM, KubeClusterEngine+VZ.swift; the Linux daemon: its VM
/// records).
@MainActor
protocol KubeEngineHost: AnyObject {
    /// Make the machine (its disks) and wire it: its IP to `runtime.ip`,
    /// its stop to `engine.nodeStopped`, a boot dying on filesystem errors
    /// to `fsFailure`. Sets `runtime.machine`. Nothing runs yet.
    func makeKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                         fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) throws
    /// Lay it out (home, meta share with `m.scripts`) and start it —
    /// resuming its saved state when allowed — registered with the host so
    /// its shell channel, the proxy and the CLI see it. Returns once started
    /// (not yet answering).
    func startKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                          repairAttempted: Bool, engine: KubeClusterEngine) async throws
    /// The machine's shell channel has a connection (the boot signal).
    func kubeMachineAnswers(_ nodeID: UUID) -> Bool
    /// The machine's IP, once known, for the host's own records.
    func setKubeMachineIP(_ nodeID: UUID, _ ip: String)
    /// Take a machine wedged at boot down for a disk repair, forgetting
    /// any saved state.
    func stopKubeMachineForRepair(_ runtime: KubeClusterEngine.NodeRuntime) async
    /// Quick repair of the machine's disks (journal replay, error flags).
    /// True when every disk came out clean or repaired.
    func repairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec) async -> Bool
    /// The full e2fsck, for damage the quick repair can't fix.
    func deepRepairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) async throws
    /// Shut the machine down.
    func stopKubeMachine(_ nodeID: UUID) async
    /// The machine stopped: drop the host's records of it.
    func kubeMachineStopped(_ nodeID: UUID)
    func guestExec(profileID: Profile.ID, command: String, timeout: Int) async throws -> String
    func guestFileOp(profileID: Profile.ID, op: [String: Any], timeout: Int) async throws -> [String: Any]
    /// A connection to `target` ("ip:port") from inside the machine (its
    /// loopback relay): the host-side fd to splice, or -1.
    func openKubeRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void)
    /// The workspaces' kubeconfigs changed: restage the running ones.
    func refreshKubeAccessForRunningWorkspaces()
    /// This host's LAN IPv4 (where LoadBalancer services are answered).
    func kubeHostIPv4() -> String?
    /// A cluster's LAN address pool ("a-b", CIDR or single addresses),
    /// host order; nil on garbage.
    func parseKubeLANPool(_ text: String) -> [UInt32]?
    /// The cluster's Bromure load balancer; nil where the host has none.
    func makeKubeLoadBalancer(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID,
                              serverIP: String, hostIP: String?, pool: [UInt32]) -> (any KubeServicePublisher)?
    var kubeNodeScriptURL: URL? { get }
    var kubeProbeScriptURL: URL? { get }
    var kubeRegistryScriptURL: URL? { get }
    var connectorScriptURL: URL? { get }
    var connectorRelayURL: URL? { get }
}

/// A cluster's LoadBalancer services, published on the host (macOS:
/// KubeLoadBalancer).
@MainActor
protocol KubeServicePublisher: AnyObject {
    /// The host address services are answered on when they have no pool IP.
    var hostIP: String? { get }
    /// Bring the listeners in line with `services`; their endpoints.
    func reconcile(services: [KubeProbe.Service]) -> [KubeLBEndpoint]
    func stopAll()
}

@MainActor
final class KubeClusterEngine {
    unowned let host: any KubeEngineHost
    let store: KubeClusterStore
    /// Where clusters keep their nodes, kubeconfigs and secrets.
    let rootDirectory: URL

    var runtimes: [UUID: ClusterRuntime] = [:]
    /// Clusters (and registries) whose dashboard is on screen: full probes
    /// on a fast cadence.
    var watched: Set<UUID> = []
    private var startedAutoClusters = false
    /// Connector (MessagingConnectorEngine.swift): a message from the user
    /// on Signal, WhatsApp or Slack, already checked to be theirs.
    var onConnectorMessage: ((ConnectorChannel.Kind, String) -> Void)?
    /// Recently sent replies, so their echo in a linked self-chat isn't
    /// read back as the user speaking.
    var connectorEchoes: Set<String> = [] {
        didSet { if connectorEchoes.count > 200 { connectorEchoes.removeAll() } }
    }
    /// Slack pairing under way: the one-time code the user sends the app in
    /// a direct message, and until when it's good. Never persisted.
    var slackPairing: (code: String, until: Date)?
    /// Direct messages with a wrong code while pairing: past a handful the
    /// pairing is called off (someone may be guessing).
    var slackPairingMisses = 0
    /// Set when pairing was called off for too many wrong codes.
    var slackPairingAborted = false

    init(host: any KubeEngineHost, store: KubeClusterStore, rootDirectory: URL? = nil) {
        self.host = host
        self.store = store
        self.rootDirectory = rootDirectory ?? KubeClusterStore.defaultDirectory
        for c in store.clusters { store.setStatus(c.id) { $0.phase = .stopped } }
    }

    // MARK: Paths

    func clusterDirectory(_ id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The node VMs' own ProfileStore — disks, homes and meta shares live
    /// under the cluster folder, never among the workspaces.
    func nodeStore(_ id: UUID) -> ProfileStore {
        ProfileStore(rootDir: clusterDirectory(id).appendingPathComponent("nodes", isDirectory: true))
    }

    func kubeconfigURL(_ id: UUID) -> URL {
        clusterDirectory(id).appendingPathComponent("kubeconfig.yaml")
    }

    // MARK: Runtime types

    final class NodeRuntime {
        let record: KubeNodeRecord
        /// The host's handle on the machine (macOS: its UbuntuSandboxVM).
        var machine: AnyObject?
        var ip: String?
        var up = false
        init(record: KubeNodeRecord) { self.record = record }
    }

    final class ClusterRuntime {
        let id: UUID
        var nodes: [UUID: NodeRuntime] = [:]
        var lifecycleTask: Task<Void, Never>?
        var probeTask: Task<Void, Never>?
        var loadBalancer: (any KubeServicePublisher)?
        var direct: KubeDirectCluster?
        /// Services already stamped with the host IP (ns/name).
        var patchedServices: Set<String> = []
        /// The base URL each cloud emulator was last told to put in the URLs it returns.
        var emulatorBaseURLs: [KubeCloudEmulator: String] = [:]
        /// VM-network addresses applied on the control-plane node for
        /// `bromure.io/scope: vm` Services (ns/name → ip), this boot.
        var vmScopeApplied: [String: String] = [:]
        var stopping = false
        init(id: UUID) { self.id = id }
    }

    func runtime(_ id: UUID) -> ClusterRuntime {
        if let rt = runtimes[id] { return rt }
        let rt = ClusterRuntime(id: id)
        runtimes[id] = rt
        return rt
    }

    // MARK: Public lifecycle

    /// Create the record and kick off provisioning. Returns the new cluster
    /// (already in the store, phase `.creating`).
    @discardableResult
    func create(name: String, spec: KubeClusterSpec, access: KubeWorkspaceAccess,
                autoStart: Bool = true, synologyPassword: String? = nil) -> KubeCluster {
        let clean = spec.clamped
        var cluster = KubeCluster(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  spec: clean, access: access, autoStart: autoStart)
        if cluster.name.isEmpty { cluster.name = "cluster" }
        // Unique slugs: node hostnames and kubeconfig contexts derive from it.
        let taken = Set(store.clusters.map(\.slug))
        if taken.contains(cluster.slug) {
            var n = 2
            while taken.contains(KubeCluster.slug(for: "\(cluster.name) \(n)")) { n += 1 }
            cluster.name = "\(cluster.name) \(n)"
        }
        cluster.nodes = (1...clean.nodeCount).map { i in
            KubeNodeRecord(name: cluster.nodeName(index: i), role: i == 1 ? .server : .agent, index: i)
        }
        store.upsert(cluster)
        if let pw = synologyPassword, clean.synology?.isConfigured == true {
            storeSynologyPassword(pw, for: cluster.id)
        }
        store.setStatus(cluster.id) { $0 = KubeClusterStatus(); $0.phase = .creating }
        let id = cluster.id
        let rt = runtime(id)
        rt.lifecycleTask = Task { [weak self] in await self?.provision(id) }
        return cluster
    }

    // MARK: Synology credentials (encrypted at rest, like profile secrets)

    private func synologySecretURL(_ id: UUID) -> URL {
        clusterDirectory(id).appendingPathComponent("synology.enc")
    }

    func storeSynologyPassword(_ password: String, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: clusterDirectory(id), withIntermediateDirectories: true)
            let blob = try SecretsVault.encrypt(Data(password.utf8))
            try blob.write(to: synologySecretURL(id), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                                   ofItemAtPath: synologySecretURL(id).path)
        } catch {
            log(id, "Couldn't store the NAS password: \(error.localizedDescription)")
        }
    }

    func synologyPassword(for id: UUID) -> String? {
        guard let blob = try? Data(contentsOf: synologySecretURL(id)),
              let plain = try? SecretsVault.decrypt(blob) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Change the NAS credentials of a provisioned cluster: re-run the
    /// Synology add-on step (refreshes the driver's Secret).
    func updateSynology(_ id: UUID, spec: KubeSynologySpec, password: String?) {
        guard var cluster = store.cluster(id) else { return }
        cluster.spec.synology = spec.isConfigured ? spec : nil
        store.upsert(cluster)
        if let password, !password.isEmpty { storeSynologyPassword(password, for: id) }
        guard store.status(id).phase == .running, spec.isConfigured, let server = cluster.server else { return }
        let rt = runtime(id)
        rt.lifecycleTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runAddons(cluster, server: server, storage: cluster.spec.needsISCSI ? "1" : "0", emulators: false)
                self.log(id, "✓ Synology CSI credentials updated.")
            } catch {
                self.log(id, "✗ Synology update failed: \(error.localizedDescription)")
            }
        }
    }

    func start(_ id: UUID) {
        guard let cluster = store.cluster(id) else { return }
        let phase = store.status(id).phase
        guard !phase.isBusy, !phase.isUp else { return }
        let rt = runtime(id)
        rt.stopping = false
        if cluster.provisioned {
            store.setStatus(id) { $0.phase = .starting; $0.message = nil; $0.log = []; $0.step = nil }
            rt.lifecycleTask = Task { [weak self] in await self?.boot(id) }
        } else {
            store.setStatus(id) { $0.phase = .creating; $0.message = nil; $0.log = []; $0.step = nil }
            rt.lifecycleTask = Task { [weak self] in await self?.provision(id) }
        }
    }

    func stop(_ id: UUID) async {
        guard let rt = runtimes[id] else {
            store.setStatus(id) { $0.phase = .stopped }
            return
        }
        rt.stopping = true
        rt.lifecycleTask?.cancel()
        rt.probeTask?.cancel()
        rt.probeTask = nil
        rt.loadBalancer?.stopAll()
        rt.loadBalancer = nil
        store.setStatus(id) { $0.phase = .stopping; $0.step = nil; $0.lbEndpoints = [] }
        log(id, "Stopping cluster…")
        // Agents first so the control plane sees clean node departures.
        let ordered = rt.nodes.values.sorted { ($0.record.role == .server ? 1 : 0) < ($1.record.role == .server ? 1 : 0) }
        for node in ordered {
            await quiesceForShutdown(node.record.id)
            await host.stopKubeMachine(node.record.id)
            node.up = false
        }
        rt.nodes.removeAll()
        rt.patchedServices.removeAll()
        store.setStatus(id) { $0.phase = .stopped; $0.nodesUp = 0; $0.probe = nil; $0.startedAt = nil }
        log(id, "Cluster stopped.")
        rt.stopping = false
    }

    func restart(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.stop(id)
            self.start(id)
        }
    }

    func delete(_ id: UUID) async {
        guard let cluster = store.cluster(id) else { return }
        await stop(id)
        store.setStatus(id) { $0.phase = .deleting }
        if let range = cluster.metallbRange { unreserveMetalLBRange(range) }
        for node in cluster.nodes { MACBindings.shared.release(profileID: node.id) }
        try? FileManager.default.removeItem(at: clusterDirectory(id))
        runtimes[id] = nil
        watched.remove(id)
        store.remove(id)
        pushKubeconfigsToWorkspaces()
    }

    func setAccess(_ id: UUID, _ access: KubeWorkspaceAccess) {
        guard var cluster = store.cluster(id) else { return }
        var resolved = access
        if case .only(let ids) = access, ids.isEmpty { resolved = .all }
        guard cluster.access != resolved else { return }
        cluster.access = resolved
        store.upsert(cluster)
        pushKubeconfigsToWorkspaces()
    }

    func setAutoStart(_ id: UUID, _ on: Bool) {
        guard var cluster = store.cluster(id), cluster.autoStart != on else { return }
        cluster.autoStart = on
        store.upsert(cluster)
    }

    /// Dashboard on screen → full probes every few seconds.
    func setWatch(_ id: UUID, _ on: Bool) {
        if on { watched.insert(id) } else { watched.remove(id) }
        if on, let rt = runtimes[id], rt.probeTask != nil {
            // Restart the loop so the first full probe lands immediately.
            if store.registry(id) != nil { startRegistryProbeLoop(id) }
            else if store.connector(id) != nil { startConnectorLoop(id) }
            else { startProbeLoop(id) }
        }
    }

    /// A workspace was deleted: prune it from the allow-lists.
    func workspaceDeleted(_ profileID: UUID) {
        store.workspaceDeleted(profileID)
    }

    /// Boot every cluster and registry marked to start with the app (once
    /// per launch). Registries first: clusters pick up their mirrors.
    func startAutoStartClusters() {
        guard !startedAutoClusters else { return }
        startedAutoClusters = true
        for r in store.registries where r.autoStart && r.provisioned { startRegistry(r.id) }
        for c in store.connectors where c.autoStart && c.provisioned { startConnector(c.id) }
        for c in store.clusters where c.autoStart && c.provisioned { start(c.id) }
    }

    /// Whether `profileID` is one of our node / registry VMs.
    func isNode(_ profileID: UUID) -> Bool {
        store.clusters.contains { $0.nodes.contains { $0.id == profileID } }
            || store.registries.contains { $0.node.id == profileID }
            || store.connectors.contains { $0.node.id == profileID }
    }

    // MARK: Workspace integration

    /// The direct-access kubeconfig entries a workspace gets (every
    /// provisioned cluster its access list allows).
    func directClusters(for profileID: UUID) -> [KubeDirectCluster] {
        store.clusters(for: profileID).compactMap { cluster in
            guard cluster.provisioned else { return nil }
            if let live = runtimes[cluster.id]?.direct { return live }
            return loadDirect(cluster)
        }
    }

    /// Node addresses the workspace must reach WITHOUT the cooperative proxy
    /// (kubectl honours HTTPS_PROXY, and the host-side MITM can't dial into
    /// the VM subnet).
    func extraNoProxy(for profileID: UUID) -> [String] {
        var out: [String] = []
        if let subnet = VMNetSwitch.shared.subnet { out.append(subnet.cidrString) }
        for cluster in store.clusters(for: profileID) {
            for node in cluster.nodes {
                if let ip = node.lastIP, !ip.isEmpty { out.append(ip) }
            }
        }
        for registry in store.registries(for: profileID) {
            if let ip = registry.node.lastIP, !ip.isEmpty { out.append(ip) }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// "<ip>:<port>" of every provisioned registry this workspace may push to.
    func registryAddresses(for profileID: UUID) -> [String] {
        store.registries(for: profileID).compactMap { $0.provisioned ? $0.address : nil }
    }

    /// containerd mirror config for every provisioned registry (clusters
    /// trust all of them — registries are shared machines).
    func registriesYAMLBase64() -> String {
        let addresses = store.registries.compactMap { $0.provisioned ? $0.address : nil }
        return Data(KubeRegistriesConfig.yaml(addresses: addresses).utf8).base64EncodedString()
    }

    /// A registry appeared, moved or went away: rewrite registries.yaml on
    /// every node of every running cluster (k3s restarts to reload it).
    func pushRegistriesToClusters() {
        let b64 = registriesYAMLBase64()
        for cluster in store.clusters where store.status(cluster.id).phase == .running {
            guard let rt = runtimes[cluster.id] else { continue }
            let id = cluster.id
            for node in cluster.nodes where rt.nodes[node.id]?.up == true {
                Task { [weak self] in
                    do { try await self?.runStep(id, node: node, step: "registries", args: [b64]) }
                    catch { self?.log(id, "Registry mirrors on \(node.name): \(error.localizedDescription)") }
                }
            }
        }
    }

    /// Standalone kubeconfig text for one cluster (Copy button, remote hand-off).
    func kubeconfigYAML(_ id: UUID) -> String? {
        guard let cluster = store.cluster(id) else { return nil }
        if let live = runtimes[id]?.direct { return live.standaloneYAML }
        return loadDirect(cluster)?.standaloneYAML
    }

    private func loadDirect(_ cluster: KubeCluster) -> KubeDirectCluster? {
        guard let yaml = try? String(contentsOf: kubeconfigURL(cluster.id), encoding: .utf8),
              let ip = cluster.serverIP else { return nil }
        return KubeDirectCluster.fromK3sYAML(yaml, contextName: cluster.contextName, serverIP: ip)
    }

    func pushKubeconfigsToWorkspaces() {
        host.refreshKubeAccessForRunningWorkspaces()
    }

    // MARK: Logging

    func log(_ id: UUID, _ line: String) {
        store.setStatus(id) { $0.appendLog(line) }
        FileHandle.standardError.write(Data("[k8s] \(line)\n".utf8))
        let url = clusterDirectory(id).appendingPathComponent("setup.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data("\(line)\n".utf8))
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: clusterDirectory(id), withIntermediateDirectories: true)
            try? "\(line)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func step(_ id: UUID, _ text: String) {
        store.setStatus(id) { $0.step = text; $0.message = text }
        log(id, "▸ \(text)")
    }

    func fail(_ id: UUID, _ message: String) {
        store.setStatus(id) { $0.phase = .error; $0.message = message; $0.step = nil }
        log(id, "✗ \(message)")
    }

    // MARK: Provisioning

    private func provision(_ id: UUID) async {
        guard var cluster = store.cluster(id) else { return }
        let rt = runtime(id)
        log(id, "Creating “\(cluster.name)”: \(cluster.spec.nodeCount) node(s), \(cluster.spec.cpusPerNode) vCPU / \(cluster.spec.memoryGBPerNode) GB each"
            + (cluster.spec.storageEnabled ? ", Longhorn storage \(cluster.spec.storageDiskGB) GB per node" : "")
            + (cluster.spec.synology?.isConfigured == true ? ", Synology NAS \(cluster.spec.synology?.host ?? "")" : "")
            + cluster.spec.emulators.map { ", \($0.displayName)" }.joined()
            + ", load balancer: \(cluster.spec.loadBalancer.displayName)")
        do {
            try await bootAllNodes(&cluster, rt)
            guard let server = cluster.server, let serverIP = rt.nodes[server.id]?.ip else {
                throw KubeError.message("The control-plane node never reported an IP address")
            }

            if cluster.spec.loadBalancer == .metallb, cluster.metallbRange == nil {
                if let range = reserveMetalLBRange() {
                    cluster.metallbRange = range
                    store.upsert(cluster)
                    log(id, "Reserved \(range) for MetalLB on the VM network")
                } else {
                    log(id, "Couldn't reserve a MetalLB pool on the VM network — MetalLB skipped")
                }
            }

            let storage = cluster.spec.needsISCSI ? "1" : "0"
            let registries = registriesYAMLBase64()
            step(id, "Preparing \(cluster.nodes.count) node(s)")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for node in cluster.nodes {
                    group.addTask { @MainActor [weak self] in
                        try await self?.runStep(id, node: node, step: "prepare", args: [storage, registries])
                    }
                }
                try await group.waitForAll()
            }

            step(id, "Installing the k3s control plane on \(server.name)")
            let noProxy = Self.noProxyForNodes
            var flags = ["--disable servicelb"]
            if !cluster.spec.ingress { flags.append("--disable traefik") }
            try await runStep(id, node: server, step: "server",
                              args: [server.name, noProxy, flags.joined(separator: " ")])

            let token = try await exec(server.id, script("token"), timeout: 30)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw KubeError.message("k3s produced no join token") }

            let agents = cluster.nodes.filter { $0.role == .agent }
            if !agents.isEmpty {
                step(id, "Joining \(agents.count) worker node(s)")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for node in agents {
                        group.addTask { @MainActor [weak self] in
                            try await self?.runStep(id, node: node, step: "agent",
                                                    args: [node.name, serverIP, token, noProxy])
                        }
                    }
                    try await group.waitForAll()
                }
                step(id, "Waiting for every node to report Ready")
                let out = try await exec(server.id, script("wait-nodes \(cluster.nodes.count) 150"), timeout: 330)
                if !out.contains("ok") { throw KubeError.message("Not every node became Ready in time") }
            }

            var addons: [String] = []
            if cluster.spec.storageEnabled { addons.append("Longhorn storage") }
            if cluster.spec.synology?.isConfigured == true { addons.append("the Synology CSI driver") }
            if cluster.spec.loadBalancer == .metallb && cluster.metallbRange != nil { addons.append("MetalLB") }
            addons += cluster.spec.emulators.map { "the \($0.displayName)" }
            if !addons.isEmpty {
                step(id, "Installing " + addons.joined(separator: ", "))
                try await runAddons(cluster, server: server, storage: cluster.spec.storageEnabled ? "1" : "0")
            }

            step(id, "Collecting the cluster's kubeconfig")
            try await captureKubeconfig(cluster, rt: rt, serverIP: serverIP)
            cluster.provisioned = true
            store.upsert(cluster)
            markRunning(cluster, rt: rt, serverIP: serverIP)
            log(id, "✓ Cluster “\(cluster.name)” is ready.")
        } catch is CancellationError {
            log(id, "Provisioning cancelled.")
        } catch {
            // Nodes stay up so the problem can be inspected
            // (`bromure-ac vm exec k8s-<name>-1 -- journalctl -u k3s`).
            fail(id, "Provisioning failed: \(error.localizedDescription)")
        }
    }

    /// The add-ons step (Longhorn / MetalLB / Synology / the cloud
    /// emulators). Synology's DSM credentials are staged into the
    /// control-plane node's meta share only for the duration of the step.
    /// `emulators: false` leaves the emulators alone (a credentials refresh
    /// must not move them to a newer release).
    private func runAddons(_ cluster: KubeCluster, server: KubeNodeRecord, storage: String,
                           emulators: Bool = true) async throws {
        let id = cluster.id
        let metallb = (cluster.spec.loadBalancer == .metallb && cluster.metallbRange != nil) ? "1" : "0"
        var synology = "0"
        var staged: [URL] = []
        if let syn = cluster.spec.synology, syn.isConfigured {
            if let password = synologyPassword(for: id) {
                let nodes = nodeStore(id)
                let meta = nodes.profileDirectory(for: Profile(id: server.id, name: server.name, tool: .claude, authMode: .token))
                    .appendingPathComponent("meta-share", isDirectory: true)
                let info = meta.appendingPathComponent("synology-client-info.yml")
                let sc = meta.appendingPathComponent("synology-storage-class.yml")
                try syn.clientInfoYAML(password: password).write(to: info, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: info.path)
                try syn.storageClassesYAML().write(to: sc, atomically: true, encoding: .utf8)
                staged = [info, sc]
                if syn.protocolKind == .smb {
                    // SMB mounts need the DSM account as a node-stage secret.
                    let smb = meta.appendingPathComponent("synology-smb.json")
                    let doc: [String: String] = ["username": syn.username.trimmingCharacters(in: .whitespaces), "password": password]
                    try JSONSerialization.data(withJSONObject: doc).write(to: smb, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: smb.path)
                    staged.append(smb)
                }
                synology = "1"
            } else {
                log(id, "Synology NAS configured but no password stored — skipping the CSI driver")
            }
        }
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }
        var emulatorArgs: [String] = []
        if emulators {
            for kind in cluster.spec.emulators {
                emulatorArgs.append("\(kind.rawValue)=\(await emulatorImage(kind, for: cluster))")
            }
        }
        try await runStep(id, node: server, step: "addons", args: [
            storage, String(cluster.spec.storageReplicas), metallb,
            cluster.metallbRange ?? "-", cluster.spec.loadBalancer.rawValue, synology,
            emulatorArgs.isEmpty ? "-" : emulatorArgs.joined(separator: ","),
        ])
    }

    /// The image a cloud emulator gets: the owner's pin, else the latest
    /// release on Docker Hub right now, else Docker Hub's `latest` tag.
    /// Nothing is pinned in bromure itself.
    private func emulatorImage(_ kind: KubeCloudEmulator, for cluster: KubeCluster) async -> String {
        let id = cluster.id
        if let pinned = cluster.spec.emulatorImage(kind) {
            log(id, "\(kind.displayName): \(pinned) (pinned)")
            return pinned
        }
        if let tag = await KubeEmulatorReleases.latestTag(for: kind) {
            log(id, "\(kind.displayName): \(kind.project) \(tag), the latest release on Docker Hub")
            return kind.image(tag: tag)
        }
        log(id, "\(kind.displayName): couldn't look up the latest release on Docker Hub — using the latest tag")
        return kind.image(tag: "latest")
    }

    /// Boot an already-provisioned cluster.
    private func boot(_ id: UUID) async {
        guard var cluster = store.cluster(id) else { return }
        let rt = runtime(id)
        log(id, "Starting “\(cluster.name)”…")
        do {
            let previousServerIP = cluster.serverIP
            try await bootAllNodes(&cluster, rt)
            guard let server = cluster.server, let serverIP = rt.nodes[server.id]?.ip else {
                throw KubeError.message("The control-plane node never reported an IP address")
            }
            if let prev = previousServerIP, prev != serverIP {
                log(id, "Control plane moved from \(prev) to \(serverIP) — repointing the workers")
                for node in cluster.nodes where node.role == .agent {
                    try await runStep(id, node: node, step: "repoint", args: [serverIP])
                }
            }
            step(id, "Waiting for the API server")
            var ready = false
            for _ in 0..<60 {
                try Task.checkCancellation()
                if let out = try? await exec(server.id, script("ready"), timeout: 15), out.contains("ready") {
                    ready = true
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard ready else { throw KubeError.message("The API server didn't come up") }
            try await captureKubeconfig(cluster, rt: rt, serverIP: serverIP)
            markRunning(cluster, rt: rt, serverIP: serverIP)
            log(id, "✓ Cluster “\(cluster.name)” is up.")
        } catch is CancellationError {
            log(id, "Start cancelled.")
        } catch {
            fail(id, "Start failed: \(error.localizedDescription)")
        }
    }

    private func markRunning(_ cluster: KubeCluster, rt: ClusterRuntime, serverIP: String) {
        let id = cluster.id
        store.setStatus(id) {
            $0.phase = .running
            $0.step = nil
            $0.message = nil
            $0.startedAt = Date()
            $0.hostIP = host.kubeHostIPv4()
        }
        if cluster.spec.loadBalancer == .bromure, let server = cluster.server {
            let hostIP = host.kubeHostIPv4()
            let pool = cluster.spec.lanPool.flatMap { host.parseKubeLANPool($0) } ?? []
            if hostIP == nil && pool.isEmpty {
                log(id, "This Mac has no LAN IPv4 address — LoadBalancer services stay pending")
            } else {
                rt.loadBalancer = host.makeKubeLoadBalancer(engine: self, clusterID: id, serverNodeID: server.id,
                                                            serverIP: serverIP, hostIP: hostIP, pool: pool)
                if !pool.isEmpty {
                    log(id, "LAN address pool: \(cluster.spec.lanPool ?? "") (\(pool.count) address(es), answered by ARP)")
                }
            }
        }
        startProbeLoop(id)
        pushKubeconfigsToWorkspaces()
        // A registry that came up while this cluster was still provisioning
        // (or since it last ran) isn't in its registries.yaml yet: converge
        // now. The step is a no-op when the file already matches.
        if store.registries.contains(where: \.provisioned) {
            let b64 = registriesYAMLBase64()
            for node in cluster.nodes where rt.nodes[node.id]?.up == true {
                Task { [weak self] in
                    do { try await self?.runStep(id, node: node, step: "registries", args: [b64]) }
                    catch { self?.log(id, "Registry mirrors on \(node.name): \(error.localizedDescription)") }
                }
            }
        }
    }

    // MARK: Node VMs

    private func bootAllNodes(_ cluster: inout KubeCluster, _ rt: ClusterRuntime) async throws {
        step(cluster.id, "Booting \(cluster.nodes.count) node VM(s)")
        try FileManager.default.createDirectory(at: clusterDirectory(cluster.id), withIntermediateDirectories: true)
        let snapshot = cluster
        try await withThrowingTaskGroup(of: (UUID, String).self) { group in
            for node in snapshot.nodes where rt.nodes[node.id] == nil {
                group.addTask { @MainActor [weak self] in
                    guard let self else { throw CancellationError() }
                    let ip = try await self.bootNode(snapshot, node, rt: rt)
                    return (node.id, ip)
                }
            }
            for try await (nodeID, ip) in group {
                if let i = cluster.nodes.firstIndex(where: { $0.id == nodeID }) { cluster.nodes[i].lastIP = ip }
            }
        }
        // Already-running nodes (a retry after a failed provisioning) keep
        // their known IP.
        for (nodeID, node) in rt.nodes {
            if let ip = node.ip, let i = cluster.nodes.firstIndex(where: { $0.id == nodeID }) {
                cluster.nodes[i].lastIP = ip
            }
        }
        store.upsert(cluster)
        store.setStatus(cluster.id) { $0.nodesUp = rt.nodes.values.filter(\.up).count }
        // The switch is certainly up now: keep every cluster's MetalLB pool
        // out of the DHCP allocator (idempotent).
        reserveKnownMetalLBRanges()
    }

    /// Boot one node and wait until its shell channel answers. Returns the
    /// guest's IP.
    private func bootNode(_ cluster: KubeCluster, _ node: KubeNodeRecord, rt: ClusterRuntime) async throws -> String {
        try await bootMachine(MachineSpec(
            ownerID: cluster.id, record: node, cpus: cluster.spec.cpusPerNode,
            memoryGB: cluster.spec.memoryGBPerNode,
            dataDiskGB: cluster.spec.storageEnabled ? cluster.spec.storageDiskGB : nil,
            comment: "Kubernetes node of cluster “\(cluster.name)” — managed by Bromure.",
            scripts: [("bromure-k8s-node.sh", host.kubeNodeScriptURL), ("bromure-k8s-probe.py", host.kubeProbeScriptURL)],
            ipCommand: "bash \(Self.scriptPath) ip",
            restoreSavedState: cluster.provisioned), rt: rt)
    }

    /// One managed VM: a cluster node or a registry.
    struct MachineSpec {
        let ownerID: UUID
        let record: KubeNodeRecord
        let cpus: Int
        let memoryGB: Int
        /// Under-a-gigabyte machines (the connector): wins over memoryGB.
        var memoryMB: Int? = nil
        let dataDiskGB: Int?
        let comment: String
        /// Files copied into the guest's read-only meta share.
        let scripts: [(String, URL?)]
        /// Guest command printing the VM's IPv4 (fallback for the outbox report).
        let ipCommand: String
        /// Resume the RAM snapshot the app saved when it quit, if there is
        /// one. Only for a machine that finished provisioning — a snapshot
        /// taken mid-provisioning is dropped and the machine boots fresh
        /// (provisioning is re-run from the top anyway).
        var restoreSavedState: Bool = true
        /// Host folders shared into the guest at /mnt/bromure-share-<N>.
        var folders: [String] = []
    }

    /// The console showed the machine's boot dying on filesystem errors.
    final class BootFSFailure: @unchecked Sendable {
        var detail: String?
    }

    /// Boot a managed VM and wait until its shell channel answers. Returns
    /// the guest's IP.
    func bootMachine(_ m: MachineSpec, rt: ClusterRuntime, repairAttempted: Bool = false) async throws -> String {
        let id = m.ownerID
        let node = m.record
        let runtime = NodeRuntime(record: node)
        // A boot-time fsck the guest's initramfs can't finish drops it to an
        // emergency shell nobody can answer; the host's console scanner
        // catches it and the wait below repairs the disks and boots again.
        let fsFailure = BootFSFailure()
        try host.makeKubeMachine(m, runtime: runtime, fsFailure: fsFailure, engine: self)
        rt.nodes[node.id] = runtime
        log(id, "Booting \(node.name)…")
        try await host.startKubeMachine(m, runtime: runtime, repairAttempted: repairAttempted, engine: self)

        // The shell agent dials out once agentd is up; the first pooled
        // connection is the boot signal.
        var alive = false
        for _ in 0..<360 {   // ≤ 3 minutes
            try Task.checkCancellation()
            if fsFailure.detail != nil { break }
            if host.kubeMachineAnswers(node.id),
               (try? await exec(node.id, "true", timeout: 10)) != nil {
                alive = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if let detail = fsFailure.detail, !alive {
            log(id, "✗ \(node.name) failed its boot-time filesystem check: \(detail)")
            // Out of the runtime first, so its stop isn't read as the
            // cluster losing a node.
            rt.nodes.removeValue(forKey: node.id)
            await host.stopKubeMachineForRepair(runtime)
            guard !repairAttempted else {
                throw KubeError.message("\(node.name)'s disk still fails its filesystem check after a repair")
            }
            step(id, "Repairing \(node.name)'s disks")
            if await !host.repairKubeMachineDisks(m) {
                // Damage past a journal replay / error-flag clear (a corrupt
                // inode, bad bitmaps): the real e2fsck -y.
                step(id, "Repairing \(node.name)'s disks with e2fsck")
                try await host.deepRepairKubeMachineDisks(m, engine: self)
            }
            return try await bootMachine(m, rt: rt, repairAttempted: true)
        }
        guard alive else { throw KubeError.message("\(node.name) never answered on its shell channel") }
        runtime.up = true

        // DHCP can take a while when several VMs boot at once: give the
        // lease up to two minutes, taking whichever lands first — the
        // guest's ip.txt report or a direct query.
        var ip = runtime.ip
        for _ in 0..<120 where ip == nil || ip?.isEmpty == true {
            try Task.checkCancellation()
            if let reported = runtime.ip, !reported.isEmpty { ip = reported; break }
            if let out = try? await exec(node.id, m.ipCommand, timeout: 10) {
                let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { ip = v; break }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let ip, !ip.isEmpty else { throw KubeError.message("\(node.name) got no IP address") }
        runtime.ip = ip
        host.setKubeMachineIP(node.id, ip)
        store.setStatus(id) { $0.nodesUp = rt.nodes.values.filter(\.up).count }
        log(id, "\(node.name) is up at \(ip)")
        return ip
    }

    /// Before the power button: stop what makes a machine's own shutdown
    /// hang. systemd waits on k3s's leftover containers (and a registry's
    /// docker) until its stop timeouts expire, so a node never powered off
    /// in time and was force-stopped with a dirty filesystem on every Stop.
    /// k3s-killall.sh (installed with k3s) stops k3s and every container and
    /// unmounts their volumes in seconds; then flush the disks.
    static let quiesceCommand = "sudo sh -c '"
        + "if [ -x /usr/local/bin/k3s-killall.sh ]; then /usr/local/bin/k3s-killall.sh >/dev/null 2>&1; fi; "
        + "if command -v docker >/dev/null 2>&1; then docker ps -q | xargs -r docker stop -t 10 >/dev/null 2>&1; fi; "
        + "sync'"

    func quiesceForShutdown(_ nodeID: UUID) async {
        _ = try? await exec(nodeID, Self.quiesceCommand, timeout: 90)
    }

    func nodeStopped(clusterID: UUID, nodeID: UUID, error: Error?) {
        host.kubeMachineStopped(nodeID)
        guard let rt = runtimes[clusterID], let node = rt.nodes[nodeID] else { return }
        node.up = false
        let phase = store.status(clusterID).phase
        if !rt.stopping, phase == .running || phase == .starting || phase == .creating {
            rt.probeTask?.cancel()
            rt.probeTask = nil
            rt.loadBalancer?.stopAll()
            rt.loadBalancer = nil
            rt.nodes.removeValue(forKey: nodeID)
            let remaining = rt.nodes.values.filter(\.up).count
            if remaining == 0 {
                store.setStatus(clusterID) { $0.phase = .stopped; $0.nodesUp = 0; $0.probe = nil; $0.lbEndpoints = [] }
                log(clusterID, "\(node.record.name) stopped\(error.map { ": \($0.localizedDescription)" } ?? "") — cluster is down.")
            } else {
                fail(clusterID, "\(node.record.name) stopped unexpectedly\(error.map { ": \($0.localizedDescription)" } ?? "")")
                store.setStatus(clusterID) { $0.nodesUp = remaining }
            }
        } else {
            store.setStatus(clusterID) { $0.nodesUp = rt.nodes.values.filter(\.up).count }
        }
    }

    /// Copy scripts into the VM's (read-only in the guest) meta share.
    /// Re-done after every `prepare()`, which wipes the share.
    static func stageScripts(_ files: [(String, URL?)], into profileDir: URL) throws {
        let meta = profileDir.appendingPathComponent("meta-share", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (name, url) in files {
            guard let url else { throw KubeError.message("\(name) missing from the app bundle") }
            let dest = meta.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest.path)
        }
    }

    static func ensureSparseImage(at url: URL, gigabytes: Int) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(gigabytes) * 1024 * 1024 * 1024)
    }

    // MARK: Guest exec + detached steps

    nonisolated static let scriptPath = "/mnt/bromure-meta/bromure-k8s-node.sh"
    private static let probePath = "/mnt/bromure-meta/bromure-k8s-probe.py"
    static let registryScriptPath = "/mnt/bromure-meta/bromure-registry.sh"
    /// Private ranges + cluster-internal names: node↔node and pod traffic
    /// must never go through the host proxy (which can't reach the VM LAN).
    static let noProxyForNodes = "localhost,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local"

    private func script(_ args: String) -> String { "bash \(Self.scriptPath) \(args)" }

    func exec(_ nodeID: UUID, _ command: String, timeout: Int) async throws -> String {
        try await host.guestExec(profileID: nodeID, command: command, timeout: timeout)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run `bromure-k8s-node.sh start <step> …` detached in the guest and
    /// poll its log into the cluster log until it exits.
    func runStep(_ id: UUID, node: KubeNodeRecord, step: String, args: [String],
                 scriptPath: String = KubeClusterEngine.scriptPath) async throws {
        let quoted = args.map(Self.shellQuote).joined(separator: " ")
        _ = try await exec(node.id, "bash \(scriptPath) start \(step) \(quoted)", timeout: 30)
        var offset = 0
        let started = Date()
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let out: String
            do {
                out = try await exec(node.id, "bash \(scriptPath) poll \(step) \(offset)", timeout: 30)
            } catch {
                if Date().timeIntervalSince(started) > 1800 { throw error }
                continue   // a transient shell-channel hiccup; the step keeps running
            }
            var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }
            let statusLine = lines.removeFirst()
            var exitCode: Int?
            if statusLine.hasPrefix("STATUS exit ") {
                exitCode = Int(statusLine.dropFirst("STATUS exit ".count).trimmingCharacters(in: .whitespaces))
            } else if statusLine.hasPrefix("STATUS missing") {
                throw KubeError.message("\(node.name): step \(step) never started")
            }
            if let first = lines.first, first.hasPrefix("OFFSET ") {
                lines.removeFirst()
                offset = Int(first.dropFirst("OFFSET ".count).trimmingCharacters(in: .whitespaces)) ?? offset
            }
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log(id, "[\(node.name)] \(line)")
            }
            if let exitCode {
                if exitCode == 0 { return }
                throw KubeError.message("\(node.name): \(step) failed (exit \(exitCode)) — see the log")
            }
            if Date().timeIntervalSince(started) > 2400 {
                throw KubeError.message("\(node.name): \(step) timed out")
            }
        }
    }

    private func captureKubeconfig(_ cluster: KubeCluster, rt: ClusterRuntime, serverIP: String) async throws {
        guard let server = cluster.server else { return }
        let yaml = try await exec(server.id, script("kubeconfig"), timeout: 30)
        guard let direct = KubeDirectCluster.fromK3sYAML(yaml, contextName: cluster.contextName, serverIP: serverIP) else {
            throw KubeError.message("Couldn't parse the cluster's kubeconfig")
        }
        rt.direct = direct
        let url = kubeconfigURL(cluster.id)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    // MARK: Probe loop

    private func startProbeLoop(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        rt.probeTask?.cancel()
        rt.probeTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let full = self.watched.contains(id) || first
                first = false
                await self.probeOnce(id, full: full)
                let interval: UInt64 = self.watched.contains(id) ? 4_000_000_000 : 15_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func probeOnce(_ id: UUID, full: Bool) async {
        guard let rt = runtimes[id], let cluster = store.cluster(id), let server = cluster.server,
              rt.nodes[server.id]?.up == true else { return }
        let cmd = "python3 \(Self.probePath)\(full ? " --full" : "")"
        guard let out = try? await exec(server.id, cmd, timeout: 45),
              let probe = KubeProbe.decode(Data(out.utf8)) else {
            store.setStatus(id) { $0.message = "Status probe failed" }
            return
        }
        let previous = store.status(id).probe
        let merged = probe.mergingDetails(from: previous)
        store.setStatus(id) {
            $0.probe = merged
            if $0.phase == .running { $0.message = nil }
        }
        if let lb = rt.loadBalancer, probe.reachable {
            // Public Services: host listeners / LAN pool. Private ones
            // (`bromure.io/scope: vm`): an address on the VM network.
            var endpoints = lb.reconcile(services: probe.loadBalancerServices)
            await reconcileVMScope(id, rt: rt, services: probe.loadBalancerServices, endpoints: &endpoints)
            endpoints.sort { ($0.namespace, $0.service, $0.port) < ($1.namespace, $1.service, $1.port) }
            store.setStatus(id) { $0.lbEndpoints = endpoints }
            await publishLoadBalancerIPs(id, rt: rt, services: probe.loadBalancerServices, endpoints: endpoints)
        }
    }

    /// `bromure.io/scope: vm` Services get an address from the cluster's
    /// VM-network pool (the twenty MetalLB would use), answered by the
    /// control-plane node itself (`patch-lb-vm` adds it to the node's NIC;
    /// kube-proxy already routes LoadBalancer ingress addresses) — reachable
    /// from every workspace and this Mac, invisible on the LAN. Assignments
    /// are read back from the Services' own status, so they survive restarts.
    private func reconcileVMScope(_ id: UUID, rt: ClusterRuntime, services: [KubeProbe.Service],
                                  endpoints: inout [KubeLBEndpoint]) async {
        guard var cluster = store.cluster(id), let server = cluster.server,
              cluster.spec.loadBalancer == .bromure else { return }
        let key = { (svc: KubeProbe.Service) in "\(svc.namespace)/\(svc.name)" }
        let vmServices = services.filter(\.isVMScoped)
        if !vmServices.isEmpty, cluster.metallbRange == nil, let range = reserveMetalLBRange() {
            cluster.metallbRange = range
            store.upsert(cluster)
            log(id, "Reserved \(range) on the VM network for private load balancers")
        }
        func pending(_ svc: KubeProbe.Service, _ error: String) -> [KubeLBEndpoint] {
            svc.ports.map { KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: $0.port, nodePort: $0.nodePort,
                                           protocolName: $0.protocolName, bound: false, error: error, scope: "vm") }
        }
        guard let range = cluster.metallbRange, let pool = host.parseKubeLANPool(range) else {
            for svc in vmServices { endpoints += pending(svc, "no VM-network pool") }
            return
        }
        // What the Services already hold from the pool.
        var taken: [String: UInt32] = [:]
        for svc in services {
            for ing in svc.ingress {
                if let ip = VMNetSwitch.parseIPv4(ing), pool.contains(ip) { taken[key(svc)] = ip }
            }
        }
        // Lost the annotation but still holds a private address: release it
        // (the public path takes over in this same cycle).
        for svc in services where !svc.isVMScoped {
            guard let ip = taken[key(svc)] else { continue }
            let ipStr = VMNetSwitch.ipString(ip)
            _ = try? await exec(server.id, script("clear-lb-vm \(Self.shellQuote(svc.namespace)) \(Self.shellQuote(svc.name)) \(ipStr)"), timeout: 20)
            rt.vmScopeApplied[key(svc)] = nil
            taken[key(svc)] = nil
            log(id, "Released \(ipStr) from \(key(svc)) (no longer private)")
        }
        for svc in vmServices {
            let k = key(svc)
            var ip = taken[k]
            if ip == nil {
                if let want = svc.lbIP, let w = VMNetSwitch.parseIPv4(want), pool.contains(w), !taken.values.contains(w) {
                    ip = w
                } else {
                    ip = pool.first { !taken.values.contains($0) }
                }
            }
            guard let ip else { endpoints += pending(svc, "VM-network pool exhausted"); continue }
            let ipStr = VMNetSwitch.ipString(ip)
            taken[k] = ip
            let inStatus = svc.ingress.contains(ipStr)
            if !inStatus || rt.vmScopeApplied[k] != ipStr {
                if (try? await exec(server.id, script("patch-lb-vm \(Self.shellQuote(svc.namespace)) \(Self.shellQuote(svc.name)) \(ipStr)"), timeout: 30)) != nil {
                    rt.vmScopeApplied[k] = ipStr
                    if !inStatus { log(id, "Published \(k) at \(ipStr) on the VM network (private)") }
                }
            }
            let bound = rt.vmScopeApplied[k] == ipStr
            for port in svc.ports {
                endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: port.port, nodePort: port.nodePort,
                                                protocolName: port.protocolName, bound: bound,
                                                error: bound ? nil : "couldn't publish on the node", ip: ipStr, scope: "vm"))
            }
        }
        // Services that are gone: drop their address from the node.
        let present = Set(services.map(key))
        for (k, ipStr) in rt.vmScopeApplied where !present.contains(k) {
            let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                _ = try? await exec(server.id, script("clear-lb-vm \(Self.shellQuote(parts[0])) \(Self.shellQuote(parts[1])) \(ipStr)"), timeout: 20)
            }
            rt.vmScopeApplied[k] = nil
        }
    }

    /// Stamp every LoadBalancer service that has at least one bound port with
    /// the host's LAN IP, the way a cloud controller would — kubectl then
    /// shows it as EXTERNAL-IP.
    private func publishLoadBalancerIPs(_ id: UUID, rt: ClusterRuntime, services: [KubeProbe.Service],
                                        endpoints: [KubeLBEndpoint]) async {
        guard let cluster = store.cluster(id), let server = cluster.server, let lb = rt.loadBalancer else { return }
        // The address each Service is answered on: its pool IP, else the Mac's.
        var publishIP: [String: String] = [:]
        for e in endpoints where e.bound && !e.isVMScoped {
            let key = "\(e.namespace)/\(e.service)"
            if publishIP[key] == nil, let ip = e.ip ?? lb.hostIP { publishIP[key] = ip }
        }
        for svc in services {
            let key = "\(svc.namespace)/\(svc.name)"
            if svc.isVMScoped {
                // Private: reconcileVMScope owns its status.
                rt.patchedServices.remove(key)
                continue
            }
            if let ip = publishIP[key] {
                if !svc.ingress.contains(ip) {
                    if (try? await exec(server.id, script("patch-lb \(Self.shellQuote(svc.namespace)) \(Self.shellQuote(svc.name)) \(ip)"), timeout: 20)) != nil {
                        rt.patchedServices.insert(key)
                        log(id, "Published \(key) at \(ip)")
                    }
                }
                // A cloud emulator puts a base URL in what it returns (SQS
                // queue URLs, presigned S3 URLs, blob endpoints…): make it
                // the published address, which workspaces, the Mac and the
                // LAN all reach.
                if let kind = KubeCloudEmulator.allCases.first(where: { $0.namespace == svc.namespace && $0.serviceName == svc.name }) {
                    let base = "http://\(ip):\(kind.port)"
                    if rt.emulatorBaseURLs[kind] != base,
                       (try? await exec(server.id, script("emulator-base-url \(kind.rawValue) \(base)"), timeout: 60)) != nil {
                        rt.emulatorBaseURLs[kind] = base
                        log(id, "\(kind.displayName) returns URLs on \(base)")
                    }
                }
            } else if !svc.ingress.isEmpty, rt.patchedServices.contains(key) {
                _ = try? await exec(server.id, script("clear-lb \(Self.shellQuote(svc.namespace)) \(Self.shellQuote(svc.name))"), timeout: 20)
                rt.patchedServices.remove(key)
            }
        }
    }

    // MARK: MetalLB pool reservation

    /// Carve twenty addresses off the top of the VM subnet for MetalLB and
    /// keep the switch's DHCP from ever leasing them.
    private func reserveMetalLBRange() -> String? {
        guard let subnet = VMNetSwitch.shared.subnet else { return nil }
        let base = subnet.network
        let first = base | 230, last = base | 249
        VMNetSwitch.shared.reserveIPs(Set(first...last))
        return "\(VMNetSwitch.ipString(first))-\(VMNetSwitch.ipString(last))"
    }

    private func unreserveMetalLBRange(_ range: String) {
        let parts = range.split(separator: "-").map(String.init)
        guard parts.count == 2, let a = VMNetSwitch.parseIPv4(parts[0]),
              let b = VMNetSwitch.parseIPv4(parts[1]), a <= b else { return }
        VMNetSwitch.shared.unreserveIPs(Set(a...b))
    }

    /// Re-reserve pools for existing clusters once the switch is up (the
    /// subnet is only known after the first VM boots).
    func reserveKnownMetalLBRanges() {
        for c in store.clusters {
            guard let range = c.metallbRange else { continue }
            let parts = range.split(separator: "-").map(String.init)
            guard parts.count == 2, let a = VMNetSwitch.parseIPv4(parts[0]),
                  let b = VMNetSwitch.parseIPv4(parts[1]), a <= b else { continue }
            VMNetSwitch.shared.reserveIPs(Set(a...b))
        }
    }

    // MARK: vsock relay (host listener → guest → service)

    /// Open a relay into `nodeID` that connects, inside the guest, to
    /// `target` ("ip:port"); returns the host-side fd to splice, or -1.
    func openRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void) {
        host.openKubeRelay(nodeID: nodeID, target: target, completion: completion)
    }

    enum KubeError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }
}

/// Retains VZVirtioSocketConnection objects until their spliced fd closes.
enum KubeRelayRetain {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [Int32: AnyObject] = [:]
    static func hold(_ obj: AnyObject, forFD fd: Int32) {
        lock.lock(); held[fd] = obj; lock.unlock()
    }
    static func release(fd: Int32) {
        lock.lock(); held[fd] = nil; lock.unlock()
    }
}
