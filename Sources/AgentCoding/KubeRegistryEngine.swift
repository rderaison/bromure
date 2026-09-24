#if os(macOS)
import Foundation
import SandboxEngine

// MARK: - Container registries (engine side)
//
// A registry is one small managed VM running `registry:2` under the base
// image's docker, with the image layers on a dedicated sparse disk. It
// boots through the same path as a cluster node (`bootMachine`), is
// probed for its catalog, and — once up — is pushed to the workspaces its
// access list allows (dockerd insecure registry + BROMURE_REGISTRY) and to
// every running cluster (containerd mirror in registries.yaml), so
// `docker push <ip>:5000/app && kubectl run --image=<ip>:5000/app` just
// works.

extension KubeClusterEngine {

    @discardableResult
    func createRegistry(name: String, access: KubeWorkspaceAccess, memoryGB: Int, diskGB: Int,
                        autoStart: Bool = true) -> KubeRegistry {
        var registry = KubeRegistry(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    access: access,
                                    memoryGB: min(max(memoryGB, KubeRegistry.memoryRange.lowerBound), KubeRegistry.memoryRange.upperBound),
                                    diskGB: min(max(diskGB, KubeRegistry.diskRange.lowerBound), KubeRegistry.diskRange.upperBound),
                                    autoStart: autoStart)
        if registry.name.isEmpty { registry.name = "registry" }
        let taken = Set(store.registries.map(\.slug))
        if taken.contains(registry.slug) {
            var n = 2
            while taken.contains(KubeCluster.slug(for: "\(registry.name) \(n)")) { n += 1 }
            registry.name = "\(registry.name) \(n)"
        }
        registry.node = KubeNodeRecord(name: "registry-\(registry.slug)", role: .server, index: 1)
        store.upsert(registry)
        store.setStatus(registry.id) { $0 = KubeClusterStatus(); $0.phase = .creating }
        let id = registry.id
        let rt = runtime(id)
        rt.lifecycleTask = Task { [weak self] in await self?.provisionRegistry(id) }
        return registry
    }

    func startRegistry(_ id: UUID) {
        guard store.registry(id) != nil else { return }
        let phase = store.status(id).phase
        guard !phase.isBusy, !phase.isUp else { return }
        let rt = runtime(id)
        rt.stopping = false
        store.setStatus(id) { $0.phase = .starting; $0.message = nil; $0.log = []; $0.step = nil }
        rt.lifecycleTask = Task { [weak self] in await self?.provisionRegistry(id) }
    }

    /// Stopping a registry is the generic machine stop; the mirrors stay in
    /// the clusters (pulls fail until it's back, like any registry outage).
    func stopRegistry(_ id: UUID) async {
        await stop(id)
    }

    func restartRegistry(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.stopRegistry(id)
            self.startRegistry(id)
        }
    }

    func deleteRegistry(_ id: UUID) async {
        guard let registry = store.registry(id) else { return }
        await stop(id)
        store.setStatus(id) { $0.phase = .deleting }
        MACBindings.shared.release(profileID: registry.node.id)
        try? FileManager.default.removeItem(at: clusterDirectory(id))
        runtimes[id] = nil
        watched.remove(id)
        store.removeRegistry(id)
        pushKubeconfigsToWorkspaces()
        pushRegistriesToClusters()
    }

    func setRegistryAccess(_ id: UUID, _ access: KubeWorkspaceAccess) {
        guard var registry = store.registry(id) else { return }
        var resolved = access
        if case .only(let ids) = access, ids.isEmpty { resolved = .all }
        guard registry.access != resolved else { return }
        registry.access = resolved
        store.upsert(registry)
        pushKubeconfigsToWorkspaces()
    }

    func setRegistryAutoStart(_ id: UUID, _ on: Bool) {
        guard var registry = store.registry(id), registry.autoStart != on else { return }
        registry.autoStart = on
        store.upsert(registry)
    }

    // MARK: Provisioning / boot (one flow: setup is idempotent in the VM)

    private func provisionRegistry(_ id: UUID) async {
        guard var registry = store.registry(id) else { return }
        let rt = runtime(id)
        let fresh = !registry.provisioned
        log(id, fresh ? "Creating registry “\(registry.name)”: \(registry.memoryGB) GB RAM, \(registry.diskGB) GB for images"
                      : "Starting registry “\(registry.name)”…")
        do {
            step(id, "Booting the registry VM")
            try FileManager.default.createDirectory(at: clusterDirectory(id), withIntermediateDirectories: true)
            let previousIP = registry.node.lastIP
            let ip: String
            if let live = rt.nodes[registry.node.id], live.up, let known = live.ip {
                ip = known
            } else {
                ip = try await bootMachine(MachineSpec(
                    ownerID: id, record: registry.node, cpus: 2, memoryGB: registry.memoryGB,
                    dataDiskGB: registry.diskGB,
                    comment: "Container registry “\(registry.name)” — managed by Bromure.",
                    scripts: [("bromure-registry.sh", app.kubeRegistryScriptURL)],
                    ipCommand: "bash \(Self.registryScriptPath) ip",
                    restoreSavedState: registry.provisioned), rt: rt)
            }
            registry.node.lastIP = ip
            store.upsert(registry)
            store.setStatus(id) { $0.nodesUp = 1; $0.address = "\(ip):\(registry.port)" }

            step(id, fresh ? "Installing the registry" : "Starting the registry")
            try await runStep(id, node: registry.node, step: "setup", args: [String(registry.port)],
                              scriptPath: Self.registryScriptPath)

            registry.provisioned = true
            store.upsert(registry)
            store.setStatus(id) {
                $0.phase = .running
                $0.step = nil
                $0.message = nil
                $0.startedAt = Date()
                $0.address = "\(ip):\(registry.port)"
            }
            startRegistryProbeLoop(id)
            log(id, "✓ Registry “\(registry.name)” answers at \(ip):\(registry.port)")
            if let prev = previousIP, prev != ip {
                log(id, "Address changed from \(prev):\(registry.port) — images tagged with the old address must be re-tagged")
            }
            // Workspaces get the insecure-registry entry; clusters get the mirror.
            pushKubeconfigsToWorkspaces()
            pushRegistriesToClusters()
        } catch is CancellationError {
            log(id, "Cancelled.")
        } catch {
            fail(id, "\(fresh ? "Creating" : "Starting") the registry failed: \(error.localizedDescription)")
        }
    }

    // MARK: Probe

    func startRegistryProbeLoop(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        rt.probeTask?.cancel()
        rt.probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeRegistryOnce(id)
                let interval: UInt64 = self.watched.contains(id) ? 4_000_000_000 : 20_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func probeRegistryOnce(_ id: UUID) async {
        guard let rt = runtimes[id], let registry = store.registry(id),
              rt.nodes[registry.node.id]?.up == true else { return }
        let cmd = "bash \(Self.registryScriptPath) probe \(registry.port)"
        guard let out = try? await exec(registry.node.id, cmd, timeout: 30),
              let info = KubeRegistryInfo.decode(Data(out.utf8)) else {
            store.setStatus(id) { $0.message = "Registry probe failed" }
            return
        }
        store.setStatus(id) {
            $0.registry = info
            if $0.phase == .running { $0.message = info.reachable ? nil : "The registry isn't answering" }
        }
    }
}
#endif
