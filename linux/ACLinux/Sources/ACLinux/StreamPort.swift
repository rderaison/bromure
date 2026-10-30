import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One VM's switch port: the Unix socket QEMU's `-netdev stream,server=off`
/// connects to. Each Ethernet frame on the wire is a 4-byte big-endian
/// length followed by the frame.
///
/// A FramePort: `inbound` yields frames without the prefix, and stops reading
/// QEMU's socket while the switch lags (QEMU holds the frames; the guest's TCP
/// slows); `send` adds the prefix and queues, bounded, drop-counted. A frame
/// whose length is out of bounds is skipped by its declared length (logged,
/// counted in `dropped`), so the stream never desyncs. QEMU reconnects after a
/// restore: the newest connection replaces the old one, and the port carries on.
// @port-skip linux-only: QEMU stream netdev (macOS: VMNetSwitch's socketpair ports from VZFileHandleNetworkDeviceAttachment)
public final class StreamPort: FramePort {
    /// Ethernet header (14) at least; jumbo frames up to 64 KiB at most.
    public static let minFrame = 14
    public static let maxFrame = 65_550
    typealias Conn = NIOAsyncChannel<ByteBuffer, ByteBuffer>

    public let path: String
    // @port-skip linux-only: QEMU stream netdev
    public var name: String { path }
    let core: FramePortCore
    private let server: Channel
    private let current = NIOLockedValueBox<(channel: Channel?, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?, generation: Int)>((nil, nil, 0))
    private let counters = NIOLockedValueBox<(connects: Int, malformed: Int)>((0, 0))
    private let log: @Sendable (String) -> Void

    /// Binds `path` (replacing a stale socket file) and waits for QEMU.
    // @port-skip linux-only: QEMU stream netdev
    public static func listen(path: String, queueFrames: Int = FramePortCore.defaultQueueFrames,
                              group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StreamPort {
        if path.utf8.count > 107 { throw MachineError.socketPathTooLong(path) }
        try? FileManager.default.removeItem(atPath: path)
        let box = PortBox()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                        LengthPrefixedFrameDecoder(onDrop: { box.port?.malformed($0) })))
                    let conn = try Conn(wrappingChannelSynchronously: ch, configuration: .init(
                        backPressureStrategy: .init(lowWatermark: 64, highWatermark: 256)))
                    box.port?.accept(conn, ch)
                }
            }
            .bind(unixDomainSocketPath: path).get()
        let port = StreamPort(path: path, server: server, queueFrames: queueFrames, log: log, box: box)
        return port
    }

    // @port-skip linux-only: QEMU stream netdev
    private init(path: String, server: Channel, queueFrames: Int, log: @escaping @Sendable (String) -> Void, box: PortBox) {
        self.path = path
        self.server = server
        self.log = log
        let current = self.current
        core = FramePortCore(name: path, queueFrames: queueFrames) { frames in
            guard let w = current.withLockedValue({ $0.writer }) else { throw ChannelError.ioOnClosedChannel }
            try await w.write(StreamPort.encode(frames))      // suspends while QEMU isn't reading
        }
        box.port = self
    }

    /// A new QEMU connection: replace the old one and pump its frames.
    // @port-skip linux-only: QEMU stream netdev
    fileprivate func accept(_ conn: Conn, _ ch: Channel) {
        counters.withLockedValue { $0.connects += 1 }
        log("stream port \(path): QEMU connected")
        let core = self.core, current = self.current
        Task {
            try? await conn.executeThenClose { inbound, outbound in
                let (old, gen) = current.withLockedValue { c -> (Channel?, Int) in
                    let old = c.channel
                    c.channel = ch
                    c.writer = outbound
                    c.generation += 1
                    return (old, c.generation)
                }
                old?.close(promise: nil)
                // One producer at a time (FramePortCore's demand gate assumes it):
                // once QEMU has reconnected, this older pump stops delivering.
                for try await frame in inbound {
                    guard current.withLockedValue({ $0.generation }) == gen else { break }
                    guard await core.deliver(Data(frame.readableBytesView)) else { break }
                }
                current.withLockedValue { c in
                    if c.generation == gen { c.channel = nil; c.writer = nil }
                }
            }
        }
    }

    // MARK: FramePort

    // @port-skip linux-only: QEMU stream netdev
    public var inbound: FrameSequence { core.sequence }
    // @port-skip linux-only: QEMU stream netdev
    @discardableResult public func send(_ frame: Data) -> FrameSendResult {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame else { return .dropped }
        return core.send(frame)
    }
    // @port-skip linux-only: QEMU stream netdev
    public func sendWaiting(_ frame: Data) async {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame else { return }
        await core.sendWaiting(frame)
    }
    // @port-skip linux-only: QEMU stream netdev
    public var isWritable: Bool { core.isWritable }
    // @port-skip linux-only: QEMU stream netdev
    public var stats: FramePortStats { core.stats }

    /// `u32 length (big-endian) + frame` for each frame, in one buffer: the
    /// stream netdev's (and passt's) wire format.
    // @port-skip linux-only: QEMU stream netdev framing
    static func encode(_ frames: [Data]) -> ByteBuffer {
        var buf = ByteBuffer()
        buf.reserveCapacity(frames.reduce(0) { $0 + $1.count + 4 })
        for f in frames {
            buf.writeInteger(UInt32(f.count))
            buf.writeBytes(f)
        }
        return buf
    }

    // @port-skip linux-only: QEMU stream netdev
    public var isConnected: Bool { current.withLockedValue { $0.channel?.isActive ?? false } }
    // @port-skip linux-only: QEMU stream netdev
    public var connects: Int { counters.withLockedValue { $0.connects } }
    /// Inbound frames skipped for an out-of-bounds length.
    // @port-skip linux-only: QEMU stream netdev
    public var dropped: Int { counters.withLockedValue { $0.malformed } }

    // @port-skip linux-only: QEMU stream netdev
    public func close() async {
        current.withLockedValue { $0.channel }?.close(promise: nil)
        try? await server.close()
        core.finish()
        try? FileManager.default.removeItem(atPath: path)
    }

    // @port-skip linux-only: QEMU stream netdev
    fileprivate func malformed(_ length: UInt32) {
        counters.withLockedValue { $0.malformed += 1 }
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

/// Inbound frames into an AsyncStream (StreamPort, PasstUplink).
// @port-skip linux-only: QEMU stream netdev
final class FrameSink: ChannelInboundHandler, Sendable {
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
