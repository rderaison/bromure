import Foundation
import NIOCore
import NIOPosix

/// One asynchronous QMP event (`{"event": …, "data": …, "timestamp": …}`).
// @port-skip linux-only: QMP is QEMU's control protocol
public struct QMPEvent: Sendable, Equatable {
    public let name: String
    public let data: JSONValue
    /// Seconds since the epoch, from QEMU's timestamp.
    public let timestamp: Double
}

// @port-skip linux-only: QMP is QEMU's control protocol
public enum QMPError: Error, Equatable, CustomStringConvertible {
    case timeout(String)
    /// QEMU answered `{"error": {"class": …, "desc": …}}`.
    case commandFailed(command: String, errorClass: String, description: String)
    case disconnected
    case protocolError(String)

    // @port-skip linux-only: QMP plumbing
    public var description: String {
        switch self {
        case .timeout(let what): return "QMP timeout: \(what)"
        case .commandFailed(let c, let k, let d): return "QMP \(c) failed: \(k): \(d)"
        case .disconnected: return "QMP connection closed"
        case .protocolError(let m): return "QMP protocol error: \(m)"
        }
    }
}

/// An async/await QMP client over QEMU's Unix socket (`-qmp unix:…,server=on`).
///
/// Commands carry an `id` that QEMU echoes, so replies are matched to their
/// command even with events interleaved. Events go to `events`, a single-
/// consumer stream that buffers the most recent 1024.
// @port-skip linux-only: QMP is QEMU's control protocol (VZ is driven in-process)
public actor QMPClient {
    public nonisolated let events: AsyncStream<QMPEvent>
    /// The greeting's `QMP.version` object.
    public private(set) var version: JSONValue = .null

    private let channel: Channel
    private let eventsContinuation: AsyncStream<QMPEvent>.Continuation
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var commands: [String: String] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var greeting: CheckedContinuation<JSONValue, Error>?
    private var greeted: JSONValue?
    private var closed = false
    private var nextID = 0

    /// Connects, reads the greeting and negotiates capabilities.
    // @port-skip linux-only: QMP is QEMU's control protocol
    public static func connect(socketPath: String,
                               group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                               timeout: Duration = .seconds(10)) async throws -> QMPClient {
        let (lines, linesCont) = AsyncStream<ByteBuffer>.makeStream()
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(max(1, timeout.components.seconds))))
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineFrameDecoder()))
                    try ch.pipeline.syncOperations.addHandler(LineForwarder(linesCont))
                }
            }
            .connect(unixDomainSocketPath: socketPath).get()
        let client = QMPClient(channel: channel)
        await client.startReading(lines)
        do {
            let hello = try await client.awaitGreeting(timeout: timeout)
            await client.setVersion(hello["version"] ?? .null)
            _ = try await client.execute("qmp_capabilities", timeout: timeout)
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    // @port-skip linux-only: QMP plumbing
    private init(channel: Channel) {
        self.channel = channel
        (events, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    // @port-skip linux-only: QMP plumbing
    private func setVersion(_ v: JSONValue) { version = v }

    // @port-skip linux-only: QMP plumbing
    private func startReading(_ lines: AsyncStream<ByteBuffer>) {
        Task { [weak self] in
            for await line in lines { await self?.handle(line) }
            await self?.connectionClosed()
        }
    }

    /// Runs `command` and returns its `return` value.
    // @port-skip linux-only: QMP is QEMU's control protocol
    @discardableResult
    public func execute(_ command: String, arguments: JSONValue? = nil,
                        timeout: Duration = .seconds(30)) async throws -> JSONValue {
        if closed { throw QMPError.disconnected }
        nextID += 1
        let id = "acl-\(nextID)"
        var msg: [String: JSONValue] = ["execute": .string(command), "id": .string(id)]
        if let arguments { msg["arguments"] = arguments }
        var bytes = try JSONEncoder().encode(JSONValue.object(msg))
        bytes.append(UInt8(ascii: "\n"))
        let buffer = channel.allocator.buffer(bytes: bytes)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            commands[id] = command
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                await self?.finish(id, .failure(QMPError.timeout(command)))
            }
            channel.writeAndFlush(buffer).whenFailure { [weak self] _ in
                Task { await self?.finish(id, .failure(QMPError.disconnected)) }
            }
        } as JSONValue
    }

    /// Runs `command` with typed arguments and decodes its `return` as `R`.
    // @port-skip linux-only: QMP is QEMU's control protocol
    public func execute<R: Decodable>(_ command: String, arguments: (some Encodable)? = nil as JSONValue?,
                                      as type: R.Type, timeout: Duration = .seconds(30)) async throws -> R {
        let args = try arguments.map { try JSONValue(encoding: $0) }
        return try await execute(command, arguments: args, timeout: timeout).decode(as: R.self)
    }

    // @port-skip linux-only: QMP plumbing
    public func close() {
        guard !closed else { return }
        channel.close(promise: nil)
        connectionClosed()
    }

    // @port-skip linux-only: QMP plumbing
    private func awaitGreeting(timeout: Duration) async throws -> JSONValue {
        if let greeted { return greeted }
        return try await withCheckedThrowingContinuation { cont in
            greeting = cont
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.failGreeting(QMPError.timeout("greeting"))
            }
        } as JSONValue
    }

    // @port-skip linux-only: QMP plumbing
    private func failGreeting(_ error: Error) {
        greeting?.resume(throwing: error)
        greeting = nil
    }

    // @port-skip linux-only: QMP plumbing
    private func finish(_ id: String, _ result: Result<JSONValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        commands.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    // @port-skip linux-only: QMP plumbing
    private func handle(_ line: ByteBuffer) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.readableBytesView)) else { return }
        if let hello = msg["QMP"] {
            greeted = hello
            greeting?.resume(returning: hello)
            greeting = nil
        } else if let name = msg["event"]?.stringValue {
            let ts = msg["timestamp"]
            let t = (ts?["seconds"]?.numberValue ?? 0) + (ts?["microseconds"]?.numberValue ?? 0) / 1e6
            eventsContinuation.yield(QMPEvent(name: name, data: msg["data"] ?? .null, timestamp: t))
        } else if let id = msg["id"]?.stringValue {
            if let r = msg["return"] {
                finish(id, .success(r))
            } else if let e = msg["error"] {
                finish(id, .failure(QMPError.commandFailed(
                    command: commands[id] ?? id, errorClass: e["class"]?.stringValue ?? "?",
                    description: e["desc"]?.stringValue ?? "")))
            }
        }
    }

    // @port-skip linux-only: QMP plumbing
    private func connectionClosed() {
        guard !closed else { return }
        closed = true
        for id in Array(pending.keys) { finish(id, .failure(QMPError.disconnected)) }
        failGreeting(QMPError.disconnected)
        eventsContinuation.finish()
    }
}

/// Splits the inbound byte stream on "\n" (QMP is newline-delimited JSON).
// @port-skip linux-only: QMP framing
struct LineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    // @port-skip linux-only: QMP framing
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let nl = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
        let length = nl - buffer.readerIndex
        let line = buffer.readSlice(length: length)!
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    // @port-skip linux-only: QMP framing
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer,
                             seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}

/// Hands each line to the client's reader, in order.
// @port-skip linux-only: QMP framing
final class LineForwarder: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let sink: AsyncStream<ByteBuffer>.Continuation

    // @port-skip linux-only: QMP framing
    init(_ sink: AsyncStream<ByteBuffer>.Continuation) { self.sink = sink }

    // @port-skip linux-only: QMP framing
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        sink.yield(unwrapInboundIn(data))
    }

    // @port-skip linux-only: QMP framing
    func channelInactive(context: ChannelHandlerContext) {
        sink.finish()
        context.fireChannelInactive()
    }

    // @port-skip linux-only: QMP framing
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
