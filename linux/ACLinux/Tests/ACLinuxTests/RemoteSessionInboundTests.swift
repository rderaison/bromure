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
    static func session() async throws -> NIOAsyncTestingChannel {
        let h = SSHPTYSessionHandler(menuExe: "/nonexistent", user: "nobody", controlSocketPath: "/nonexistent.sock")
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

    @Test func pastTheCapTheChannelCloses() async throws {
        let ch = try await Self.session()
        for _ in 0..<((SSHPTYSessionHandler.maxPendingInbound >> 16) + 2) { try await Self.send(ch, 64 << 10) }
        #expect(await Self.closes(ch, within: 5), "more than the cap before exec: closed")
    }
}
