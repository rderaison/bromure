#if os(macOS)
import AppKit
import Foundation
import SandboxEngine
import Virtualization

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

@MainActor
final class KubeClusterEngine {
    unowned let app: ACAppDelegate
    let store: KubeClusterStore

    var runtimes: [UUID: ClusterRuntime] = [:]
    /// Clusters (and registries) whose dashboard is on screen: full probes
    /// on a fast cadence.
    var watched: Set<UUID> = []
    private var startedAutoClusters = false

    init(app: ACAppDelegate, store: KubeClusterStore) {
        self.app = app
        self.store = store
        for c in store.clusters { store.setStatus(c.id) { $0.phase = .stopped } }
        // LAN service IPs (MetalLB-style ARP) relay through the same vsock path.
        KubeLANAnnouncer.shared.relayOpener = { [weak self] nodeID, header, completion in
            MainActor.assumeIsolated {
                guard let self else { completion(-1); return }
                self.openRelay(nodeID: nodeID, target: header, completion: completion)
            }
        }
    }

    // MARK: Paths

    static var rootDirectory: URL { KubeClusterStore.defaultDirectory }

    func clusterDirectory(_ id: UUID) -> URL {
        Self.rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
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
        let profile: Profile
        let sessionDisk: SessionDisk
        let sandbox: UbuntuSandboxVM
        var ip: String?
        var up = false
        init(record: KubeNodeRecord, profile: Profile, sessionDisk: SessionDisk, sandbox: UbuntuSandboxVM) {
            self.record = record
            self.profile = profile
            self.sessionDisk = sessionDisk
            self.sandbox = sandbox
        }
    }

    final class ClusterRuntime {
        let id: UUID
        var nodes: [UUID: NodeRuntime] = [:]
        var lifecycleTask: Task<Void, Never>?
        var probeTask: Task<Void, Never>?
        var loadBalancer: KubeLoadBalancer?
        var direct: KubeDirectCluster?
        /// Services already stamped with the host IP (ns/name).
        var patchedServices: Set<String> = []
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
                try await self.runAddons(cluster, server: server, storage: cluster.spec.needsISCSI ? "1" : "0")
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
            await app.stopSession(node.record.id, action: .shutdown)
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
            if store.registry(id) != nil { startRegistryProbeLoop(id) } else { startProbeLoop(id) }
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
        for c in store.clusters where c.autoStart && c.provisioned { start(c.id) }
    }

