import Foundation
import IOKit.pwr_mgt
import Testing
@testable import bromure_ac

/// An automation on a sleeping Mac: the boot wait counts awake time only.
@Suite("Boot budget")
struct BootBudgetTests {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 1000 }

    @Test("time asleep isn't spent: only the clock that stops in sleep counts")
    func awakeTimeOnly() {
        let c = Clock()
        let b = BootBudget(seconds: 180, reason: "test", holdAwake: false, clock: { c.now })
        #expect(b.remains)
        c.now += 179
        #expect(b.remains)
        c.now += 1
        #expect(!b.remains)
    }

    /// Finding (CWE-670): "Hard-sentry hold fails unattended boots at 180s
    /// while the module is still loading".
    @Test("past its seconds, a budget holds while the guest still loads its sentry, up to the cap")
    func extendsWhileLoading() {
        let c = Clock()
        final class Flag: @unchecked Sendable { var on = true }
        let loading = Flag()
        let b = BootBudget(seconds: 180, reason: "test", holdAwake: false, clock: { c.now },
                           extendWhile: { loading.on }, extendUpTo: 180 + 1905)
        c.now += 600
        #expect(b.remains)                       // past 180 s, the sentry is still loading
        loading.on = false
        // Settled: the workload server starts just after; the probes get a grace to see it.
        #expect(b.remains)
        c.now += BootBudget.settleGrace - 1
        #expect(b.remains)
        c.now += 2
        #expect(!b.remains)
        // Loading seen just before the deadline, settled as it passes: the grace still runs.
        let edge = Flag()
        let atEdge = BootBudget(seconds: 180, reason: "test", holdAwake: false, clock: { c.now },
                                extendWhile: { edge.on }, extendUpTo: 180 + 1905)
        c.now += 178
        #expect(atEdge.remains)
        edge.on = false
        c.now += 5
        #expect(atEdge.remains)
        // A budget that never extended has no grace past its seconds.
        let plain = BootBudget(seconds: 180, reason: "test", holdAwake: false, clock: { c.now },
                               extendWhile: { false }, extendUpTo: 180 + 1905)
        c.now += 181
        #expect(!plain.remains)
        let capped = BootBudget(seconds: 180, reason: "test", holdAwake: false, clock: { c.now },
                                extendWhile: { true }, extendUpTo: 180 + 1905)
        c.now += 180 + 1905
        #expect(!capped.remains)                 // never past the sentry's worst case
        // Only `pending` / `waiting` count as loading.
        let pid = UUID()
        defer { GuestSandboxStatusStore.shared.reset(profileID: pid) }
        #expect(!BootBudget.sentryLoading(pid))
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "filesystem": "pending",
                                                                       "sentry": "waiting"])
        #expect(BootBudget.sentryLoading(pid))
        GuestSandboxStatusStore.shared.update(profileID: pid, report: ["event": "sandbox_status", "filesystem": "pending",
                                                                       "sentry": "running"])
        #expect(!BootBudget.sentryLoading(pid))
    }

    @Test("the session engine's boot wait keeps a grace after the sentry was last seen loading")
    @MainActor func sessionBootGrace() {
        let t0 = Date(), deadline = t0.addingTimeInterval(180), cap = t0.addingTimeInterval(180 + 1905)
        let go = { (at: TimeInterval, last: TimeInterval?) in
            AgentSessionEngine.bootGoesOn(now: t0.addingTimeInterval(at), deadline: deadline, sentryCap: cap,
                                          lastLoading: last.map { t0.addingTimeInterval($0) })
        }
        #expect(go(100, nil))                    // within the deadline
        #expect(!go(200, nil))                   // past it, never loading
        #expect(go(292, 291))                    // loading a moment ago
        #expect(go(294 + 80, 292))               // settled at ~292: probes go on through the grace
        #expect(!go(292 + 91, 292))
        #expect(!go(180 + 1905, 180 + 1904))     // never past the cap
    }

    @Test("the default clock is the one that stops while the Mac sleeps")
    func defaultClock() {
        let b = BootBudget(seconds: 60, reason: "test")
        #expect(b.remains)
    }

    /// Finding (CWE-400): the keep-awake lived as long as the budget object,
    /// which a checkout automation held through its clone (up to 15 min), and
    /// a guest exec that never answered held it for the life of the app.
    @Test("the keep-awake ends when the time is up, checked or not, or on release")
    func keepAwakeEnds() async throws {
        let c = Clock()
        let b = BootBudget(seconds: 180, reason: "test", clock: { c.now })
        #expect(b.holdsAwake)
        c.now += 180
        #expect(!b.remains)
        #expect(!b.holdsAwake)
        // Released early: the workspace answered.
        let r = BootBudget(seconds: 180, reason: "test")
        r.release()
        #expect(!r.holdsAwake)
        r.release()   // idempotent
        // Never checked again (a caller stuck in a call): it still ends.
        let stuck = BootBudget(seconds: 0.2, reason: "test")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(!stuck.holdsAwake)
    }

    @Test("a guest that takes the request and never answers can't hold the exchange")
    func exchangeHasADeadline() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let start = ProcessInfo.processInfo.systemUptime
        let out = ACAutomationServer.exchangeJSON(fd: fds[0], request: ["cmd": "true"], replyWithin: 0.3)
        let took = ProcessInfo.processInfo.systemUptime - start
        if case .protocolFailure = out {} else { Issue.record("expected a protocol failure, got \(out)") }
        #expect(took < 3)
    }

    /// Finding: the boot's keep-awake was PreventUserIdleSystemSleep only,
    /// which a dark wake's return to sleep ignores — the boot lost the CPU.
    @Test("the boot holds PreventSystemSleep too, and lets it go with the budget")
    func preventsSystemSleep() {
        let reason = "boot-budget-test-\(UUID().uuidString)"
        func held() -> Bool {
            var dict: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
                  let all = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
                  let mine = all[NSNumber(value: getpid())] else { return false }
            return mine.contains {
                $0[kIOPMAssertionNameKey as String] as? String == reason
                    && $0[kIOPMAssertionTypeKey as String] as? String == kIOPMAssertionTypePreventSystemSleep as String
            }
        }
        let b = BootBudget(seconds: 180, reason: reason)
        #expect(held())
        b.release()
        #expect(!held())
        #expect(!b.holdsAwake)
    }
}
