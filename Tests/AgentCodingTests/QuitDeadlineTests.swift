import Foundation
import Testing
@testable import bromure_ac

/// QH-1: quit's bounded waits must actually be bounded, even when the work
/// awaits a continuation that ignores cancellation (a wedged `vm.stop`).
@Suite("QuitDeadline: bounded quit waits")
struct QuitDeadlineTests {
    /// Parks forever, ignoring cancellation — the shape of a VZ stop whose
    /// completion handler never fires. Leaks one continuation per call, by design.
    private static func neverReturns() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }

    @Test("A hung, cancellation-deaf operation is abandoned at the deadline")
    func hungOperationTimesOut() async {
        let logged = LogBox()
        let start = Date()
        let finished = await QuitDeadline.run(seconds: 0.2, label: "hung",
                                              log: { logged.append($0) }) {
            await Self.neverReturns()
        }
        #expect(finished == false)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(logged.lines.count == 1)
        #expect(logged.lines.first?.contains("hung") == true)
    }

    @Test("A task-group race against a sleep does NOT bound the same hang")
    func taskGroupRaceIsNotABound() async {
        // Documents the original bug: the group awaits the deaf child even
        // after cancelAll(). We only prove it is still pending after the
        // "timeout" fired, then let it go (wrapped in QuitDeadline itself).
        let returned = await QuitDeadline.run(seconds: 1.0, label: "race", log: { _ in }) {
            await withTaskGroup(of: Void.self) { race in
                race.addTask { await Self.neverReturns() }
                race.addTask { try? await Task.sleep(nanoseconds: 50_000_000) }
                _ = await race.next()
                race.cancelAll()
            }
        }
        #expect(returned == false)
    }

    @Test("A fast operation returns its value and does not log")
    func fastOperationWins() async {
        let logged = LogBox()
        let value = await QuitDeadline.run(seconds: 5, label: "fast", timeoutValue: -1,
                                           log: { logged.append($0) }) { 42 }
        #expect(value == 42)
        #expect(logged.lines.isEmpty)
    }

    @Test("Timeout value is returned for a slow typed operation")
    func slowTypedOperation() async {
        let value = await QuitDeadline.run(seconds: 0.1, label: "slow", timeoutValue: false,
                                           log: { _ in }) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        #expect(value == false)
    }

    @Test("Main-actor work runs and completes in time")
    @MainActor
    func mainActorWork() async {
        let done = await QuitDeadline.run(seconds: 5, label: "main", log: { _ in }) { @MainActor in
            MainActor.assertIsolated()
        }
        #expect(done)
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
}
