import Foundation
import Testing
@testable import bromure_ac

/// Review of the consent-overtake fix: the terminal gate held ONE prompt,
/// answer and semaphore per workspace. A fresh prompt after an overtaken one
/// (or a second credential asking at once) overwrote the first, and the
/// keystroke answering one completed the other. Each ask is its own now.
@Suite("Terminal consent gate: one answer per ask")
struct PumpConsentGateTests {
    private func asking(_ gate: ACAutomationServer.PumpConsentGate, _ id: UUID, _ prompt: String,
                        into box: ResultBox) {
        Thread.detachNewThread {
            box.set(gate.ask(id: id, prompt: prompt, choices: ["Allow", "Deny"], timeout: 30))
        }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?? = .none
        func set(_ v: Int?) { lock.lock(); value = .some(v); lock.unlock() }
        var result: Int?? { lock.lock(); defer { lock.unlock() }; return value }
        func wait(_ seconds: Double = 2) -> Int?? {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if let r = result { return r }; Thread.sleep(forTimeInterval: 0.01) }
            return result
        }
    }

    @Test("a withdrawn ask returns at once; the next ask gets its own prompt and its own answer")
    func withdrawnAskDoesNotTakeTheNextAnswer() {
        let gate = ACAutomationServer.PumpConsentGate()
        let old = UUID(), fresh = UUID()
        let oldBox = ResultBox(), freshBox = ResultBox()
        asking(gate, old, "old", into: oldBox)
        Thread.sleep(forTimeInterval: 0.1)
        let shown = gate.takePending()
        #expect(shown?.id == old)
        gate.withdraw(old)                                // overtaken by a Guardrails decision
        #expect(oldBox.wait() == .some(nil))
        #expect(!gate.isOpen(old))                        // the terminal stops showing it
        asking(gate, fresh, "fresh", into: freshBox)
        Thread.sleep(forTimeInterval: 0.1)
        gate.deliver(0, to: old)                          // a late keystroke for the dead prompt
        #expect(freshBox.wait(0.3) == nil)                // …doesn't answer the fresh one
        let next = gate.takePending()
        #expect(next?.id == fresh && next?.prompt == "fresh")
        gate.deliver(0, to: fresh)
        #expect(freshBox.wait() == .some(0))
    }

    @Test("two asks at once are shown in turn; the attach ending denies the rest")
    func asksQueue() {
        let gate = ACAutomationServer.PumpConsentGate()
        let a = UUID(), b = UUID()
        let aBox = ResultBox(), bBox = ResultBox()
        asking(gate, a, "a", into: aBox)
        Thread.sleep(forTimeInterval: 0.05)
        asking(gate, b, "b", into: bBox)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(gate.takePending()?.id == a)
        #expect(gate.takePending()?.id == b)
        gate.deliver(1, to: a)
        #expect(aBox.wait() == .some(1))
        #expect(bBox.result == nil)
        gate.failAll()
        #expect(bBox.wait() == .some(nil))
        #expect(gate.takePending() == nil)
    }
}
