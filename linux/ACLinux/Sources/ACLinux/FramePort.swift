import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One side of the switch: a VM's stream port or the uplink (passt, tap).
///
/// The shape follows VMNetSwitch's frame loop on macOS, with backpressure added
/// where macOS relies on the kernel dropping:
/// - **inbound** is what VMNetSwitch's `readVMLoop` (a blocking `read` per VM
///   socketpair) and `drainVmnetToVMs` (vmnet's packets-available callback)
///   produce. Here it is a bounded, lossless async sequence: when the consumer
///   lags by `highWatermark` frames, the port stops reading its socket or fd
///   (QEMU / passt / the tap then hold the data, and TCP slows), and resumes
///   below `lowWatermark`.
/// - **outbound** is what VMNetSwitch's `write(fd)` to a VM socketpair and
///   `writeToVmnet` do. Here:
///   - `send(_:)` never blocks: it queues into a bounded per-port queue and
///     drops, counted, only when that queue is full. Use it from a shared
///     reader (the uplink fanning out to VMs), so one slow destination can't
///     stall the others. That's the per-destination drop a real switch does.
///   - `sendWaiting(_:)` waits for room instead of dropping. Use it when one
///     source feeds one destination (a VM's frames to the uplink), so the
///     pressure goes back to that source alone.
///   - A writer task drains the queue with writability-aware writes.
// @port-skip linux-only: the port abstraction VMNetSwitch's core will sit on (macOS: socketpair fds + vmnet)
public protocol FramePort: AnyObject, Sendable {
    var name: String { get }
    /// Inbound frames. Single consumer.
    var inbound: FrameSequence { get }
    /// Queues a frame; `.dropped` when this port's queue is full.
    @discardableResult func send(_ frame: Data) -> FrameSendResult
    /// Queues a frame, waiting while this port's queue is full.
    func sendWaiting(_ frame: Data) async
    /// Whether `send` would queue right now.
    var isWritable: Bool { get }
    var stats: FramePortStats { get }
    /// `send`, without waking the writer: a burst of these is followed by
    /// one `flush` (the switch routes a batch, then flushes). Same queue,
    /// same order, same drop counting as `send`.
    @discardableResult func sendDeferred(_ frame: Data) -> FrameSendResult
    /// Wakes the writer for whatever `sendDeferred` queued.
    func flush()
}

// @port-skip linux-only: frame port plumbing
extension FramePort {
    // @port-skip linux-only: frame port plumbing
    @discardableResult public func sendDeferred(_ frame: Data) -> FrameSendResult { send(frame) }
    // @port-skip linux-only: frame port plumbing
    public func flush() {}
}

// @port-skip linux-only: frame port plumbing
public enum FrameSendResult: Sendable, Equatable { case queued, dropped, closed }

// @port-skip linux-only: frame port plumbing
public struct FramePortStats: Sendable, Equatable {
    public var received = 0
    public var sent = 0
    /// Frames refused by `send` because this port's queue was full.
    public var dropped = 0
    public var queued = 0
    /// Times the inbound side paused reading because the consumer lagged.
    public var inboundPauses = 0
}

/// The inbound frames of a FramePort: an NIOAsyncSequenceProducer (bounded,
/// lossless), type-erased.
// @port-skip linux-only: frame port plumbing
public struct FrameSequence: AsyncSequence, Sendable {
    public typealias Element = Data
    typealias Producer = NIOAsyncSequenceProducer<Data, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, FramePortCore.Demand>
    let producer: Producer

    // @port-skip linux-only: frame port plumbing
    public struct AsyncIterator: AsyncIteratorProtocol {
        var it: Producer.AsyncIterator
        // @port-skip linux-only: frame port plumbing
        public mutating func next() async -> Data? { await it.next() }
    }

    // @port-skip linux-only: frame port plumbing
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(it: producer.makeAsyncIterator()) }
}

/// The machinery every FramePort shares: the inbound producer with its demand
/// signal, and the bounded outbound queue with its writer task.
// @port-skip linux-only: frame port plumbing
public final class FramePortCore: Sendable {
    public static let defaultInboundLow = 256, defaultInboundHigh = 1024
    public static let defaultQueueFrames = 1024, defaultQueueBytes = 8 << 20

