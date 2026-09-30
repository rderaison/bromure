import AppKit
import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

// Switching back to a chat must show what was already downloaded at once —
// not after the tunnel's round trips — flagged as catching up until the
// first read of this showing lands.

@Suite("Chat warm start")
@MainActor
struct ChatWarmStartTests {

    private final class Provider: BeautifiedTranscriptProvider {
        let key: String
        let delay: UInt64
        init(key: String, delay: UInt64) { self.key = key; self.delay = delay }
        var accent: Color { .blue }
        var historyCacheKey: String? { key }
        func activeTabIndex() -> Int? { 0 }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if command.contains("capture-pane") { return "" }
            if command.contains("pane_current_path") { return "/home/ubuntu/p\n0\n" }
            let body = #"{"type":"user","message":{"role":"user","content":"hello there"},"timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
            let n = body.utf8.count
            return "/home/ubuntu/.claude/projects/p/s.jsonl\n\n\(n)\n0\n\(n)\n" + body
        }
    }

    private func waitFor(_ seconds: Double, _ cond: () -> Bool) async {
        let until = Date().addingTimeInterval(seconds)
        while !cond(), Date() < until { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test("a chat shown again renders its cached history before any read, then catches up")
    func cachedHistoryShowsAtOnce() async {
        let key = "test-\(UUID().uuidString)"
        let first = BeautifiedSessionModel(provider: Provider(key: key, delay: 0))
        first.start()
        await waitFor(5) { !first.items.isEmpty }
        #expect(!first.items.isEmpty)
        first.stop()

        // The tunnel is slow now: every read takes 3 s.
        let again = BeautifiedSessionModel(provider: Provider(key: key, delay: 3_000_000_000))
        again.start()
        await waitFor(1) { !again.items.isEmpty }
        #expect(!again.items.isEmpty)
        #expect(again.catchingUp)
        again.stop()
    }
}
