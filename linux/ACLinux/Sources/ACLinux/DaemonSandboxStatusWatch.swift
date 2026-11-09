import Foundation

/// A strict workspace (an egress policy enforcing `binaries`) whose guest
/// never reports its sandbox status: the binary gate holds its connections
/// meanwhile, and past a time limit the VM is shut down, with a Security
/// Timeline event, not marked compromised (linux-port only, agreed with the
/// macOS side). The limit is macOS's boot budget: bootTimeout (180 s) plus
/// BootBudget.settleGrace (90 s), extended while the guest reports its
/// kernel sentry still loading, up to bootTimeout + the sentry's load budget
/// (BootBudget.workspace's ceiling).
extension Daemon {
    static let sandboxStatusBootTimeout: TimeInterval = 180

    /// Whether a strict workspace's sandbox status is overdue `elapsed`
    /// seconds into its boot.
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    static func sandboxStatusOverdue(elapsed: TimeInterval, sentryLoading: Bool) -> Bool {
        guard elapsed >= sandboxStatusBootTimeout + BootBudget.settleGrace else { return false }
        if sentryLoading, elapsed < sandboxStatusBootTimeout + KernelSentryService.loadBudget { return false }
        return true
    }

    /// Watches a cold boot of workspace `id` (its VM `machine`): done once
    /// the guest's sandbox status arrives, the VM goes or isn't strict any
    /// more; overdue, it's shut down.
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    func watchSandboxStatus(_ id: String, machine: FirecrackerMachine, every tick: Duration = .seconds(5),
                            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        guard let pid = UUID(uuidString: id) else { return }
        let start = clock()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: tick)
                guard let self, await self.live[id]?.machine === machine else { return }
                if GuestSandboxStatusStore.shared.status(for: pid) != nil { return }
                guard await self.mitm?.guardrailsConfig(for: pid)?.egressPolicy?.enforceBinaries == true else { return }
                let elapsed = clock() - start
                guard Self.sandboxStatusOverdue(elapsed: elapsed, sentryLoading: BootBudget.sentryLoading(pid)) else { continue }
                await self.shutDownForMissingSandboxStatus(id, after: elapsed)
                return
            }
        }
    }

    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    func shutDownForMissingSandboxStatus(_ id: String, after elapsed: TimeInterval) async {
        guard let rec = registry.find(id), let pid = UUID(uuidString: id) else { return }
        let name = existingProfile(for: rec)?.name ?? rec.name
        let why = "the guest's sandbox status never arrived (\(Int(elapsed)) s after boot): the strict workspace was shut down"
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': \(why)\n".utf8))
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "sandbox.status",
                                            eventData: ["filesystem": .string("failed"), "reason": .string(why)])
        _ = await deleteVM(rec, action: "stop")
    }
}
