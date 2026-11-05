import CACLinuxShims
import Foundation
import NIOCore
import NIOPosix

/// A control connection as a plain blocking socket, for shared code that
/// works on the connection's fd as macOS's control server hands it over
/// (MachineLinkHub's parked links and proxied requests): one end of a
/// socketpair for `body`, the other spliced to the NIO connection until
/// either side ends.
extension ControlResponse {
    /// `head`, then the connection is `body`'s descriptor (run on a thread
    /// of its own; it owns the descriptor and closes it, now or later).
    /// An empty `head` writes nothing first: `body` answers in full. The
    /// client's end of input reaches `body` as EOF (a request answered
    /// after it), or with `closeWithClient` ends the bridge (a parked link
    /// whose machine went away: `body`'s end then reads as hung up). Either
    /// way, both ends of the pair close once either side is done.
    // @port-skip linux-only: NIO stream handoff (macOS hands the raw fd to the handler)
    public static func descriptor(head: String, closeWithClient: Bool = false,
                                  _ body: @escaping @Sendable (Int32) -> Void) -> ControlResponse {
        .streaming(head: head) { s in
            var sp: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &sp) == 0 else { return }
            let theirs = sp[1]
            let pair: Channel
            do {
                pair = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .channelInitializer { ch in ch.pipeline.addHandler(SpliceToClient(s)) }
                    .withConnectedSocket(sp[0]).get()
            } catch {
                close(sp[0]); close(theirs)
                return
            }
            Thread.detachNewThread { body(theirs) }
            // The client's bytes to `body`; its end of input is `body`'s.
            let toBody = Task {
                for await b in s.inbound { try? await pair.writeAndFlush(b) }
                if closeWithClient { try? await pair.close() } else { try? await pair.close(mode: .output) }
            }
            // Over once `body` is done with its end (the pair closes).
            try? await pair.closeFuture.get()
            toBody.cancel()
        }
    }
}

/// `body`'s bytes to the client; the pair closing (or failing) ends it.
// @port-skip linux-only: NIO stream handoff
private final class SpliceToClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let client: ControlStream
    // @port-skip linux-only: NIO stream handoff
    init(_ client: ControlStream) { self.client = client }
    // @port-skip linux-only: NIO stream handoff
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        client.channel.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }
    // @port-skip linux-only: NIO stream handoff
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // `body` closed its end (or shut it for writing): the reply is whole.
        if case ChannelEvent.inputClosed = event { context.close(promise: nil); return }
        context.fireUserInboundEventTriggered(event)
    }
    // @port-skip linux-only: NIO stream handoff
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