    // @port-skip linux-only: frame port plumbing
    final class Demand: NIOAsyncSequenceProducerDelegate, Sendable {
        let waiters = NIOLockedValueBox<(open: Bool, conts: [CheckedContinuation<Void, Never>], terminated: Bool)>((true, [], false))
        // @port-skip linux-only: frame port plumbing
        func produceMore() {
            let c = waiters.withLockedValue { s -> [CheckedContinuation<Void, Never>] in
                s.open = true
                defer { s.conts = [] }
                return s.conts
            }
            for x in c { x.resume() }
        }
        // @port-skip linux-only: frame port plumbing
        func didTerminate() {
            let c = waiters.withLockedValue { s -> [CheckedContinuation<Void, Never>] in
                s.terminated = true
                s.open = true
                defer { s.conts = [] }
                return s.conts
            }
            for x in c { x.resume() }
        }
        /// Closed *before* each yield: a produceMore that lands between a
        /// yield answering .stopProducing and the wait would otherwise be lost
        /// (the pump would wait forever on an already-drained consumer).
        // @port-skip linux-only: frame port plumbing
        func closeGate() { waiters.withLockedValue { $0.open = false } }
        // @port-skip linux-only: frame port plumbing
        func openGate() { waiters.withLockedValue { $0.open = true } }
        // @port-skip linux-only: frame port plumbing
        func waitOpen() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = waiters.withLockedValue { s -> Bool in
                    if s.open { return true }
                    s.conts.append(c)
                    return false
                }
                if ready { c.resume() }
            }
        }
        // @port-skip linux-only: frame port plumbing
        func waitOpenBlocking() {
            let sem = DispatchSemaphore(value: 0)
            Task { await self.waitOpen(); sem.signal() }
            sem.wait()
        }
    }

    public let name: String
    let sequence: FrameSequence
    private let source: FrameSequence.Producer.Source
    private let demand: Demand
    private let queueFrames: Int, queueBytes: Int

    /// The one room predicate for send, sendWaiting and isWritable: a frame is
    /// taken while the queue is under both limits (the byte limit may be
    /// overshot by that last frame).
    // @port-skip linux-only: frame port plumbing
    private func hasRoom(_ count: Int, _ bytes: Int) -> Bool { count < queueFrames && bytes < queueBytes }
    private let state = NIOLockedValueBox<(queue: [Data], bytes: Int, stats: FramePortStats, closed: Bool,
                                          drainWaiter: CheckedContinuation<Void, Never>?,
                                          spaceWaiters: [CheckedContinuation<Void, Never>])>(([], 0, FramePortStats(), false, nil, []))
    private let writerTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// When set, inbound frames go straight to it from the reader: no queue,
    /// no consumer to wait for, so the reader never pauses. The receiver must
    /// not block (the switch's routes only `send`, which drops when full).
    /// The closure lives in a struct: a function type stored directly in the
    /// generic box made Swift 6.4 emit two reabstraction thunks that called
    /// each other until the stack overflowed (SIGSEGV on the first frame).
    private struct Receiver: Sendable { let call: @Sendable (inout Data) -> Void; let batchEnd: (@Sendable () -> Void)? }
    private let receiver = NIOLockedValueBox<Receiver?>(nil)

    // @port-skip linux-only: frame port plumbing
    public func setReceiver(_ r: (@Sendable (inout Data) -> Void)?, batchEnd: (@Sendable () -> Void)? = nil) {
        let boxed = r.map { Receiver(call: $0, batchEnd: batchEnd) }
        receiver.withLockedValue { $0 = boxed }
        // A reader blocked on `inbound` (frames that came before the receiver
        // did, with nobody consuming) must go on: from now on it delivers here.
        if boxed != nil { demand.produceMore() }
    }

    /// The eager path: hands `frame` to the receiver if there is one.
    // @port-skip linux-only: frame port plumbing
    /// `endsBatch: false` when more frames follow at once (the passt routing
    /// thread's batches, closed by `endBatch`); a lone frame ends its batch.
    func receiveEagerly(_ frame: Data, endsBatch: Bool = true) -> Bool {
        var f = frame
        return receiveEagerly(owning: &f, endsBatch: endsBatch)
    }

    /// The receiver may change `frame` in place (the switch rewrites the
    /// destination MAC): when the caller holds the only reference, no copy.
    // @port-skip linux-only: frame port plumbing
    func receiveEagerly(owning frame: inout Data, endsBatch: Bool = true) -> Bool {
        guard let r = receiver.withLockedValue({ $0 }) else { return false }
        state.withLockedValue { $0.stats.received += 1 }
        r.call(&frame)
        if endsBatch { r.batchEnd?() }
        return true
    }

    // @port-skip linux-only: frame port plumbing
    func endBatch() { receiver.withLockedValue { $0 }?.batchEnd?() }

    // @port-skip linux-only: frame port plumbing
    var hasReceiver: Bool { receiver.withLockedValue { $0 != nil } }

    /// `write` sends a batch of frames (everything queued, up to `maxBatch`) to
    /// the wire in one go, waiting while the wire isn't writable; it throws
    /// when the destination is gone for now (the batch is dropped, counted).
    /// One write + flush per batch, not per frame: that is most of the cost
    /// at 1500-byte frames.
    // @port-skip linux-only: frame port plumbing
    public init(name: String, inboundLow: Int = FramePortCore.defaultInboundLow, inboundHigh: Int = FramePortCore.defaultInboundHigh,
                queueFrames: Int = FramePortCore.defaultQueueFrames, queueBytes: Int = FramePortCore.defaultQueueBytes,
                maxBatch: Int = 256, write: @escaping @Sendable ([Data]) async throws -> Void) {
        self.name = name
        self.queueFrames = queueFrames
        self.queueBytes = queueBytes
        let d = Demand()
        demand = d
        let made = FrameSequence.Producer.makeSequence(
            elementType: Data.self,
            backPressureStrategy: .init(lowWatermark: inboundLow, highWatermark: inboundHigh),
            finishOnDeinit: false, delegate: d)
        source = made.source
        sequence = FrameSequence(producer: made.sequence)
        let t = Task { [state] in
            while true {
                // Everything queued (up to maxBatch), or wait for send() to signal.
                var batch: [Data] = []
                var done = false
                while batch.isEmpty && !done {
                    let (b, closed) = state.withLockedValue { s -> ([Data], Bool) in
                        if !s.queue.isEmpty {
                            let n = min(maxBatch, s.queue.count)
                            let b = Array(s.queue.prefix(n))
                            s.queue.removeFirst(n)
                            s.bytes -= b.reduce(0) { $0 + $1.count }
                            s.stats.queued = s.queue.count
                            return (b, false)
                        }
                        return ([], s.closed)
                    }
                    if !b.isEmpty { batch = b; break }
                    if closed { done = true; break }
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let ready = state.withLockedValue { s -> Bool in
                            if !s.queue.isEmpty || s.closed { return true }
                            s.drainWaiter = c
                            return false
                        }
                        if ready { c.resume() }
                    }
                }
                if done { return }
                let waiters = state.withLockedValue { s -> [CheckedContinuation<Void, Never>] in
                    defer { s.spaceWaiters = [] }
                    return s.spaceWaiters
                }
                for w in waiters { w.resume() }
                do {
                    try await write(batch)
                    state.withLockedValue { $0.stats.sent += batch.count }
                } catch {
                    state.withLockedValue { $0.stats.dropped += batch.count }
                }
            }
        }
        writerTask.withLockedValue { $0 = t }
    }

    // MARK: inbound (the port's reader calls these)

    /// Hands one inbound frame to the consumer; returns once the consumer has
    /// room for more (the caller then reads the next one). False once the
    /// consumer is gone.
    // @port-skip linux-only: frame port plumbing
    @discardableResult
    public func deliver(_ frame: Data) async -> Bool {
        if receiveEagerly(frame) { return true }
        state.withLockedValue { $0.stats.received += 1 }
        demand.closeGate()
        switch source.yield(frame) {
        case .produceMore:
            demand.openGate()
            return true
        case .stopProducing:
            state.withLockedValue { $0.stats.inboundPauses += 1 }
            await demand.waitOpen()
            return !demand.waiters.withLockedValue { $0.terminated }
        case .dropped: return false
        }
    }

    /// `deliver` for a reader on a plain thread (the tap): blocks the thread.
    // @port-skip linux-only: frame port plumbing
    @discardableResult
    public func deliverBlocking(_ frame: Data) -> Bool {
        if receiveEagerly(frame) { return true }
        state.withLockedValue { $0.stats.received += 1 }
        demand.closeGate()
        switch source.yield(frame) {
        case .produceMore:
            demand.openGate()
            return true
        case .stopProducing:
            state.withLockedValue { $0.stats.inboundPauses += 1 }
            demand.waitOpenBlocking()
            return !demand.waiters.withLockedValue { $0.terminated }
        case .dropped: return false
        }
    }

    // MARK: outbound

    // @port-skip linux-only: frame port plumbing
    public func send(_ frame: Data) -> FrameSendResult {
        let (result, waiter) = state.withLockedValue { s -> (FrameSendResult, CheckedContinuation<Void, Never>?) in
            if s.closed { return (.closed, nil) }
            if !hasRoom(s.queue.count, s.bytes) {
                s.stats.dropped += 1
                return (.dropped, nil)
            }
            s.queue.append(frame)
            s.bytes += frame.count
            s.stats.queued = s.queue.count
            defer { s.drainWaiter = nil }
            return (.queued, s.drainWaiter)
        }
        waiter?.resume()
        return result
    }

    // @port-skip linux-only: frame port plumbing
    public func sendWaiting(_ frame: Data) async {
        while true {
            switch send(frameIfRoom: frame) {
            case .queued, .closed: return
            case .dropped:
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let roomNow = state.withLockedValue { s -> Bool in
                        if s.closed || hasRoom(s.queue.count, s.bytes) { return true }
                        s.spaceWaiters.append(c)
                        return false
                    }
                    if roomNow { c.resume() }
                }
            }
        }
    }

    /// `send` without waking the writer (see FramePort.sendDeferred).
    // @port-skip linux-only: frame port plumbing
    @discardableResult
    public func sendDeferred(_ frame: Data) -> FrameSendResult {
        state.withLockedValue { s -> FrameSendResult in
            if s.closed { return .closed }
            if !hasRoom(s.queue.count, s.bytes) {
                s.stats.dropped += 1
                return .dropped
            }
            s.queue.append(frame)
            s.bytes += frame.count
            s.stats.queued = s.queue.count
            return .queued
        }
    }

    /// Wakes the writer if it waits and anything is queued.
    // @port-skip linux-only: frame port plumbing
    public func flush() {
        let waiter = state.withLockedValue { s -> CheckedContinuation<Void, Never>? in
            guard !s.queue.isEmpty, let w = s.drainWaiter else { return nil }
            s.drainWaiter = nil
            return w
        }
        waiter?.resume()
    }

    /// `send` without counting a drop (sendWaiting retries).
    // @port-skip linux-only: frame port plumbing
    private func send(frameIfRoom frame: Data) -> FrameSendResult {
        let (result, waiter) = state.withLockedValue { s -> (FrameSendResult, CheckedContinuation<Void, Never>?) in
            if s.closed { return (.closed, nil) }
            if !hasRoom(s.queue.count, s.bytes) { return (.dropped, nil) }
            s.queue.append(frame)
            s.bytes += frame.count
            s.stats.queued = s.queue.count
            defer { s.drainWaiter = nil }
            return (.queued, s.drainWaiter)
        }
        waiter?.resume()
        return result
    }

    // @port-skip linux-only: frame port plumbing
    public var isWritable: Bool {
        state.withLockedValue { !$0.closed && hasRoom($0.queue.count, $0.bytes) }
    }

    // @port-skip linux-only: frame port plumbing
    public var stats: FramePortStats { state.withLockedValue { $0.stats } }

    /// Ends both directions: the consumer sees the end, queued frames are dropped.
    // @port-skip linux-only: frame port plumbing
    public func finish() {
        let (drain, spaces) = state.withLockedValue { s -> (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>]) in
            s.closed = true
            s.queue = []
            s.bytes = 0
            defer { s.drainWaiter = nil; s.spaceWaiters = [] }
            return (s.drainWaiter, s.spaceWaiters)
        }
        drain?.resume()
        for w in spaces { w.resume() }
        source.finish()
        demand.didTerminate()
    }
}
