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
}
