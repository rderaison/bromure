import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One VM's switch port: the Unix socket QEMU's `-netdev stream,server=off`
/// connects to. Each Ethernet frame on the wire is a 4-byte big-endian
/// length followed by the frame.
///
/// `frames` yields inbound frames without the prefix; `send(_:)` adds it. A
/// frame whose length is out of bounds is skipped by its declared length
/// (logged, counted in `dropped`), so the stream never desyncs. QEMU
/// reconnects after a restore: the newest connection replaces the old one.
// @port-skip linux-only: QEMU stream netdev (macOS: VMNetSwitch's socketpair ports from VZFileHandleNetworkDeviceAttachment)
public final class StreamPort: Sendable {
    /// Ethernet header (14) at least; jumbo frames up to 64 KiB at most.
    public static let minFrame = 14
    public static let maxFrame = 65_550

    public let path: String
    public let frames: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let server: Channel
    private let peer = NIOLockedValueBox<Channel?>(nil)
    private let counters = NIOLockedValueBox<(connects: Int, dropped: Int)>((0, 0))
    private let log: @Sendable (String) -> Void

    /// Binds `path` (replacing a stale socket file) and waits for QEMU.
    // @port-skip linux-only: QEMU stream netdev
    public static func listen(path: String,
                              group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StreamPort {
        if path.utf8.count > 107 { throw MachineError.socketPathTooLong(path) }
        try? FileManager.default.removeItem(atPath: path)
        let (frames, sink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        let box = PortBox()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                        LengthPrefixedFrameDecoder(onDrop: { box.port?.dropped($0) })))
                    try ch.pipeline.syncOperations.addHandler(FrameSink(sink))
                    box.port?.attach(ch)
                }
            }
            .bind(unixDomainSocketPath: path).get()
        let port = StreamPort(path: path, frames: frames, sink: sink, server: server, log: log)
        box.port = port
        return port
    }

    // @port-skip linux-only: QEMU stream netdev
    private init(path: String, frames: AsyncStream<Data>, sink: AsyncStream<Data>.Continuation,
                 server: Channel, log: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.frames = frames
        self.sink = sink
        self.server = server
        self.log = log
    }

    /// Sends one frame to the VM; dropped if QEMU isn't connected.
    // @port-skip linux-only: QEMU stream netdev
    public func send(_ frame: Data) {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame,
              let ch = peer.withLockedValue({ $0 }) else { return }
        var buf = ch.allocator.buffer(capacity: frame.count + 4)
        buf.writeInteger(UInt32(frame.count))
        buf.writeBytes(frame)
        ch.writeAndFlush(buf, promise: nil)
    }

    // @port-skip linux-only: QEMU stream netdev
    public var isConnected: Bool { peer.withLockedValue { $0?.isActive ?? false } }
    // @port-skip linux-only: QEMU stream netdev
    public var connects: Int { counters.withLockedValue { $0.connects } }
    // @port-skip linux-only: QEMU stream netdev
    public var dropped: Int { counters.withLockedValue { $0.dropped } }

    // @port-skip linux-only: QEMU stream netdev
    public func close() async {
        peer.withLockedValue { $0 }?.close(promise: nil)
        try? await server.close()
        sink.finish()
        try? FileManager.default.removeItem(atPath: path)
    }

    // @port-skip linux-only: QEMU stream netdev
    fileprivate func attach(_ ch: Channel) {
        let old = peer.withLockedValue { p -> Channel? in defer { p = ch }; return p }
        old?.close(promise: nil)
        counters.withLockedValue { $0.connects += 1 }
        log("stream port \(path): QEMU connected")
    }

    // @port-skip linux-only: QEMU stream netdev
    fileprivate func dropped(_ length: UInt32) {
        counters.withLockedValue { $0.dropped += 1 }
        log("stream port \(path): dropped a frame of declared length \(length)")
    }
}

/// Lets the child initializer reach the port that's created after the bind.
// @port-skip linux-only: QEMU stream netdev
private final class PortBox: @unchecked Sendable {
    // Written once, before QEMU can connect (it starts after `listen` returns).
    var port: StreamPort?
}

/// `u32 length (big-endian) + frame`. Out-of-bounds lengths are skipped
/// byte for byte as they arrive, so framing survives a bad frame.
// @port-skip linux-only: QEMU stream netdev framing
struct LengthPrefixedFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let onDrop: @Sendable (UInt32) -> Void
    private var skipping = 0

    // @port-skip linux-only: QEMU stream netdev framing
    init(onDrop: @escaping @Sendable (UInt32) -> Void) { self.onDrop = onDrop }

    // @port-skip linux-only: QEMU stream netdev framing
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if skipping > 0 {
            let n = min(skipping, buffer.readableBytes)
            buffer.moveReaderIndex(forwardBy: n)
            skipping -= n
            return skipping == 0 ? .continue : .needMoreData
        }
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
        if length < StreamPort.minFrame || length > StreamPort.maxFrame {
            buffer.moveReaderIndex(forwardBy: 4)
            skipping = Int(length)
            onDrop(length)
            return .continue
        }
        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: Int(length))!))
        return .continue
    }

    // @port-skip linux-only: QEMU stream netdev framing
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer,
                             seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}

/// Inbound frames into the port's stream.
// @port-skip linux-only: QEMU stream netdev
private final class FrameSink: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let sink: AsyncStream<Data>.Continuation

    // @port-skip linux-only: QEMU stream netdev
    init(_ sink: AsyncStream<Data>.Continuation) { self.sink = sink }

    // @port-skip linux-only: QEMU stream netdev
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        sink.yield(Data(unwrapInboundIn(data).readableBytesView))
    }

    // @port-skip linux-only: QEMU stream netdev
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
