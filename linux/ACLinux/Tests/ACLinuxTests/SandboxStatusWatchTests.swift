import Foundation
import Testing
@testable import ACLinux

/// A strict workspace whose sandbox status never arrives (linux-port only):
/// shut down past 270 s, or later while its sentry reports loading, up to
/// the boot budget's ceiling; the event is the timeline's blocked sandbox row.
@Suite("Strict workspace: the sandbox status deadline")
struct SandboxStatusWatchTests {
    @Test func theDeadlineIsMacOSsBootBudget() {
        #expect(!Daemon.sandboxStatusOverdue(elapsed: 269, sentryLoading: false))
        #expect(Daemon.sandboxStatusOverdue(elapsed: 270, sentryLoading: false), "180 s + the 90 s settle grace")
        #expect(!Daemon.sandboxStatusOverdue(elapsed: 1200, sentryLoading: true), "the sentry still loading")
        let ceiling = 180 + KernelSentryService.loadBudget
        #expect(!Daemon.sandboxStatusOverdue(elapsed: ceiling - 1, sentryLoading: true))
        #expect(Daemon.sandboxStatusOverdue(elapsed: ceiling, sentryLoading: true), "up to BootBudget.workspace's ceiling")
    }

    @Test func theShutdownIsABlockedSandboxRowOnTheTimeline() throws {
        let why = "the guest's sandbox status never arrived (270 s after boot): the strict workspace was shut down"
        let e = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "sandbox.status",
                                                  eventData: ["filesystem": .string("failed"), "reason": .string(why)], now: Date()))
        #expect(e.kind == .blocked)
        #expect(e.decision == why)
    }

    /// Only time spent strict and not paused counts: a policy made strict
    /// later starts its count then, a compromise question's pause doesn't
    /// use the budget.
    @Test func onlyStrictUnpausedTimeCounts() {
        func tick(_ c: TimeInterval, strict: Bool = true, paused: Bool = false, loading: Bool = false) -> TimeInterval? {
            Daemon.sandboxStatusTick(counted: c, delta: 5, strict: strict, paused: paused, sentryLoading: loading)
        }
        #expect(tick(0, strict: false) == 0, "not strict yet: nothing counted, still watched")
        #expect(tick(100, paused: true) == 100, "paused: nothing counted")
        #expect(tick(100) == 105)
        #expect(tick(264) == 269)
        #expect(tick(265) == nil, "overdue at 270 s counted")
        #expect(tick(265, loading: true) == 270, "the sentry still loading")
        #expect(Daemon.sandboxStatusTick(counted: 10, delta: -3, strict: true, paused: false, sentryLoading: false) == 10)
    }

    /// The shutdown acts only on the VM the watch began with: one stopped
    /// and started again (or rebooted) meanwhile is another machine, and
    /// neither stopped nor reported.
    @Test func aReplacedMachineIsntShutDown() async throws {
        let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = try #require(UUID(uuidString: rec.id))
        await d.shutDownForMissingSandboxStatus(rec.id, machine: NSObject(), after: 270)
        try await Task.sleep(for: .milliseconds(200))
        let reported = await MainActor.run { SecurityTimeline.shared.allEvents.contains { $0.profileID == pid } }
        #expect(!reported, "no event for a machine that isn't the live one")
        #expect(await d.registry.find(rec.id)?.state == .stopped)
    }
}
