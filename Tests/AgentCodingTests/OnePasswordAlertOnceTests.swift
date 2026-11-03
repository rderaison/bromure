import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "A failing 1Password read shows the error alert again
/// on every live credential push". Whether the failure had been reported
/// lived inside the refresh task, and every live push (a credential save, a
/// model restage, a kubeconfig rewrite) restarts it -- so the app-modal
/// alert came back each time while the reference kept failing.
@Suite("1Password refresh: a failing reference is reported once")
@MainActor
struct OnePasswordAlertOnceTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var fail: Set<String> = []
        var missing = false
        var reads = 0
        func read(_ ref: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if missing { throw OnePasswordCLI.OpError.notInstalled }
            if fail.contains(ref) { throw OnePasswordCLI.OpError.readFailed(ref: ref, stderr: "not signed in") }
            return "secret-" + ref
        }
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    private func entries(_ refs: [String]) -> [TokenMap.Entry] {
        refs.map { TokenMap.Entry(fake: "brm-\($0)", real: $0, host: "api.example.com") }
    }

    @Test("restarts don't re-alert; success, a changed reference, or a new session re-arm it")
    func alertOnce() async throws {
        let box = Box()
        let loop = OnePasswordRefresher(read: { try box.read($0) })
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        var alerts: [String] = []
        func start(_ refs: [String]) async throws {
            swapper.setMap(TokenMap(entries: entries(refs)), for: pid)
            let before = box.readCount
            loop.start(profileID: pid, refs: OnePasswordRefresher.refs(in: entries(refs)), swapper: swapper,
                       onFirstError: { e in alerts.append("\(e)") })
            for _ in 0..<200 where box.readCount < before + refs.count { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        box.fail = ["op://v/a/t"]
        try await start(["op://v/a/t"])
        #expect(alerts.count == 1)
        // Live pushes while it keeps failing: no new alert.
        try await start(["op://v/a/t"])
        try await start(["op://v/a/t"])
        #expect(alerts.count == 1)
        // A second reference that fails is its own alert, once.
        box.fail.insert("op://v/b/t")
        try await start(["op://v/a/t", "op://v/b/t"])
        try await start(["op://v/a/t", "op://v/b/t"])
        #expect(alerts.count == 2)
        // It worked once: a later failure is news again.
        box.fail.remove("op://v/a/t")
        try await start(["op://v/a/t", "op://v/b/t"])
        box.fail.insert("op://v/a/t")
        try await start(["op://v/a/t", "op://v/b/t"])
        #expect(alerts.count == 3)
        // Changed away and back: told again.
        try await start(["op://v/b/t"])
        try await start(["op://v/a/t", "op://v/b/t"])
        #expect(alerts.count == 4)
        // A missing CLI: once, whatever reference.
        box.missing = true
        try await start(["op://v/a/t", "op://v/b/t"])
        try await start(["op://v/a/t", "op://v/b/t"])
        #expect(alerts.count == 5)
        // The session ends: a new one tells again.
        loop.stop(profileID: pid)
        try await start(["op://v/a/t", "op://v/b/t"])
        #expect(alerts.count == 6)
        loop.stop(profileID: pid)
    }
}
