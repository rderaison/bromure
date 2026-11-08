import Foundation
import SandboxEngine

/// Where the daemon's kernel sentry modules come from (DaemonConfig).
// @port-skip linux-only: the Linux daemon's choice of sentry catalog (macOS: SentryModuleStore.shared's default)
public struct SentryCatalogSource: Sendable, Equatable {
    public var base: URL
    /// Catalogs must verify against the pinned key (the published one); a
    /// local or test base accepts unsigned ones, as SentryModuleStore's
    /// override does.
    public var signed: Bool

    /// The published catalog (https://dl.bromure.io/), signed.
    public static let published = SentryCatalogSource(base: SentryModuleStore.defaultBase, signed: true)

    /// BROMURE_SENTRY_CATALOG_BASE when set (unsigned accepted), else the
    /// published catalog.
    // @port-skip linux-only: see SentryCatalogSource
    public static func fromEnvironment(_ env: [String: String]) -> SentryCatalogSource {
        guard let raw = env["BROMURE_SENTRY_CATALOG_BASE"], !raw.isEmpty,
              let base = URL(string: raw.hasSuffix("/") ? raw : raw + "/") else { return .published }
        return SentryCatalogSource(base: base, signed: false)
    }
}

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

    /// The kernel sentry's module cache, under the state dir, reading this
    /// host's guests' catalog (an x86_64 server's are amd64:
    /// sentry/<hash>/amd64/) from `source`; none without one. A sentry
    /// workspace isn't started while no verified catalog is to be had
    /// (DaemonSandboxGuard).
    // @port-skip linux-only: where the Linux daemon keeps SentryModuleStore's cache
    nonisolated static func makeSentryModuleStore(stateDir: String, source: SentryCatalogSource?) -> SentryModuleStore? {
        guard let source else { return nil }
        return SentryModuleStore(root: URL(fileURLWithPath: stateDir + "/sentry-modules", isDirectory: true),
                                 base: source.base, requireSignature: source.signed, arch: .host)
    }

    /// Whether a verified module catalog for the shipped sentry source and
    /// this host's architecture is to be had now (fetched, else cached).
    // @port-skip linux-only: the Linux guard's question (macOS boots and lets a guest without a module go on)
    func sentryCatalogReady() async -> Bool {
        guard let store = sentryModules, let hash = SentryModuleStore.shippedSourceHash(setupDir: setupDir) else { return false }
        return await store.refreshCatalog(hash).map { !$0.modules.isEmpty } ?? false
    }

    /// The same from what's cached only (no fetch), for a VM taken back.
    // @port-skip linux-only: see sentryCatalogReady
    nonisolated func sentryCatalogCached() -> Bool {
        guard let store = sentryModules, let hash = SentryModuleStore.shippedSourceHash(setupDir: setupDir) else { return false }
        return store.cachedCatalog(hash).map { !$0.modules.isEmpty } ?? false
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
    // partial: fetches only for a workspace with the sentry on (its kernels' report, the prefetch); macOS also settles the others' kernels
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
            // A workspace without the sentry on fetches nothing (no catalog or
            // module download for a guest that doesn't load it).
            guard Self.sentryOn(pid, in: profiles.loadAll()) else { return }
            // Only a workspace whose spec is active has a sentry dir.
            let dir = URL(fileURLWithPath: vmsDir + pid.uuidString.lowercased() + "/meta/sentry", isDirectory: true)
            Task.detached {
                await store.settle(profileID: pid, kernels: kernels, waiting: waiting, hash: hash, sentryDir: dir)
            }
        }
        let all = profileStore.loadAll()
        let prefetch = all.filter { Self.sentryOn($0.id, in: all) }
            .map { store.knownKernels(for: $0.id) }.flatMap { $0 }
        // Nothing to fetch while no workspace has the sentry on.
        guard !prefetch.isEmpty else { return }
        Task.detached { await store.prefetch(prefetch, hash: hash) }
    }

    /// Whether a workspace loads the sentry, so its kernels' modules are
    /// worth a catalog fetch.
    // @port-skip linux-only: the fetch gate of wireSentryModules (macOS settles every workspace's kernels)
    nonisolated static func sentryOn(_ pid: UUID, in profiles: [Profile]) -> Bool {
        profiles.contains { $0.id == pid && $0.effectiveKernelSentry != .off }
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