    /// Whether `profileID` is one of our node / registry VMs.
    func isNode(_ profileID: UUID) -> Bool {
        store.clusters.contains { $0.nodes.contains { $0.id == profileID } }
            || store.registries.contains { $0.node.id == profileID }
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
        app.refreshKubeAccessForRunningWorkspaces()
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

            let wantsAddons = cluster.spec.storageEnabled
                || cluster.spec.synology?.isConfigured == true
                || (cluster.spec.loadBalancer == .metallb && cluster.metallbRange != nil)
            if wantsAddons {
                step(id, cluster.spec.storageEnabled ? "Installing Longhorn storage"
                     : cluster.spec.synology?.isConfigured == true ? "Installing the Synology CSI driver" : "Installing MetalLB")
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

    /// The add-ons step (Longhorn / MetalLB / Synology). Synology's DSM
    /// credentials are staged into the control-plane node's meta share
    /// only for the duration of the step.
    private func runAddons(_ cluster: KubeCluster, server: KubeNodeRecord, storage: String) async throws {
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
        try await runStep(id, node: server, step: "addons", args: [
            storage, String(cluster.spec.storageReplicas), metallb,
            cluster.metallbRange ?? "-", cluster.spec.loadBalancer.rawValue, synology,
        ])
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
            $0.hostIP = HostNetwork.primaryIPv4()
        }
        if cluster.spec.loadBalancer == .bromure, let server = cluster.server {
            let hostIP = HostNetwork.primaryIPv4()
            let pool = cluster.spec.lanPool.flatMap(KubeLANPool.parse) ?? []
            if hostIP == nil && pool.isEmpty {
                log(id, "This Mac has no LAN IPv4 address — LoadBalancer services stay pending")
            } else {
                rt.loadBalancer = KubeLoadBalancer(engine: self, clusterID: id, serverNodeID: server.id,
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
            scripts: [("bromure-k8s-node.sh", app.kubeNodeScriptURL), ("bromure-k8s-probe.py", app.kubeProbeScriptURL)],
            ipCommand: "bash \(Self.scriptPath) ip"), rt: rt)
    }

    /// One managed VM: a cluster node or a registry.
    struct MachineSpec {
        let ownerID: UUID
        let record: KubeNodeRecord
        let cpus: Int
        let memoryGB: Int
        let dataDiskGB: Int?
        let comment: String
        /// Files copied into the guest's read-only meta share.
        let scripts: [(String, URL?)]
        /// Guest command printing the VM's IPv4 (fallback for the outbox report).
        let ipCommand: String
    }

    /// Boot a managed VM and wait until its shell channel answers. Returns
    /// the guest's IP.
    func bootMachine(_ m: MachineSpec, rt: ClusterRuntime) async throws -> String {
        let id = m.ownerID
        let node = m.record
        let nodes = nodeStore(id)
        var profile = Profile(id: node.id, name: node.name, tool: .claude, authMode: .token,
                              homeModel: .virtiofs)
        profile.memoryGB = m.memoryGB
        profile.closeAction = .shutdown
        profile.color = .gray
        profile.nativeTerminal = true
        profile.comments = m.comment

        let sessionDisk = SessionDisk(profile: profile, store: nodes, baseDiskURL: app.imageManager.baseDiskURL)
        sessionDisk.tokenPlan = nil
        if let engine = app.mitmEngine, let scriptURL = app.bridgeScriptURL {
            sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                caCertificatePEM: engine.ca.certificatePEM,
                bridgeScriptURL: scriptURL,
                awsCredsHelperURL: app.awsCredsHelperURL,
                claudeTokenAgentURL: app.claudeTokenAgentURL,
                codexTokenAgentURL: app.codexTokenAgentURL,
                shellAgentURL: app.shellAgentURL,
                loopbackRelayAgentURL: app.loopbackRelayAgentURL,
                agentdURL: app.agentdURL)
        }
        let sandbox = UbuntuSandboxVM(imageManager: app.imageManager, sessionDisk: sessionDisk)
        sandbox.cpuCountOverride = m.cpus
        if let gb = m.dataDiskGB {
            let dataURL = nodes.profileDirectory(for: profile).appendingPathComponent("data.img")
            try Self.ensureSparseImage(at: dataURL, gigabytes: gb)
            sandbox.extraDiskURLs = [dataURL]
        }
        let runtime = NodeRuntime(record: node, profile: profile, sessionDisk: sessionDisk, sandbox: sandbox)
        rt.nodes[node.id] = runtime

        sandbox.onIPUpdate = { [weak self] ip in
            Task { @MainActor in
                guard let self else { return }
                runtime.ip = ip
                self.app.runningSessions[node.id]?.lastIP = ip
            }
        }
        sandbox.onStopped = { [weak self] error in
            Task { @MainActor in self?.nodeStopped(clusterID: id, nodeID: node.id, error: error) }
        }

        log(id, "Booting \(node.name)…")
        try nodes.prepareHomeDirectory(for: profile, terminalDefaults: app.terminalDefaults)
        try sandbox.prepare()
        try stageScripts(m.scripts, into: nodes.profileDirectory(for: profile))
        try await sandbox.start()

        guard let dev = sandbox.socketDevice else {
            throw KubeError.message("\(node.name): no vsock device")
        }
        // Egress through the host MITM (apt, the k3s installer, image pulls)
        // with an empty swap map — nothing to substitute on a node.
        app.mitmEngine?.register(socketDevice: dev, profileID: node.id)
        app.shellBridges[node.id] = ShellBridge(socketDevice: dev)
        let session = app.registerSession(sandbox, profile: profile)
        session.kubeClusterID = id

        // The shell agent dials out once agentd is up; the first pooled
        // connection is the boot signal.
        var alive = false
        for _ in 0..<360 {   // ≤ 3 minutes
            try Task.checkCancellation()
            if (app.shellBridges[node.id]?.poolSize ?? 0) > 0,
               (try? await exec(node.id, "true", timeout: 10)) != nil {
                alive = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
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
        app.runningSessions[node.id]?.lastIP = ip
        store.setStatus(id) { $0.nodesUp = rt.nodes.values.filter(\.up).count }
        log(id, "\(node.name) is up at \(ip)")
        return ip
    }

    func nodeStopped(clusterID: UUID, nodeID: UUID, error: Error?) {
        app.handleSessionStopped(profileID: nodeID)
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
    private func stageScripts(_ files: [(String, URL?)], into profileDir: URL) throws {
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

    static let scriptPath = "/mnt/bromure-meta/bromure-k8s-node.sh"
    private static let probePath = "/mnt/bromure-meta/bromure-k8s-probe.py"
    static let registryScriptPath = "/mnt/bromure-meta/bromure-registry.sh"
    /// Private ranges + cluster-internal names: node↔node and pod traffic
    /// must never go through the host proxy (which can't reach the VM LAN).
    static let noProxyForNodes = "localhost,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local"

    private func script(_ args: String) -> String { "bash \(Self.scriptPath) \(args)" }

    func exec(_ nodeID: UUID, _ command: String, timeout: Int) async throws -> String {
        try await app.guestExec(profileID: nodeID, command: command, timeout: timeout)
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
            let endpoints = lb.reconcile(services: probe.loadBalancerServices)
            store.setStatus(id) { $0.lbEndpoints = endpoints }
            await publishLoadBalancerIPs(id, rt: rt, services: probe.loadBalancerServices, endpoints: endpoints)
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
        for e in endpoints where e.bound {
            let key = "\(e.namespace)/\(e.service)"
            if publishIP[key] == nil, let ip = e.ip ?? lb.hostIP { publishIP[key] = ip }
        }
        for svc in services {
            let key = "\(svc.namespace)/\(svc.name)"
            if let ip = publishIP[key] {
                if !svc.ingress.contains(ip) {
                    if (try? await exec(server.id, script("patch-lb \(Self.shellQuote(svc.namespace)) \(Self.shellQuote(svc.name)) \(ip)"), timeout: 20)) != nil {
                        rt.patchedServices.insert(key)
                        log(id, "Published \(key) at \(ip)")
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
    /// Same path the fat-client forward resolver uses (the app process can't
    /// TCP-dial its own guests; the guest's loopback relay can).
    func openRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void) {
        guard let session = app.runningSessions[nodeID], let dev = session.sandbox.socketDevice else {
            completion(-1); return
        }
        dev.connect(toPort: 5010) { result in
            switch result {
            case .success(let conn):
                let vfd = conn.fileDescriptor
                let header = "\(target)\n"
                let sent = header.withCString { Darwin.write(vfd, $0, strlen($0)) }
                guard sent > 0 else { completion(-1); return }
                let dupFD = dup(vfd)
                // Keep the VZ connection object alive for as long as the
                // splice uses the dup'd descriptor.
                KubeRelayRetain.hold(conn, forFD: dupFD)
                completion(dupFD)
            case .failure:
                completion(-1)
            }
        }
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

// MARK: - Load balancer

/// Bromure's LoadBalancer implementation. Two ways to answer for a Service:
/// - a LAN pool address (`spec.lanPool`, or the Service's own
///   `spec.loadBalancerIP`): the announcer answers ARP for it on the wire
///   and terminates its flows in userspace, MetalLB-style — nothing on the
///   Mac is exposed;
/// - otherwise the Mac's own address: one host listener per (service, port)
///   on 0.0.0.0.
/// Either way each connection is relayed over vsock into the control-plane
/// node and on to the Service's NodePort; the cluster never leaves the VM LAN.
@MainActor
final class KubeLoadBalancer {
    unowned let engine: KubeClusterEngine
    let clusterID: UUID
    let serverNodeID: UUID
    let serverIP: String
    /// The Mac's LAN address (nil = none; only pool addresses can work).
    let hostIP: String?
    /// Spare LAN addresses (host order) handed out to Services.
    let pool: [UInt32]
    /// Service key → LAN address it was given.
    private var assigned: [String: UInt32] = [:]
    /// Addresses the LAN refused (someone else answers), so we don't retry
    /// them on every probe.
    private var refused: [UInt32: String] = [:]

    private final class Listener {
        let fd: Int32
        let key: String
        let target: String
        var thread: Thread?
        init(fd: Int32, key: String, target: String) { self.fd = fd; self.key = key; self.target = target }
    }

    private var listeners: [String: Listener] = [:]
    /// Ports that failed to bind, with the reason — shown in the dashboard.
    private var failures: [String: String] = [:]

    /// UDP on the Mac's own address: one bound socket per (service, port);
    /// every datagram rides the one framed relay into the control-plane
    /// node, and replies come back by NodePort to the socket that owns it.
    private final class UDPListener {
        let fd: Int32
        let key: String
        let nodePort: UInt16
        var thread: Thread?
        init(fd: Int32, key: String, nodePort: UInt16) { self.fd = fd; self.key = key; self.nodePort = nodePort }
    }
    private var udpListeners: [String: UDPListener] = [:]
    private var udpByNodePort: [UInt16: UDPListener] = [:]
    private var udpRelay: KubeUDPRelay?

    init(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID, serverIP: String,
         hostIP: String?, pool: [UInt32] = []) {
        self.engine = engine
        self.clusterID = clusterID
        self.serverNodeID = serverNodeID
        self.serverIP = serverIP
        self.hostIP = hostIP
        self.pool = pool
    }

    /// Bring the listener set in line with the cluster's LoadBalancer
    /// services. Returns the endpoint list for the status snapshot.
    func reconcile(services: [KubeProbe.Service]) -> [KubeLBEndpoint] {
        var desired: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)] = [:]
        var endpoints: [KubeLBEndpoint] = []
        // Services that get their own LAN address are answered by the
        // announcer, not by host listeners.
        let lanServices = reconcileLAN(services: services, endpoints: &endpoints)
        var desiredUDP: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)] = [:]
        for svc in services where !lanServices.contains("\(svc.namespace)/\(svc.name)") {
            for p in svc.ports {
                let key = "\(svc.namespace)/\(svc.name):\(p.port)"
                if p.protocolName.uppercased() == "UDP" {
                    if p.nodePort > 0 { desiredUDP[key] = (svc, p) }
                    else {
                        endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                        nodePort: 0, protocolName: p.protocolName,
                                                        bound: false, error: "no NodePort allocated"))
                    }
                    continue
                }
                guard p.protocolName.uppercased() == "TCP" else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: p.nodePort, protocolName: p.protocolName,
                                                    bound: false, error: "\(p.protocolName) isn't relayed"))
                    continue
                }
                guard p.nodePort > 0 else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: 0, protocolName: p.protocolName,
                                                    bound: false, error: "no NodePort allocated"))
                    continue
                }
                desired[key] = (svc, p)
            }
        }
        // Close what's gone (or whose NodePort changed).
        for (key, l) in listeners {
            if let d = desired[key], d.port.nodePort == Int(l.target.split(separator: ":").last ?? "") { continue }
            close(l)
            listeners[key] = nil
            failures[key] = nil
        }
        // Open what's new.
        for (key, d) in desired where listeners[key] == nil {
            guard hostIP != nil else {
                failures[key] = "this Mac has no LAN address"
                continue
            }
            let target = "\(serverIP):\(d.port.nodePort)"
            let fd = FatForward.listen(port: d.port.port, bindAll: true)
            if fd < 0 {
                failures[key] = "port \(d.port.port) is in use on this Mac"
                continue
            }
            let l = Listener(fd: fd, key: key, target: target)
            listeners[key] = l
            failures[key] = nil
            startAccepting(l)
        }
        for (key, d) in desired {
            endpoints.append(KubeLBEndpoint(namespace: d.svc.namespace, service: d.svc.name, port: d.port.port,
                                            nodePort: d.port.nodePort, protocolName: d.port.protocolName,
                                            bound: listeners[key] != nil, error: failures[key]))
        }
        reconcileUDP(desiredUDP, endpoints: &endpoints)
        return endpoints.sorted { ($0.namespace, $0.service, $0.port) < ($1.namespace, $1.service, $1.port) }
    }

    private func reconcileUDP(_ desired: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)],
                              endpoints: inout [KubeLBEndpoint]) {
        for (key, l) in udpListeners {
            if let d = desired[key], d.port.nodePort == Int(l.nodePort) { continue }
            closeUDP(l)
            udpListeners[key] = nil
            udpByNodePort[l.nodePort] = nil
            failures[key] = nil
        }
        for (key, d) in desired where udpListeners[key] == nil {
            guard hostIP != nil else { failures[key] = "this Mac has no LAN address"; continue }
            let fd = Self.bindUDP(port: d.port.port)
            if fd < 0 {
                failures[key] = "UDP port \(d.port.port) is in use on this Mac"
                continue
            }
            let l = UDPListener(fd: fd, key: key, nodePort: UInt16(d.port.nodePort))
            udpListeners[key] = l
            udpByNodePort[l.nodePort] = l
            failures[key] = nil
            startReceiving(l)
        }
        for (key, d) in desired {
            endpoints.append(KubeLBEndpoint(namespace: d.svc.namespace, service: d.svc.name, port: d.port.port,
                                            nodePort: d.port.nodePort, protocolName: d.port.protocolName,
                                            bound: udpListeners[key] != nil, error: failures[key]))
        }
    }

    private static func bindUDP(port: Int) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    private func closeUDP(_ l: UDPListener) {
        Darwin.shutdown(l.fd, SHUT_RDWR)
        Darwin.close(l.fd)
    }

    /// The one relay for every host-port UDP service of this cluster.
    private func ensureUDPRelay() -> KubeUDPRelay {
        if let r = udpRelay, !r.isClosed { return r }
        let engine = self.engine, nodeID = serverNodeID, header = "UDP \(serverIP)"
        let relay = KubeUDPRelay(
            dial: {
                let fd = KubeLANAnnouncer.openRelay({ n, h, done in
                    DispatchQueue.main.async { MainActor.assumeIsolated { engine.openRelay(nodeID: n, target: h, completion: done) } }
                }, nodeID: nodeID, header: header)
                return fd >= 0 ? fd : nil
            },
            onReply: { [weak self] srcIP, srcPort, dstPort, payload in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.deliverUDP(clientIP: srcIP, clientPort: srcPort, nodePort: dstPort, payload: payload) }
                }
            },
            onClosed: { fd in if fd >= 0 { KubeRelayRetain.release(fd: fd) } })
        udpRelay = relay
        return relay
    }

    private func deliverUDP(clientIP: UInt32, clientPort: UInt16, nodePort: UInt16, payload: ArraySlice<UInt8>) {
        guard let l = udpByNodePort[nodePort] else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(clientPort.bigEndian)
        addr.sin_addr.s_addr = clientIP.bigEndian
        let bytes = Array(payload)
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(l.fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func startReceiving(_ l: UDPListener) {
        let fd = l.fd, nodePort = l.nodePort
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65535)
            while true {
                var addr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue }; return }   // socket closed
                guard n > 0 else { continue }
                let clientIP = UInt32(bigEndian: addr.sin_addr.s_addr)
                let clientPort = UInt16(bigEndian: addr.sin_port)
                let payload = Array(buf[0..<n])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.ensureUDPRelay().send(srcIP: clientIP, srcPort: clientPort, dstPort: nodePort, payload: payload[...])
                    }
                }
            }
        }
        t.name = "kube-lb-udp:\(l.key)"
        t.start()
        l.thread = t
    }

    func stopAll() {
        for (_, l) in listeners { close(l) }
        listeners.removeAll()
        for (_, l) in udpListeners { closeUDP(l) }
        udpListeners.removeAll()
        udpByNodePort.removeAll()
        udpRelay?.close()
        udpRelay = nil
        failures.removeAll()
        KubeLANAnnouncer.shared.withdrawAll(owner: clusterID)
        KubeLANAnnouncer.shared.closeRelays(nodeID: serverNodeID)
        assigned.removeAll()
    }

    // MARK: LAN pool addresses

    /// Give every Service that asks for (or qualifies for) a LAN address its
    /// own IP on the wire. Returns the keys of the Services handled here.
    private func reconcileLAN(services: [KubeProbe.Service], endpoints: inout [KubeLBEndpoint]) -> Set<String> {
        var handled = Set<String>()
        let live = Set(services.map { "\($0.namespace)/\($0.name)" })
        // Services gone → give their addresses back.
        for (key, ip) in assigned where !live.contains(key) {
            KubeLANAnnouncer.shared.withdraw(ip: ip, owner: clusterID, service: key)
            assigned[key] = nil
        }
        // Explicit requests first, then Services already holding one of our
        // addresses (so a restart keeps assignments stable), then the rest —
        // an automatic assignment never grabs an address someone else has a
        // claim to.
        func rank(_ s: KubeProbe.Service) -> Int {
            if !(s.lbIP ?? "").isEmpty { return 0 }
            if s.ingress.contains(where: { ip in VMNetSwitch.parseIPv4(ip).map(pool.contains) ?? false }) { return 1 }
            return 2
        }
        let ordered = services.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.namespace, a.name) < (b.namespace, b.name)
        }
        for svc in ordered {
            let key = "\(svc.namespace)/\(svc.name)"
            guard let ip = resolveLANIP(for: svc, key: key) else { continue }
            handled.insert(key)
            let ipText = VMNetSwitch.ipString(ip)
            var ports: [KubeLANAnnouncer.PortKey: KubeLANAnnouncer.Target] = [:]
            for p in svc.ports {
                let proto = p.protocolName.uppercased()
                guard proto == "TCP" || proto == "UDP" else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: p.nodePort, protocolName: p.protocolName,
                                                    bound: false, error: "\(p.protocolName) isn't relayed", ip: ipText))
                    continue
                }
                guard p.nodePort > 0, p.port > 0, p.port <= 65535 else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: 0, protocolName: p.protocolName,
                                                    bound: false, error: "no NodePort allocated", ip: ipText))
                    continue
                }
                ports[KubeLANAnnouncer.PortKey(port: UInt16(p.port), udp: proto == "UDP")] =
                    KubeLANAnnouncer.Target(nodeID: serverNodeID, nodeIP: serverIP, nodePort: UInt16(p.nodePort))
            }
            var error: String?
            var conflicts: [KubeLANAnnouncer.PortKey] = []
            if let why = refused[ip] {
                error = why
            } else {
                do {
                    conflicts = try KubeLANAnnouncer.shared.publish(ip: ip, ports: ports, owner: clusterID, service: key)
                    assigned[key] = ip
                } catch {
                    let msg = "\(ipText): \(error.localizedDescription)"
                    refused[ip] = msg
                    if case KubeLANAnnouncer.PublishError.inUse = error { assigned[key] = nil }
                }
                error = refused[ip]
            }
            for p in svc.ports where ["TCP", "UDP"].contains(p.protocolName.uppercased()) && p.nodePort > 0 {
                let clash = conflicts.contains(KubeLANAnnouncer.PortKey(port: UInt16(p.port), udp: p.protocolName.uppercased() == "UDP"))
                endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                nodePort: p.nodePort, protocolName: p.protocolName,
                                                bound: error == nil && !clash,
                                                error: error ?? (clash ? "port \(p.port) already used on \(ipText)" : nil),
                                                ip: ipText))
            }
        }
        return handled
    }

    /// Which LAN address a Service gets: the one it asks for, the one it
    /// already holds (ours, or the ingress it was left with before a
    /// restart), else the next free pool address. nil = share the Mac's IP.
    private func resolveLANIP(for svc: KubeProbe.Service, key: String) -> UInt32? {
        if let requested = svc.lbIP, !requested.isEmpty {
            // A requested address is honoured even outside the pool — it's
            // the operator's call, as with metallb.io/loadBalancerIPs.
            if let ip = VMNetSwitch.parseIPv4(requested) { return ip }
        }
        if let ip = assigned[key] { return ip }
        guard !pool.isEmpty else { return nil }
        let taken = Set(assigned.values)
        // Re-adopt the address the Service already shows (stable across app
        // restarts) when it's from our pool and free.
        for ingress in svc.ingress {
            if let ip = VMNetSwitch.parseIPv4(ingress), pool.contains(ip), !taken.contains(ip) { return ip }
        }
        return pool.first { !taken.contains($0) && refused[$0] == nil }
    }

    private func close(_ l: Listener) {
        Darwin.shutdown(l.fd, SHUT_RDWR)
        Darwin.close(l.fd)
    }

    private func startAccepting(_ l: Listener) {
        let fd = l.fd, target = l.target, nodeID = serverNodeID
        let engine = self.engine
        let t = Thread { [engine] in
            while true {
                var addr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
                }
                if client < 0 {
                    if errno == EINTR { continue }
                    return   // listener closed
                }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        engine.openRelay(nodeID: nodeID, target: target) { vfd in
                            guard vfd >= 0 else { Darwin.close(client); return }
                            Thread.detachNewThread {
                                FatForward.splice(vfd, client)
                                KubeRelayRetain.release(fd: vfd)
                            }
                        }
                    }
                }
            }
        }
        t.name = "kube-lb:\(l.key)"
        t.start()
        l.thread = t
    }
}
#endif
