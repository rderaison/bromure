import Foundation
import SandboxEngine

extension Daemon {
    /// Which workspaces' VMs run right now (live, not held paused), for the
    /// sentry's background liveness check: a VM that isn't running sends
    /// nothing, and that isn't silence.
    // @port-skip linux-only: the Linux daemon's run state for KernelSentryService.vmRunningProvider (macOS: launch's runTimer)
    nonisolated static let sentryRunState = KernelSentryRunState()

    // @port-skip linux-only: the Linux daemon's run state (live VMs not held paused)
    func publishSentryRunState() {
        Self.sentryRunState.set(Set(live.keys.filter { pauseHolds[$0] == nil }.compactMap { UUID(uuidString: $0) }))
    }

    /// The kernel sentry's module cache, under the state dir. Only with a
    /// catalog base set (BROMURE_SENTRY_CATALOG_BASE: a local or test
    /// catalog, whose unsigned catalogs the store accepts) until Linux takes
    /// the published one; without it a sentry workspace isn't started
    /// (DaemonSandboxGuard).
    // @port-skip linux-only: where the Linux daemon keeps SentryModuleStore's cache
    nonisolated static func makeSentryModuleStore(stateDir: String,
                                                  env: [String: String] = ProcessInfo.processInfo.environment) -> SentryModuleStore? {
        // SentryModuleStore.overrideBase's reading of it, from `env`.
        guard let raw = env["BROMURE_SENTRY_CATALOG_BASE"], !raw.isEmpty,
              let base = URL(string: raw.hasSuffix("/") ? raw : raw + "/") else { return nil }
        // This host's guests' modules (an x86_64 server's are amd64:
        // sentry/<hash>/amd64/).
        return SentryModuleStore(root: URL(fileURLWithPath: stateDir + "/sentry-modules", isDirectory: true),
                                 base: base, requireSignature: false, arch: .host)
    }

    /// The guest scripts' directory (beside agentd), where the sentry's
    /// source ships.
    // @port-skip linux-only: the Linux daemon's vm-setup directory
    nonisolated var setupDir: URL { URL(fileURLWithPath: config.agentdPath).deletingLastPathComponent() }

    /// Kernel sentry modules from the catalog: the guest reports its kernels
    /// (running and installed); the daemon caches their modules and drops
    /// them into the running VM's meta share, where a guest waiting at boot
    /// picks them up. Known kernels of sentry workspaces are prefetched at
    /// start, so a normal boot never waits.
    // @port ACAppDelegate.wireSentryModules() h=ee218e0c9f1709fa @641863f2
    func wireSentryModules() async {
        let running = Self.sentryRunState
        KernelSentryService.shared.vmRunningProvider = { running.isRunning($0) }
        let profiles = profileStore
        await MainActor.run {
            KernelSentryService.shared.pinDirectory = { profiles.profileDirectory(for: $0) }
        }
        guard let store = sentryModules,
              let hash = SentryModuleStore.shippedSourceHash(setupDir: setupDir) else { return }
        let vmsDir = config.stateDir + "/vms/"
        GuestSandboxStatusStore.shared.onKernels = { pid, kernels, waiting in
            // Status reports repeat; act on a new kernel set or a waiting guest
            // (boot staging already covers every kernel known before the boot).
            guard store.record(kernels: kernels, for: pid) || waiting else { return }
            // Only a workspace whose spec is active has a sentry dir.
            let dir = URL(fileURLWithPath: vmsDir + pid.uuidString.lowercased() + "/meta/sentry", isDirectory: true)
            Task.detached {
                await store.settle(profileID: pid, kernels: kernels, waiting: waiting, hash: hash, sentryDir: dir)
            }
        }
        let prefetch = profileStore.loadAll().filter { $0.effectiveKernelSentry != .off }
            .map { store.knownKernels(for: $0.id) }.flatMap { $0 }
        Task.detached { await store.prefetch(prefetch, hash: hash) }
    }

    /// The guest kernel sentry's channel (vsock 5841) for a workspace whose
    /// sentry is on, served by the shared SentryBridge (macOS:
    /// KernelSentryService.attach, through a VZ listener). Its pin is
    /// host-side, in the workspace's directory: a fresh boot drops it, a VM
    /// taken back keeps it (its module reconnects with a proof).
    // @port KernelSentryService.attach(profile: Profile, socketDevice: VZVirtioSocketDevice, restoring: Bool) h=fa39b107a197f581 @546fa806
    func serveSentry(_ rec: VMRecord, profile: Profile?, udsPath: String, stored: Int32?, restoring: Bool) async -> VsockFDListener? {
        if let profile { KernelSentryService.shared.dropBridge(profile.id)?.closeChannel() }
        guard let profile, !rec.managed, rec.registration != true,
              let bridge = await MainActor.run(body: { KernelSentryService.shared.makeBridge(profile: profile, restoring: restoring) })
        else {
            if let stored { close(stored) }
            return nil
        }
        do {
            // One connection at a time (the bridge refuses a second); each
            // served on its own thread for the VM's life, as on macOS.
            let l = try VsockFDListener(udsPath: udsPath, port: KernelSentryService.vsockPort,
                                        fdStoreName: "sentry-" + rec.shortId, stored: stored) { [weak bridge] fd in
                guard let bridge else { close(fd); return }
                bridge.accept(fd)
            }
            KernelSentryService.shared.adoptBridge(bridge)
            return l
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no kernel sentry listener: \(error)\n".utf8))
            return nil
        }
    }
}
