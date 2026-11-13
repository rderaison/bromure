import Foundation
import Testing
@testable import SandboxEngine

/// The shared-window poll must not keep waking a VM the energy setting
/// idle-suspended; user-driven work still wakes it.
@MainActor
@Suite("Shared-window operation queue")
struct SharedWindowOperationQueueTests {
    private func drain(_ done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test("A background poll neither wakes nor runs on a suspended VM")
    func backgroundSkippedWhileSuspended() async {
        let queue = SharedWindowOperationQueue()
        var resumes = 0, ran = false, foreground = false
        queue.isVMSuspended = { true }
        queue.resumeVM = { resumes += 1 }
        queue.enqueue(background: true) { ran = true }
        await drain { false }
        #expect(!ran && resumes == 0)
        // The skipped poll no longer counts as outstanding: a later one is
        // admitted, and skipped again while the VM stays suspended.
        queue.enqueue(background: true) { ran = true }
        queue.enqueue { foreground = true }
        await drain { foreground }
        #expect(!ran && foreground && resumes == 1)
    }

    @Test("User-driven work wakes the VM and runs")
    func foregroundResumes() async {
        let queue = SharedWindowOperationQueue()
        var resumes = 0, ran = false
        queue.isVMSuspended = { true }
        queue.resumeVM = { resumes += 1 }
        queue.enqueue { ran = true }
        await drain { ran }
        #expect(ran && resumes == 1)
    }

    @Test("A background poll runs on an awake VM without resuming it")
    func backgroundRunsWhenAwake() async {
        let queue = SharedWindowOperationQueue()
        var resumes = 0, ran = 0
        queue.resumeVM = { resumes += 1 }
        queue.enqueue(background: true) { ran += 1 }
        queue.enqueue(background: true) { ran += 1 }  // deduplicated: one outstanding
        await drain { ran > 0 }
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == 1 && resumes == 0)
        queue.enqueue(background: true) { ran += 1 }  // admitted again once done
        await drain { ran > 1 }
        #expect(ran == 2)
    }

    @Test("Operations run in order; same-window motion coalesces")
    func orderAndCoalescing() async {
        let queue = SharedWindowOperationQueue()
        var log: [String] = []
        queue.enqueue { log.append("a") }
        queue.enqueue(coalescingMotion: 1) { log.append("m1") }
        queue.enqueue(coalescingMotion: 1) { log.append("m2") }
        queue.enqueue { log.append("b") }
        await drain { log.count >= 3 }
        for _ in 0..<20 { await Task.yield() }
        #expect(log == ["a", "m2", "b"])
    }
}
