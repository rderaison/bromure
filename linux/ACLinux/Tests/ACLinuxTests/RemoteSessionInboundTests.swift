import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import ACLinux

/// A session channel's bytes before it asks for exec or a shell wait for the
/// fd that request opens (SSHPTYSessionHandler.pendingInbound), and only up
/// to a cap: a channel that keeps sending without one is closed.
@Suite("Remote session: bytes before exec")
struct RemoteSessionInboundTests {
    static func session(_ budget: RemoteConnectionBudget? = nil) async throws -> NIOAsyncTestingChannel {
        let h = SSHPTYSessionHandler(menuExe: "/nonexistent", user: "nobody", controlSocketPath: "/nonexistent.sock",
                                     budget: budget)
        let ch = try await NIOAsyncTestingChannel(handler: h)
        // Active, as an opened session channel is (closing makes it inactive).
        try await ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22))
        #expect(ch.isActive)
        return ch
    }

    static func send(_ ch: NIOAsyncTestingChannel, _ n: Int) async throws {
        var buf = ch.allocator.buffer(capacity: n)
        buf.writeRepeatingByte(0x61, count: n)
        try await ch.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buf)))
    }

    /// Waits up to `seconds` for the channel to close.
    static func closes(_ ch: NIOAsyncTestingChannel, within seconds: Double) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if !ch.isActive { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !ch.isActive
    }

    @Test func aFewBytesBeforeExecWait() async throws {
        let ch = try await Self.session()
        try await Self.send(ch, 64 << 10)
        #expect(!(await Self.closes(ch, within: 0.5)), "a little early input is fine")
        _ = try? await ch.close()
    }

    /// The connection's channels share one budget: under each one's cap,
    /// together they still can't hold more than RemoteConnectionBudget's.
    @Test func aConnectionsChannelsShareOneBudget() async throws {
        let budget = RemoteConnectionBudget()
        let per = 900 << 10   // under one channel's 1 MiB
        var chans: [NIOAsyncTestingChannel] = []
        for _ in 0..<(RemoteConnectionBudget.maxPendingBytes / per) {
            let ch = try await Self.session(budget)
            try await Self.send(ch, per)
            chans.append(ch)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let allUp = chans.allSatisfy { $0.isActive }
        #expect(allUp, "within the connection's budget")
        let over = try await Self.session(budget)
        try await Self.send(over, per)
        #expect(await Self.closes(over, within: 5), "past the connection's budget: closed")
        #expect(budget.pendingBytes <= RemoteConnectionBudget.maxPendingBytes)
        // A channel that closes gives its share back.
        _ = try? await chans[0].close()
        for _ in 0..<50 where budget.pendingBytes > (chans.count - 1) * per { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(budget.pendingBytes == (chans.count - 1) * per)
        for c in chans.dropFirst() { _ = try? await c.close() }
    }

    @Test func aConnectionOpensAtMostItsChannels() {
        let b = RemoteConnectionBudget()
        for _ in 0..<RemoteConnectionBudget.maxChannels { #expect(b.openChannel()) }
        #expect(!b.openChannel(), "one more is refused")
        b.closeChannel()
        #expect(b.openChannel(), "a closed one makes room")
        #expect(b.openChannels == RemoteConnectionBudget.maxChannels)
    }

    @Test func pastTheCapTheChannelCloses() async throws {
        let ch = try await Self.session()
        for _ in 0..<((SSHPTYSessionHandler.maxPendingInbound >> 16) + 2) { try await Self.send(ch, 64 << 10) }
        #expect(await Self.closes(ch, within: 5), "more than the cap before exec: closed")
    }
}
