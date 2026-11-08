import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// "Guest unresponsive" on the daemon (macOS: UbuntuSandboxVM's
    /// liveness.txt poll): a running guest that stops beating is reported in
    /// its /vms entry, and again answers once it beats; a paused one is
    /// never flagged.
    @Suite("Guest liveness", .serialized)
    struct GuestLivenessDaemonTests {
        @Test func aSilentGuestIsReportedAndClears() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            defer { Daemon.compromiseVMForTesting.withLockedValue { $0 = nil } }
            var rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            rec.state = .running
            try await d.registerForTesting(rec)
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { [id = rec.id] _ in (id, vm) } }
            let outbox = await d.vmDir(rec.id) + "/outbox"
            try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
            func beat(_ s: String) throws { try s.write(toFile: outbox + "/liveness.txt", atomically: true, encoding: .utf8) }
            func flagged() async -> Bool {
                guard case .object(let o) = await d.vmEntry(rec), case .bool(let b)? = o["guestUnresponsive"] else { return false }
                return b
            }
            try beat("1 1 5")
            await d.observeGuestLiveness(now: 0)
            await d.observeGuestLiveness(now: GuestLiveness.patience - 1)
            #expect(await !flagged(), "within the patience")
            await d.observeGuestLiveness(now: GuestLiveness.patience)
            #expect(await flagged(), "no new beat: unresponsive")
            #expect(LinuxSessionHost.unresponsive.withLockedValue { $0.contains(UUID(uuidString: rec.id)!) })
            try beat("2 1 5")
            await d.observeGuestLiveness(now: GuestLiveness.patience + 1)
            #expect(await !flagged(), "beating again")
            // Paused: not expected to beat, never flagged.
            try await vm.pause()
            await d.observeGuestLiveness(now: 10_000)
            #expect(await !flagged())
            await d.shutdown()
        }
    }
}
