import Foundation
import NIOConcurrencyHelpers

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

    /// One tick of the watch: the time counted so far, or nil when it's
    /// overdue. Only a tick spent strict and not paused counts.
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    static func sandboxStatusTick(counted: TimeInterval, delta: TimeInterval, strict: Bool, paused: Bool,
                                  sentryLoading: Bool) -> TimeInterval? {
        guard strict, !paused else { return counted }
        let now = counted + max(0, delta)
        return sandboxStatusOverdue(elapsed: now, sentryLoading: sentryLoading) ? nil : now
    }

    /// Each workspace's attestor channel (serveAttestor), for the watch to
    /// ask the guest its status: a VM taken back or resumed after a daemon
    /// restart starts with an empty store, filled only when asked.
    static let attestorBridges = NIOLockedValueBox<[UUID: WeakAttestorBridge]>([:])
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    struct WeakAttestorBridge: @unchecked Sendable { weak var bridge: AttestorBridge? }

    /// Watches workspace `id`'s VM `machine` from its boot, resume or
    /// adoption: done once the guest's sandbox status arrives or the VM
    /// goes. Only time it's strict and not paused (a compromise question
    /// holding it) counts; a status not heard is asked for first. Overdue,
    /// it's shut down.
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    func watchSandboxStatus(_ id: String, machine: FirecrackerMachine, every tick: Duration = .seconds(5),
                            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        guard let pid = UUID(uuidString: id) else { return }
        Task { [weak self] in
            var counted: TimeInterval = 0
            var last = clock()
            while true {
                try? await Task.sleep(for: tick)
                guard let self, await self.live[id]?.machine === machine else { return }
                if GuestSandboxStatusStore.shared.status(for: pid) != nil { return }
                let now = clock()
                let delta = now - last
                last = now
                let strict = await self.mitm?.guardrailsConfig(for: pid)?.egressPolicy?.enforceBinaries == true
                let paused = await self.pauseHolds[id] != nil
                if strict, !paused, let bridge = Self.attestorBridges.withLockedValue({ $0[pid]?.bridge }), bridge.isConnected {
                    await bridge.askSandboxStatus()
                    if GuestSandboxStatusStore.shared.status(for: pid) != nil { return }
                }
                if let next = Self.sandboxStatusTick(counted: counted, delta: delta, strict: strict, paused: paused,
                                                     sentryLoading: BootBudget.sentryLoading(pid)) {
                    counted = next
                    continue
                }
                await self.shutDownForMissingSandboxStatus(id, machine: machine, after: counted + delta)
                return
            }
        }
    }

    /// The shutdown, only if `machine` is still the workspace's VM and
    /// nothing else is stopping or rebooting it: checked on the actor with
    /// no suspension before deleteVM reads it, so a stop and start or a
    /// reboot in between never takes the new boot.
    // @port-skip linux-only: the strict-workspace status deadline (no macOS counterpart)
    func shutDownForMissingSandboxStatus(_ id: String, machine: AnyObject, after elapsed: TimeInterval) async {
        guard live[id]?.machine === machine, stopping[id] == nil, !rebooting.contains(id),
              let rec = registry.find(id), let pid = UUID(uuidString: id) else { return }
        let name = existingProfile(for: rec)?.name ?? rec.name
        let why = "the guest's sandbox status never arrived (\(Int(elapsed)) s after boot): the strict workspace was shut down"
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': \(why)\n".utf8))
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "sandbox.status",
                                            eventData: ["filesystem": .string("failed"), "reason": .string(why)])
        _ = await deleteVM(rec, action: "stop")
    }
}
