import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSH
@testable import bromure_ac

/// The fat-client dialer's fd → channel pump read the app's side as fast as
/// it could and queued every chunk on the channel: a server that stopped
/// taking data made it buffer the app's whole output in RAM. It now keeps
/// one chunk in flight, reading the next once the channel has taken it.
@Suite("Fat-client dialer: the fd → channel pump waits for the channel")
struct DialerPumpBackpressureTests {
    /// Holds every write's promise (a channel that hasn't taken the data).
    private final class HeldWrites: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = SSHChannelData
        private let lock = NSLock()
        private var held: [EventLoopPromise<Void>] = []
        private var writes = 0
        /// Writes received so far.
        var count: Int { lock.withLock { writes } }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            lock.withLock { writes += 1; held.append(promise ?? context.eventLoop.makePromise()) }
        }
        func flush(context: ChannelHandlerContext) {}
        func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }
        /// Completes the oldest held write.
        func release() { lock.withLock { held.isEmpty ? nil : held.removeFirst() }?.succeed(()) }
        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            let pending = lock.withLock { () -> [EventLoopPromise<Void>] in defer { held.removeAll() }; return held }
            for p in pending { p.fail(ChannelError.ioOnClosedChannel) }
            context.close(mode: mode, promise: promise)
        }
    }

    @Test("one chunk in flight until the channel takes it, then the next")
    func oneChunkInFlight() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // pair: [pump fd the handler owns, the app's end]; chan: the channel's own fd.
        var pair: [Int32] = [0, 0], chan: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &chan)
        defer { close(pair[1]); close(chan[1]) }
        // The writer below may still be writing when the pump closes its end.
        var one: Int32 = 1
        for fd in pair + chan { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let held = HeldWrites()
        let pump = ExecFDPumpHandler(command: "test", fd: pair[0])
        let channel = try await NIOPipeBootstrap(group: group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandlers([held, pump]) }
            }
            .takingOwnershipOfDescriptor(inputOutput: chan[0]).get()
        // The app writes 1 MB, far more than one 64 KB read.
        let app = pair[1]
        _ = fcntl(app, F_SETFL, fcntl(app, F_GETFL) | O_NONBLOCK)
        Thread.detachNewThread {
            let chunk = [UInt8](repeating: 0x61, count: 64 * 1024)
            var sent = 0
            while sent < 1 << 20 {
                let n = write(app, chunk, chunk.count)
                if n > 0 { sent += n } else if errno == EAGAIN { usleep(1000) } else { break }
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        let whileHeld = held.count
        held.release()
        try await Task.sleep(for: .milliseconds(200))
        let afterOne = held.count
        try? await channel.close()
        try? await group.shutdownGracefully()
        #expect(whileHeld == 1, "\(whileHeld) chunks queued while the channel held the first")
        #expect(afterOne == 2, "the pump didn't read on once the channel took its chunk")
    }
}
