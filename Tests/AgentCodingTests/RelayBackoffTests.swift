import Foundation
import Testing
@testable import bromure_ac

/// The fat client's browser-mcp relay redialed every 0.5-1 s forever: against
/// a server that refuses the relay (the Linux server has no resolver for it)
/// that was thousands of refused channels an hour, each a socket on the
/// server. Failed dials and channels that drop at once now back off to 30 s.
@Suite("Browser-MCP relay redial backoff")
struct RelayBackoffTests {
    @Test("failed dials and instant drops double the wait up to 30 s; a channel that lived resets it")
    func backoff() {
        var b = RelayBackoff()
        let waits = (0..<10).map { _ in b.next(lived: 0) }
        #expect(waits.prefix(7) == [0.5, 1, 2, 4, 8, 16, 30])
        #expect(waits.suffix(3).allSatisfy { $0 == 30 })
        #expect(b.next(lived: 0.3) == 30)              // a channel that dropped at once
        #expect(b.next(lived: 60) == 0.5)              // one that lived resets it
        #expect(b.next(lived: 0) == 0.5 && b.next(lived: 0) == 1)
    }

    @Test("the relay loop sleeps by the backoff, never a fixed interval")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BrowserMCPRelayClient.swift"), encoding: .utf8)
        #expect(!src.contains("Thread.sleep(forTimeInterval: 1.0)") && !src.contains("Thread.sleep(forTimeInterval: 0.5)"))
        #expect(src.contains("backoff.next(lived: 0)") && src.contains("backoff.next(lived: Date().timeIntervalSince(opened))"))
    }
}
