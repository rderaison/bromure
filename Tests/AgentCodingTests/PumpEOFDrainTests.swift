import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSH
@testable import bromure_ac

/// 5.4.0 on a remote server: 7.7 GB peak, a 1.3 GB NIO task queue and 3.4 M
/// callbacks on five pending writes. A bridged fd at EOF stays readable, so
/// its read source fired again on every pass until finish() cancelled it,
/// and finish() waited for the channel's last write. While a slow client
/// took that write, every pass queued another event-loop task and another
/// callback on it. The drain now runs once and stops the source.
@Suite("SSH bridge: an fd at EOF drains once")
struct PumpEOFDrainTests {
    /// Swallows every write and holds its promise, like a client that hasn't
    /// taken the data yet; fails them on close so none leaks.
    private final class HeldWrites: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = SSHChannelData
        var held: [EventLoopPromise<Void>] = []
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if let promise { held.append(promise) }
        }
        func flush(context: ChannelHandlerContext) {}
        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            for p in held { p.fail(ChannelError.ioOnClosedChannel) }
            held.removeAll()
            context.close(mode: mode, promise: promise)
        }
        func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }
    }

    /// A Unix socket that answers its one connection with a few bytes, then
    /// closes it (EOF on the bridge's side).
    private func controlSocket() throws -> (path: String, listener: Int32) {
        let path = NSTemporaryDirectory() + "pump-eof-\(UUID().uuidString.prefix(8)).sock"
        let l = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(ok == 0)
        listen(l, 1)
        Thread.detachNewThread {
            let c = accept(l, nil, nil)
            guard c >= 0 else { return }
            _ = "HTTP/1.1 200 OK\r\n\r\nhello".withCString { write(c, $0, strlen($0)) }
            close(c)
        }
        return (path, l)
    }

    @Test("a held last write doesn't make the EOF fire the drain again")
    func eofDrainsOnce() async throws {
        let (path, listener) = try controlSocket()
        defer { close(listener); unlink(path) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var sv: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &sv)
        defer { close(sv[1]) }
        let handler = SSHPTYSessionHandler(menuExe: "/usr/bin/false", user: "test", controlSocketPath: path)
        let channel = try await NIOPipeBootstrap(group: group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([HeldWrites(), handler])
                }
            }
            .takingOwnershipOfDescriptor(inputOutput: sv[0]).get()
        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.ExecRequest(command: FatClient.controlVerb, wantReply: false))
        try await Task.sleep(for: .milliseconds(500))
        let calls = handler.drainCallsForTesting()
        try? await channel.close()
        try? await group.shutdownGracefully()
        #expect(calls == 1, "EOF reached the drain \(calls) times")
    }
}
