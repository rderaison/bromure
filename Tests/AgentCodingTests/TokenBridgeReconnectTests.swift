import Foundation
import Testing
@testable import bromure_ac

/// The token bridges (SubscriptionTokenBridge, CodexTokenBridge) over a
/// socketpair standing in for the vsock connection. The agent reconnects
/// every 2 s after a drop; a reconnect used to let the replaced
/// connection's cancel handler (run later on the main queue) mark the new
/// connection disconnected, and left the old connection's waiting requests
/// to be matched to the new connection's replies.
@MainActor
@Suite("Token bridge reconnect")
struct TokenBridgeReconnectTests {
    private static func pair() -> (host: Int32, guest: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// The agent's side: answer every request line with `reply`; closes its
    /// end when the host's goes away.
    private static func agent(_ fd: Int32, reply: [String: Any]) {
        var out = try! JSONSerialization.data(withJSONObject: reply)
        out.append(0x0a)
        Thread.detachNewThread {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { close(fd); return }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0a) {
                    buf = Data(buf[(nl + 1)...])
                    out.withUnsafeBytes { _ = write(fd, $0.baseAddress!, out.count) }
                }
            }
        }
    }

    private static func claudeReply(_ tag: String) -> [String: Any] {
        ["ok": true, "access": "access-\(tag)", "refresh": "refresh-\(tag)"]
    }

    private static func codexReply(_ tag: String) -> [String: Any] {
        ["ok": true, "access": "access-\(tag)", "refresh": "refresh-\(tag)", "id_token": "id-\(tag)"]
    }

    /// Lets queued main-queue work (a replaced source's cancel handler) run.
    private static func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("Claude: the replaced connection's cancel doesn't take the new one down")
    func claudeReconnectKeepsNewConnection() async throws {
        let bridge = SubscriptionTokenBridge(testingWithoutListener: ())
        let a = Self.pair(); Self.agent(a.guest, reply: Self.claudeReply("one"))
        bridge.attach(fd: a.host, owner: nil)
        #expect(try await bridge.read()?.access == "access-one")
        let b = Self.pair(); Self.agent(b.guest, reply: Self.claudeReply("two"))
        bridge.attach(fd: b.host, owner: nil)
        try await Self.settle()
        #expect(bridge.isConnected)
        #expect(try await bridge.read()?.access == "access-two")
        bridge.stop()
        #expect(!bridge.isConnected)
    }

    @Test("Claude: a reconnect fails the old connection's waiting request; the new reply is the new request's")
    func claudeReconnectFailsOldPending() async throws {
        let bridge = SubscriptionTokenBridge(testingWithoutListener: ())
        let silent = Self.pair()   // an agent that never answers
        bridge.attach(fd: silent.host, owner: nil)
        let old = Task { try await bridge.read() }
        try await Self.settle()
        let b = Self.pair(); Self.agent(b.guest, reply: Self.claudeReply("two"))
        bridge.attach(fd: b.host, owner: nil)
        await #expect(throws: SubscriptionTokenBridge.BridgeError.self) { _ = try await old.value }
        #expect(try await bridge.read()?.access == "access-two")
        bridge.stop()
        close(silent.guest)
    }

    @Test("Claude: an agent that drops ends the connection")
    func claudeDrop() async throws {
        let bridge = SubscriptionTokenBridge(testingWithoutListener: ())
        let a = Self.pair()
        bridge.attach(fd: a.host, owner: nil)
        #expect(bridge.isConnected)
        close(a.guest)
        try await Self.settle()
        #expect(!bridge.isConnected)
        await #expect(throws: SubscriptionTokenBridge.BridgeError.self) { _ = try await bridge.read() }
    }

    @Test("Codex: the replaced connection's cancel doesn't take the new one down")
    func codexReconnectKeepsNewConnection() async throws {
        let bridge = CodexTokenBridge(testingWithoutListener: ())
        let a = Self.pair(); Self.agent(a.guest, reply: Self.codexReply("one"))
        bridge.attach(fd: a.host, owner: nil)
        #expect(try await bridge.read()?.idToken == "id-one")
        let b = Self.pair(); Self.agent(b.guest, reply: Self.codexReply("two"))
        bridge.attach(fd: b.host, owner: nil)
        try await Self.settle()
        #expect(bridge.isConnected)
        #expect(try await bridge.read()?.idToken == "id-two")
        bridge.stop()
        #expect(!bridge.isConnected)
    }

    @Test("Codex: a reconnect fails the old connection's waiting request; the new reply is the new request's")
    func codexReconnectFailsOldPending() async throws {
        let bridge = CodexTokenBridge(testingWithoutListener: ())
        let silent = Self.pair()
        bridge.attach(fd: silent.host, owner: nil)
        let old = Task { try await bridge.read() }
        try await Self.settle()
        let b = Self.pair(); Self.agent(b.guest, reply: Self.codexReply("two"))
        bridge.attach(fd: b.host, owner: nil)
        await #expect(throws: CodexTokenBridge.BridgeError.self) { _ = try await old.value }
        #expect(try await bridge.read()?.idToken == "id-two")
        bridge.stop()
        close(silent.guest)
    }
}
