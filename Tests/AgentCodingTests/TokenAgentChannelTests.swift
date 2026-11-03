import Foundation
import Testing
@testable import bromure_ac

/// The token agents' line channel (TokenAgentChannel), over a socketpair
/// standing in for the vsock connection.
@MainActor
@Suite("Token agent channel")
struct TokenAgentChannelTests {
    struct Dropped: Error {}

    private static func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// The agent's side: answer each request line with `reply`.
    private static func agent(_ fd: Int32, reply: @escaping ([String: Any]) -> [String: Any]) {
        Thread.detachNewThread {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { close(fd); return }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0a) {
                    let line = buf[buf.startIndex..<nl]
                    buf = Data(buf[(nl + 1)...])
                    let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    var out = try! JSONSerialization.data(withJSONObject: reply(req))
                    out.append(0x0a)
                    out.withUnsafeBytes { _ = write(fd, $0.baseAddress!, out.count) }
                }
            }
        }
    }

    @Test("a request gets its reply; a dropped agent fails the caller and the channel")
    func roundTripAndDrop() async throws {
        let ch = TokenAgentChannel(disconnectedError: Dropped())
        let (host, guest) = Self.pair()
        Self.agent(guest) { req in ["ok": true, "echo": req["op"] as? String ?? ""] }
        ch.accept(fd: host, owner: nil)
        #expect(ch.isConnected)
        let r = try await ch.rpc(["op": "read"])
        #expect(r["echo"] as? String == "read")
        ch.stop()
        #expect(!ch.isConnected)
        await #expect(throws: Dropped.self) { try await ch.rpc(["op": "read"]) }
    }

    @Test("a reconnecting agent replaces the old connection without the old one's end taking the new down")
    func reconnect() async throws {
        let ch = TokenAgentChannel(disconnectedError: Dropped())
        let (h1, g1) = Self.pair()
        Self.agent(g1) { _ in ["ok": true, "n": 1] }
        ch.accept(fd: h1, owner: nil)
        let (h2, g2) = Self.pair()
        Self.agent(g2) { _ in ["ok": true, "n": 2] }
        ch.accept(fd: h2, owner: nil)
        // Let the first connection's cancel land on the main queue.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ch.isConnected)
        let r = try await ch.rpc(["op": "read"])
        #expect(r["n"] as? Int == 2)
        ch.stop()
    }
}
