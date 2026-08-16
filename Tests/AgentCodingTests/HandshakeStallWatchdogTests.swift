import Foundation
import Testing
import NIOCore
import NIOEmbedded
@testable import bromure_ac

/// The SSH handshake watchdog must abort only on a genuine *stall*, never on a
/// slow-but-progressing link — that's what keeps a bad connection (a plane, a
/// congested relay) alive instead of dropping it on a fixed deadline.
@Suite("SSH handshake stall watchdog")
struct HandshakeStallWatchdogTests {

    /// An active EmbeddedChannel with the watchdog installed (connecting is what
    /// flips `isActive` and fires `channelActive`, which arms the timer).
    private func activeChannel(idle: TimeAmount) throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandler(
            HandshakeStallWatchdog(idle: idle, label: "test"),
            name: SSHConnection.watchdogName)
        try ch.connect(to: SocketAddress(ipAddress: "10.0.0.1", port: 22)).wait()
        return ch
    }

    @Test("Fires after the idle window when no data arrives")
    func firesOnIdle() throws {
        let ch = try activeChannel(idle: .seconds(20))
        #expect(ch.isActive)

        ch.embeddedEventLoop.advanceTime(by: .seconds(19))
        #expect(ch.isActive, "must not fire before the idle window elapses")

        ch.embeddedEventLoop.advanceTime(by: .seconds(2))
        #expect(!ch.isActive, "must close after 20s of inbound silence")
        _ = try? ch.finish()
    }

    @Test("Inbound data keeps resetting the timer — a slow link survives")
    func resetsOnProgress() throws {
        let ch = try activeChannel(idle: .seconds(20))

        // 6 rounds of "15s pass, then a packet arrives" — 90s of total elapsed
        // time, well past any fixed deadline, but never 20s of silence.
        for _ in 0..<6 {
            ch.embeddedEventLoop.advanceTime(by: .seconds(15))
            #expect(ch.isActive, "a progressing handshake must not be dropped")
            var buf = ch.allocator.buffer(capacity: 8)
            buf.writeString("packet")
            try ch.writeInbound(buf)          // channelRead → re-arm the timer
        }
        #expect(ch.isActive)

        // Now go silent past the idle window: it finally gives up.
        ch.embeddedEventLoop.advanceTime(by: .seconds(21))
        #expect(!ch.isActive, "a true stall (no data for 20s) still closes")
        _ = try? ch.finish()
    }

    @Test("Once removed (handshake done), it never fires on idle")
    func stopsAfterRemoval() throws {
        let ch = try activeChannel(idle: .seconds(20))

        // Same removal the connection does once auth completes.
        let removed = ch.pipeline.removeHandler(name: SSHConnection.watchdogName)
        ch.embeddedEventLoop.run()
        try removed.wait()

        // Long silence on the live connection is normal — it must stay up.
        ch.embeddedEventLoop.advanceTime(by: .seconds(120))
        #expect(ch.isActive, "removed watchdog must not close an idle live link")
        _ = try? ch.finish()
    }
}
