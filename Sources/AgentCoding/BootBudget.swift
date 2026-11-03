import Foundation
import IOKit.pwr_mgt

/// How long an unattended start (an automation firing, a board task) waits
/// for its workspace to come up — counted in time the Mac is AWAKE, and
/// keeping it awake meanwhile.
///
/// A wall-clock deadline failed every run that fired on a sleeping Mac: the
/// fire comes from a dark wake, the VM starts booting, the Mac goes back to
/// sleep, and on the next wake the 180 s were long gone — "the workspace
/// did not boot in time" for a workspace that was never given the time. A
/// suspended workspace restores in seconds and slipped through; a cold boot
/// of one that's OFF doesn't.
///
/// Kept awake means two assertions. `beginActivity(.idleSystemSleepDisabled)`
/// is PreventUserIdleSystemSleep: idle sleep only — the kernel's return to
/// sleep at the end of a DARK wake (the one a scheduled fire runs in,
/// often lid-closed) ignores it, so the boot lost the CPU after a slice too
/// short to finish. PreventSystemSleep (IOKit) is the one that check
/// honours. macOS honours it on AC power only; on battery the boot waits
/// for the next wake (the budget counts awake time, so it isn't spent).
///
/// The keep-awake lasts only the boot wait: it ends when the budget runs out
/// (checked or not — a caller stuck in a call that never returns can't hold
/// the Mac awake past it), on `release()` (the workspace answered; what
/// follows — a clone, the run — isn't "starting"), or when it's dropped.
final class BootBudget: @unchecked Sendable {
    private let deadline: TimeInterval
    private let clock: () -> TimeInterval
    /// Past the deadline, time still remains while this holds, up to `cap`,
    /// and `settleGrace` after it stops holding (once it has extended):
    /// the guest says the sentry settled a moment before its workload
    /// server is listening, and the next probes must still get to see it.
    private let extendWhile: (() -> Bool)?
    private let cap: TimeInterval
    static let settleGrace: TimeInterval = 90
    private var extendedUntil: TimeInterval?
    private let lock = NSLock()
    private var activity: NSObjectProtocol?
    private var systemSleepAssertion: IOPMAssertionID?

    /// `clock`: seconds of awake time (the default doesn't advance while the
    /// Mac sleeps). `holdAwake`: hold off idle sleep and App Nap until the
    /// budget runs out or is released.
    /// `extendWhile`: past `seconds`, the boot is still going while it says
    /// so (a guest waiting for its kernel sentry), up to `extendUpTo` in all.
    init(seconds: TimeInterval, reason: String, holdAwake: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         extendWhile: (() -> Bool)? = nil, extendUpTo: TimeInterval = 0) {
        self.clock = clock
        let start = clock()
        deadline = start + seconds
        self.extendWhile = extendWhile
        cap = start + max(seconds, extendWhile == nil ? seconds : extendUpTo)
        let awake = cap - start
        activity = holdAwake
            ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                    reason: reason)
            : nil
        if holdAwake {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason as CFString, &id) == kIOReturnSuccess {
                systemSleepAssertion = id
            }
            // DispatchTime stops while the Mac sleeps, like the budget.
            DispatchQueue.global().asyncAfter(deadline: .now() + awake) { [weak self] in self?.release() }
        }
    }

    deinit { release() }

    /// Stop keeping the Mac awake (idempotent).
    func release() {
        lock.lock()
        let a = activity, sys = systemSleepAssertion
        activity = nil
        systemSleepAssertion = nil
        lock.unlock()
        if let a { ProcessInfo.processInfo.endActivity(a) }
        if let sys { IOPMAssertionRelease(sys) }
    }

    /// Whether the Mac is still being kept awake for this budget.
    var holdsAwake: Bool { lock.lock(); defer { lock.unlock() }; return activity != nil || systemSleepAssertion != nil }

    /// Time is left. Once it isn't, the keep-awake ends.
    var remains: Bool {
        let now = clock()
        // Sampled every check, inside the deadline too: a hold that ends on
        // the check that first crosses it still gets its grace.
        if extendWhile?() ?? false { lock.lock(); extendedUntil = now; lock.unlock() }
        var left = now < deadline
        if !left, now < cap {
            lock.lock(); let last = extendedUntil; lock.unlock()
            left = last.map { now < $0 + Self.settleGrace } ?? false
        }
        if !left { release() }
        return left
    }
}

extension BootBudget {
    /// A workspace boot's budget: `seconds`, and past them for as long as
    /// the guest still reports its kernel sentry loading (`pending` /
    /// `waiting`), up to the sentry's own worst case — under `requirement:
    /// hard` nothing of the workload runs until it settles, which can take
    /// far longer than a boot (Finding CWE-670, "Hard-sentry hold fails
    /// unattended boots at 180s while the module is still loading").
    static func workspace(_ profileID: UUID, seconds: TimeInterval, reason: String) -> BootBudget {
        BootBudget(seconds: seconds, reason: reason,
                   extendWhile: { sentryLoading(profileID) },
                   extendUpTo: seconds + KernelSentryService.loadBudget)
    }

    /// The guest says its kernel sentry is still on its way.
    static func sentryLoading(_ profileID: UUID) -> Bool {
        guard let s = GuestSandboxStatusStore.shared.sentryState(for: profileID) else { return false }
        return s == "pending" || s == "waiting"
    }
}
