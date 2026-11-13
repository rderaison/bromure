import Foundation
import Testing
@testable import SandboxEngine

/// Several windows can fail to boot while the host is offline; each must be
/// reopened on the next network change, and one window opening must not
/// cancel another's retry.
@Suite("Network retry queue")
struct NetworkRetryQueueTests {
    @Test("Two failed launches are both retried, in launch order")
    func bothRetried() {
        var queue = NetworkRetryQueue()
        var ran: [String] = []
        queue.register(UUID(), { ran.append("first") })
        queue.register(UUID(), { ran.append("second") })
        for retry in queue.takeAll() { retry() }
        #expect(ran == ["first", "second"])
        #expect(queue.isEmpty)
    }

    @Test("Another launch opening clears only its own retry")
    func successCancelsOnlyItsOwn() {
        var queue = NetworkRetryQueue()
        var ran: [String] = []
        let failed = UUID(), opened = UUID()
        queue.register(failed, { ran.append("failed") })
        queue.register(opened, { ran.append("opened") })
        queue.cancel(opened)
        for retry in queue.takeAll() { retry() }
        #expect(ran == ["failed"])
    }

    @Test("A launch failing again replaces its own retry, not another's")
    func refailureReplacesOwnEntry() {
        var queue = NetworkRetryQueue()
        var ran: [String] = []
        let a = UUID(), b = UUID()
        queue.register(a, { ran.append("a1") })
        queue.register(b, { ran.append("b") })
        queue.register(a, { ran.append("a2") })
        for retry in queue.takeAll() { retry() }
        #expect(ran == ["a2", "b"])
    }

    @Test("A launch already retried by a network change is no longer pending")
    func takenLaunchNotPending() {
        var queue = NetworkRetryQueue()
        let id = UUID()
        queue.register(id, {})
        #expect(queue.contains(id))
        _ = queue.takeAll()
        #expect(!queue.contains(id))
    }

    @Test("A launch no-op cancel leaves others intact")
    func cancelUnknown() {
        var queue = NetworkRetryQueue()
        queue.register(UUID(), {})
        queue.cancel(UUID())
        #expect(!queue.isEmpty)
    }
}
