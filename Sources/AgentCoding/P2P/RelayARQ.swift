import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - RelayARQ — a reliable ordered byte stream over unreliable datagrams
//
// The TURN *UDP* relay (REQUESTED-TRANSPORT=udp) moves opaque datagrams, but the
// payload we carry is SSH — a reliable, ordered byte stream. So we run a compact
// selective-repeat ARQ (KCP-flavoured) on top: sequence numbers, per-segment
// retransmission with an RTT-estimated timer, SACK-driven fast retransmit, a
// sliding receive window, and AIMD congestion control.
//
// Why not just relay over TURN-TCP (RFC 6062, `TurnTCP.swift`)? Because that
// tunnels a TCP stream (SSH) inside another TCP stream (the relay leg). On a
// lossy/high-latency link the two loss-recovery loops fight — the outer TCP
// stalls the whole pipe on a single drop (head-of-line blocking) and both RTOs
// compound ("TCP meltdown"). A datagram relay + our own ARQ removes the outer
// reliability loop: a lost segment is retransmitted directly, in ~1 RTT, without
// freezing everything behind it. That is the whole point of the UDP path —
// resilience over slow links — so this layer is deliberately loss-tolerant
// (fast retransmit on 3 dup-SACKs, latency-biased RTO) rather than throughput-
// maximal.
//
// Security: the relay (and this ARQ) is untrusted, exactly as the TCP relay is —
// SSH stays end-to-end, host-key-pinned and pubkey-authed. A hostile relay can
// corrupt/drop datagrams and at worst deny service; it can never read or forge
// the SSH inside. So there is no integrity/crypto here: that is SSH's job.
//
// `ARQConnection` is the pure protocol engine — time is injected (every call
// takes `now` in monotonic ms), it has no sockets and no threads, so it is
// exhaustively unit-testable against a simulated lossy channel. `ARQEndpoint`
// wraps one in the socketpair-loopback pattern (`TurnTLSTunnel`), presenting a
// plain blocking fd whose bytes are ARQ'd to the peer, and is driven by whatever
// datagram substrate feeds it (a raw UDP socket on the dialer, a TURN
// ChannelData pump on the listener).

// MARK: Wire format

/// Every segment is a 20-byte header + optional payload, big-endian:
///
///     0               1               2               3
///     +-------+-------+-------+-------+-------+-------+-------+-------+
///     |            conv (4)           | cmd(1)| frg(1)|   wnd (2)     |
///     +-------+-------+-------+-------+-------+-------+-------+-------+
///     |            seq (4)            |            una (4)           |
///     +-------+-------+-------+-------+-------+-------+-------+-------+
///     | sackN | rsvd  |   len (2)     |   payload (len bytes) ...    |
///     +-------+-------+-------+-------+-------------------------------+
///
/// `conv` names the session (guards stray/old datagrams on a reused relay
/// address). `una` piggybacks the cumulative ack and `wnd` the free receive
/// window on *every* segment. DATA/FIN carry `len` bytes of stream payload;
/// ACK carries `sackN` big-endian UInt32 selectively-acked seqs as its payload.
enum ARQWire {
    static let headerSize = 20

    enum Cmd: UInt8 {
        case syn = 1      // initiator → responder: open (retransmitted until any reply)
        case synack = 2   // responder → initiator: establishing reply (may be empty)
        case data = 3      // stream payload at `seq`
        case ack = 4       // pure ack (cumulative `una` + optional SACK payload)
        case fin = 5       // half-close: consumes one `seq`, after all queued data
        case ping = 6      // keepalive (also probes a half-open path)
    }

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    static func rd32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}

/// One decoded/encodable segment.
struct ARQSegment {
    var conv: UInt32
    var cmd: ARQWire.Cmd
    var wnd: UInt16
    var seq: UInt32
    var una: UInt32
    var sack: [UInt32] = []
    var data: [UInt8] = []

    func encoded() -> [UInt8] {
        // ACK carries SACK entries as payload; DATA/FIN carry stream bytes.
        let payload: [UInt8] = cmd == .ack ? sack.flatMap { ARQWire.be32($0) } : data
        let len = payload.count
        var out: [UInt8] = []
        out.reserveCapacity(ARQWire.headerSize + len)
        out += ARQWire.be32(conv)
        out.append(cmd.rawValue)
        out.append(0)   // frg (reserved)
        out.append(UInt8(truncatingIfNeeded: wnd >> 8)); out.append(UInt8(truncatingIfNeeded: wnd))
        out += ARQWire.be32(seq)
        out += ARQWire.be32(una)
        out.append(UInt8(truncatingIfNeeded: cmd == .ack ? sack.count : 0))
        out.append(0)   // reserved
        out.append(UInt8(truncatingIfNeeded: len >> 8)); out.append(UInt8(truncatingIfNeeded: len))
        out += payload
        return out
    }

    static func decode(_ b: [UInt8]) -> ARQSegment? {
        guard b.count >= ARQWire.headerSize else { return nil }
        guard let cmd = ARQWire.Cmd(rawValue: b[4]) else { return nil }
        let wnd = UInt16(b[6]) << 8 | UInt16(b[7])
        let sackN = Int(b[16])
        let len = Int(b[18]) << 8 | Int(b[19])
        guard b.count >= ARQWire.headerSize + len else { return nil }
        let payload = Array(b[ARQWire.headerSize ..< ARQWire.headerSize + len])
        var seg = ARQSegment(conv: ARQWire.rd32(b, 0), cmd: cmd, wnd: wnd,
                             seq: ARQWire.rd32(b, 8), una: ARQWire.rd32(b, 12))
        if cmd == .ack {
            guard sackN * 4 <= payload.count else { return nil }
            seg.sack = (0..<sackN).map { ARQWire.rd32(payload, $0 * 4) }
        } else {
            seg.data = payload
        }
        return seg
    }
}

// MARK: - The protocol engine

/// A full-duplex reliable stream. Pure w.r.t. time and I/O: it never touches a
/// socket or clock — the owner injects `now` (monotonic ms) on every call and
/// wires `output`/`deliver`/`onClosed`. All state is lock-guarded so the owner
/// can call `write`/`input`/`update` from different threads; emissions are
/// buffered under the lock and flushed to the closures after it is released, so
/// a slow sink never deadlocks the engine.
final class ARQConnection: @unchecked Sendable {
    // Owner-provided sinks.
    var output: ([UInt8]) -> Void = { _ in }   // a datagram to put on the wire
    var deliver: ([UInt8]) -> Void = { _ in }   // in-order stream bytes for the app
    var onClosed: () -> Void = {}                // the connection is fully done
    /// The peer half-closed: all of its data has been delivered and it will send
    /// no more. Fires once, after the last `deliver`. The endpoint uses it to
    /// half-close the local stream so the consumer (sshd) sees EOF promptly,
    /// rather than hanging until the full-close / dead-link timeout.
    var onDeliverEOF: () -> Void = {}

    private let conv: UInt32
    private let isInitiator: Bool
    private let mss: Int
    private let lock = NSLock()

    // Tunables (segments unless noted). Sized for interactive SSH over a slow
    // relay, not bulk throughput.
    private let rcvWndMax = 512          // ~560 KB at mss 1100 — ample for SSH
    private let rtoMin: Int64 = 120
    private let rtoMax: Int64 = 8000
    private let fastAckThreshold = 3      // dup-SACKs before fast retransmit
    private let keepaliveIdle: Int64 = 10_000
    private let deadLink: Int64 = 45_000  // no ack progress this long → abort

    // Send side.
    private var sndUna: UInt32 = 0        // oldest unacked data seq
    private var sndNxt: UInt32 = 0        // next data seq to assign
    private var sndQueue: [ArraySlice<UInt8>] = []   // app bytes not yet segmented
    private var sndBuf: [OutSeg] = []     // in-flight, ascending seq
    private var rmtWnd: Int = 1           // peer's advertised free window
    private var cwnd: Double = 4          // congestion window
    private var ssthresh: Double = 128
    private var finSeq: UInt32?           // seq assigned to our FIN (once closing)
    private var wantClose = false         // app half-closed the write side

    // Receive side.
    private var rcvNxt: UInt32 = 0        // next in-order data seq to deliver
    private var rcvBuf: [UInt32: [UInt8]] = [:]   // buffered out-of-order data
    private var peerFinSeq: UInt32?       // seq of peer's FIN (once seen)

    // RTT / timers.
    private var srtt: Int64 = 0
    private var rttvar: Int64 = 0
    private var rto: Int64 = 400
    private var established = false
    private var handshakeResendAt: Int64 = 0
    private var lastRecvAt: Int64 = 0
    private var lastSendAt: Int64 = 0
    private var lastAckProgressAt: Int64 = 0
    private var needAck = false           // a cumulative ack is owed
    private var closedFired = false
    private var aborted = false

    // Emission buffers (drained after the lock is dropped).
    private var pendingOut: [[UInt8]] = []
    private var pendingDeliver: [[UInt8]] = []

    private struct OutSeg {
        var seq: UInt32
        var data: [UInt8]
        var cmd: ARQWire.Cmd          // .data or .fin
        var sentAt: Int64
        var resendAt: Int64
        var xmit: Int = 0             // transmit count (Karn: >1 ⇒ no RTT sample)
        var fastAck: Int = 0          // dup-SACKs observed past this seq
    }

    init(conv: UInt32, isInitiator: Bool, now: Int64, mss: Int = 1100) {
        self.conv = conv
        self.isInitiator = isInitiator
        self.mss = mss
        self.lastRecvAt = now
        self.lastSendAt = now
        self.lastAckProgressAt = now
        if isInitiator {
            // The SYN is sent by the first `update()`, not here: the owner wires
            // `output` only after init returns, so emitting now would drop the
            // SYN into the default no-op sink and cost a full RTO. Arming the
            // handshake timer at `now` makes the first tick send it immediately.
            handshakeResendAt = now
        } else {
            established = true   // responder is created from the peer's SYN
        }
    }

    var isEstablished: Bool { lock.lock(); defer { lock.unlock() }; return established }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedFired }

    // MARK: App → net

    /// Queue app bytes for reliable, ordered delivery to the peer.
    func write(_ bytes: [UInt8], now: Int64) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if wantClose || aborted { lock.unlock(); return }
        var off = 0
        while off < bytes.count {
            let end = min(off + mss, bytes.count)
            sndQueue.append(bytes[off..<end])
            off = end
        }
        pump(now: now)
        lock.unlock()
        flush()
    }

    /// Half-close: after everything queued is delivered, send a FIN.
    func closeWrite(now: Int64) {
        lock.lock()
        if wantClose || aborted { lock.unlock(); return }
        wantClose = true
        pump(now: now)
        lock.unlock()
        flush()
    }

    /// Hard teardown — stop retransmitting, fire `onClosed` once.
    func abort() {
        lock.lock()
        aborted = true
        let fire = !closedFired
        closedFired = true
        lock.unlock()
        if fire { onClosed() }
    }

    // MARK: net → engine

    /// Feed one received datagram.
    func input(_ dgram: [UInt8], now: Int64) {
        guard let seg = ARQSegment.decode(dgram), seg.conv == conv else { return }
        lock.lock()
        if aborted { lock.unlock(); return }
        lastRecvAt = now
        rmtWnd = max(1, Int(seg.wnd))
        if isInitiator && !established { established = true }   // any valid reply establishes us

        // Cumulative + selective acknowledgement of our in-flight segments.
        processAck(una: seg.una, sack: seg.sack, now: now)

        switch seg.cmd {
        case .syn:
            // Duplicate SYN (our SYNACK was lost) — re-answer.
            enqueueControl(.synack, now: now)
        case .synack, .ack, .ping:
            break   // ack already processed; ping keeps the path warm
        case .data:
            acceptData(seq: seg.seq, data: seg.data, now: now)
        case .fin:
            // FIN sits at a seq in the data stream; accept in order like data,
            // then (once delivered) it advances rcvNxt and we ack it.
            peerFinSeq = seg.seq
            acceptData(seq: seg.seq, data: [], now: now, isFin: true)
        }
        pump(now: now)
        // Flush an owed ack now rather than waiting for the next `update` tick —
        // the endpoint's ticker can sleep up to 500 ms, and a delayed ack stalls
        // the sender's window (kills throughput on a bulk transfer) and slows
        // fast-retransmit. If `pump` already emitted a data segment its `una`
        // piggybacks the ack, but a standalone one is cheap and idempotent.
        if needAck { emit(ackSeg()); needAck = false }
        maybeCheckClosed(now: now)
        lock.unlock()
        flush()
    }

    // MARK: timers

    /// Drive retransmission/ack/keepalive. Returns ms until the next `update`
    /// is worthwhile (the owner sleeps at most that long).
    @discardableResult
    func update(now: Int64) -> Int64 {
        lock.lock()
        if aborted { lock.unlock(); return 1000 }

        // Dead-link guard: no forward progress (acks) for `deadLink` while we
        // still have unacked data ⇒ the path is gone. Abort so the SSH layer
        // sees EOF instead of hanging forever.
        if (!sndBuf.isEmpty || wantClose) && now - lastAckProgressAt > deadLink {
            lock.unlock()
            abort()
            return 1000
        }

        // Handshake retransmit (initiator only, until established).
        if isInitiator && !established && now >= handshakeResendAt {
            enqueueControl(.syn, now: now)
            rto = min(rtoMax, rto * 2)
            handshakeResendAt = now + rto
        }

        // Retransmit timed-out in-flight segments.
        for i in sndBuf.indices where now >= sndBuf[i].resendAt {
            sndBuf[i].xmit += 1
            sndBuf[i].sentAt = now
            sndBuf[i].resendAt = now + rto
            emit(dataSeg(sndBuf[i]))
            // RTO loss ⇒ collapse the window hard (classic Tahoe on timeout).
            ssthresh = max(2, cwnd / 2)
            cwnd = 1
        }

        pump(now: now)

        // Owe a cumulative ack? (received data but had nothing to piggyback on.)
        if needAck { emit(ackSeg()); needAck = false }

        // Keepalive so a half-open path is detected (and NAT/relay bindings stay
        // warm) even when the SSH stream is idle.
        if established && now - lastSendAt >= keepaliveIdle {
            emit(ARQSegment(conv: conv, cmd: .ping, wnd: recvWindow(), seq: sndNxt, una: rcvNxt))
        }

        maybeCheckClosed(now: now)
        let next = nextTimeout(now: now)
        lock.unlock()
        flush()
        return next
    }

    // MARK: - Internals (lock held)

    private func recvWindow() -> UInt16 {
        UInt16(truncatingIfNeeded: max(0, rcvWndMax - rcvBuf.count))
    }

    private func inflightLimit() -> Int {
        max(1, min(Int(cwnd), rmtWnd))
    }

    /// Move queued app bytes into in-flight segments as the window allows, and,
    /// once the queue drains, assign the FIN its seq.
    private func pump(now: Int64) {
        guard established else { return }
        while sndBuf.count < inflightLimit(), !sndQueue.isEmpty {
            let chunk = sndQueue.removeFirst()
            var seg = OutSeg(seq: sndNxt, data: Array(chunk), cmd: .data,
                             sentAt: now, resendAt: now + rto)
            sndNxt &+= 1
            seg.xmit = 1
            sndBuf.append(seg)
            emit(dataSeg(seg))
        }
        // FIN goes on the wire only after every data segment is queued/in-flight.
        if wantClose, finSeq == nil, sndQueue.isEmpty, sndBuf.count < inflightLimit() {
            let seq = sndNxt; sndNxt &+= 1; finSeq = seq
            var seg = OutSeg(seq: seq, data: [], cmd: .fin, sentAt: now, resendAt: now + rto)
            seg.xmit = 1
            sndBuf.append(seg)
            emit(dataSeg(seg))
        }
    }

    private func dataSeg(_ s: OutSeg) -> ARQSegment {
        lastSendAt = max(lastSendAt, s.sentAt)
        return ARQSegment(conv: conv, cmd: s.cmd, wnd: recvWindow(),
                          seq: s.seq, una: rcvNxt, data: s.data)
    }

    private func ackSeg() -> ARQSegment {
        // Cumulative una + up to 16 SACK blocks (the buffered out-of-order seqs)
        // so the sender can fast-retransmit the specific hole, not the window.
        let sack = Array(rcvBuf.keys.sorted().prefix(16))
        return ARQSegment(conv: conv, cmd: .ack, wnd: recvWindow(),
                          seq: sndNxt, una: rcvNxt, sack: sack)
    }

    private func enqueueControl(_ cmd: ARQWire.Cmd, now: Int64) {
        lastSendAt = now
        emit(ARQSegment(conv: conv, cmd: cmd, wnd: recvWindow(), seq: sndNxt, una: rcvNxt))
    }

    private func emit(_ seg: ARQSegment) { pendingOut.append(seg.encoded()) }

    /// Apply an incoming cumulative ack + SACK: drop acked in-flight segments,
    /// sample RTT (Karn), fast-retransmit a hole SACKed past `fastAckThreshold`,
    /// and adjust the congestion window.
    private func processAck(una: UInt32, sack: [UInt32], now: Int64) {
        let before = sndBuf.count
        var newlyAcked = false

        // Cumulative: everything with seq < una is delivered.
        sndBuf.removeAll { seg in
            guard seqLt(seg.seq, una) else { return false }
            if seg.xmit == 1 { sampleRTT(now - seg.sentAt, now: now) }   // Karn
            newlyAcked = true
            return true
        }
        if seqLt(sndUna, una) { sndUna = una }

        // Selective: drop individually-acked holes too.
        if !sack.isEmpty {
            let sset = Set(sack)
            sndBuf.removeAll { seg in
                guard sset.contains(seg.seq) else { return false }
                if seg.xmit == 1 { sampleRTT(now - seg.sentAt, now: now) }
                newlyAcked = true
                return true
            }
            // Dup-SACK accounting: any in-flight seg below the highest SACKed seq
            // is presumed lost after enough later segments arrive.
            if let maxSacked = sack.max() {
                for i in sndBuf.indices where seqLt(sndBuf[i].seq, maxSacked) {
                    sndBuf[i].fastAck += 1
                    if sndBuf[i].fastAck >= fastAckThreshold {
                        sndBuf[i].fastAck = 0
                        sndBuf[i].xmit += 1
                        sndBuf[i].sentAt = now
                        sndBuf[i].resendAt = now + rto
                        emit(dataSeg(sndBuf[i]))
                        ssthresh = max(2, Double(sndBuf.count) / 2)
                        cwnd = ssthresh + 3   // fast recovery
                    }
                }
            }
        }

        if newlyAcked {
            lastAckProgressAt = now
            // Slow start below ssthresh, congestion avoidance above.
            if cwnd < ssthresh { cwnd += 1 }
            else { cwnd += 1.0 / cwnd }
            cwnd = min(cwnd, Double(rcvWndMax))
        }
        if before != sndBuf.count { pump(now: now) }
    }

    private func sampleRTT(_ r: Int64, now: Int64) {
        let rtt = max(1, r)
        if srtt == 0 { srtt = rtt; rttvar = rtt / 2 }
        else {
            rttvar = (3 * rttvar + abs(srtt - rtt)) / 4
            srtt = (7 * srtt + rtt) / 8
        }
        rto = min(rtoMax, max(rtoMin, srtt + max(1, 4 * rttvar)))
    }

    /// Accept an in-order or buffered data (or FIN) segment; deliver everything
    /// now contiguous and owe an ack.
    private func acceptData(seq: UInt32, data: [UInt8], now: Int64, isFin: Bool = false) {
        // Outside the receive window (already delivered, or too far ahead) —
        // still ack so the sender learns our cumulative state.
        if seqLt(seq, rcvNxt) || seqGte(seq, rcvNxt &+ UInt32(rcvWndMax)) {
            needAck = true
            return
        }
        if seq == rcvNxt || rcvBuf[seq] == nil {
            rcvBuf[seq] = isFin ? [] : data
            if isFin { peerFinSeq = seq }
        }
        // Drain the contiguous prefix.
        while let chunk = rcvBuf[rcvNxt] {
            rcvBuf[rcvNxt] = nil
            if !chunk.isEmpty { pendingDeliver.append(chunk) }
            let wasFin = (peerFinSeq == rcvNxt)
            rcvNxt &+= 1
            if wasFin {
                if !eofScheduled { eofScheduled = true; pendingEOF = true }
                break   // nothing after the peer's FIN
            }
        }
        needAck = true
    }

    /// Fully closed once BOTH directions are done: our FIN is acked (no in-flight
    /// left and we wanted to close) and we have delivered the peer's FIN.
    private func maybeCheckClosed(now: Int64) {
        guard !closedFired else { return }
        let ourDone = wantClose && finSeq != nil && sndBuf.isEmpty
        let peerDone = peerFinSeq != nil && seqGte(rcvNxt, (peerFinSeq ?? 0) &+ 1)
        if ourDone && peerDone {
            closedFired = true
            // Fire outside the lock via a one-shot on the deliver path.
            pendingClose = true
        }
    }
    private var pendingClose = false
    private var pendingEOF = false
    private var eofScheduled = false

    private func nextTimeout(now: Int64) -> Int64 {
        var next = now + 1000
        if isInitiator && !established { next = min(next, handshakeResendAt) }
        for s in sndBuf { next = min(next, s.resendAt) }
        if established { next = min(next, lastSendAt + keepaliveIdle) }
        if needAck { next = now }
        return max(1, next - now)
    }

    /// Push buffered emissions/deliveries to the sinks with the lock released.
    private func flush() {
        lock.lock()
        let out = pendingOut; pendingOut = []
        let del = pendingDeliver; pendingDeliver = []
        let close = pendingClose; pendingClose = false
        let eof = pendingEOF; pendingEOF = false
        lock.unlock()
        for d in out { output(d) }
        for d in del { deliver(d) }
        if eof { onDeliverEOF() }   // after the last bytes, before any full close
        if close { onClosed() }
    }

    // Serial-number comparison (RFC 1982, 32-bit) so wraparound is handled.
    private func seqLt(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
    private func seqGte(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) >= 0 }
}

// MARK: - Endpoint (socketpair loopback ⇄ ARQ ⇄ datagram substrate)

/// Wraps an `ARQConnection` behind a blocking loopback fd, exactly like
/// `TurnTLSTunnel` does for TLS. The caller reads/writes `localFD` as a plain
/// byte stream; three threads move bytes:
///   • uplink — blocking-read `localFD`, `ARQConnection.write`
///   • delivery — drain the engine's in-order output to `localFD` (decoupled by
///     a queue so a slow local consumer never stalls ack processing)
///   • ticker — call `ARQConnection.update` on the schedule it asks for
/// The datagram substrate (raw UDP on the dialer, TURN ChannelData on the
/// listener) owns the actual socket: it calls `receive(_:)` for each inbound
/// datagram and provides the `send` closure for outbound ones.
final class ARQEndpoint: @unchecked Sendable {
    let localFD: Int32
    private let pumpFD: Int32
    private let arq: ARQConnection
    private let estGate = DispatchSemaphore(value: 0)
    private var estSignalled = false
    private let stateLock = NSLock()
    private var stopped = false
    /// Fired once when the endpoint tears down — the datagram substrate uses it
    /// to close its socket / drop its peer entry.
    var onStop: (() -> Void)?

    // Decoupled delivery queue: engine → here → blocking write to pumpFD.
    private let deliverCond = NSCondition()
    private var deliverQueue: [[UInt8]] = []
    private var deliverClosed = false
    private var deliverEOF = false   // peer half-closed → shut the write side once drained

    /// - Parameters:
    ///   - conv: session id (initiator picks it; responder learns it from the SYN).
    ///   - isInitiator: dialer = true, listener = false.
    ///   - send: puts one ARQ datagram on the wire (UDP sendto / TURN send).
    init?(conv: UInt32, isInitiator: Bool, send: @escaping ([UInt8]) -> Void) {
        var sp: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0 else { return nil }
        self.localFD = sp[0]
        self.pumpFD = sp[1]
        self.arq = ARQConnection(conv: conv, isInitiator: isInitiator, now: Self.nowMS())

        arq.output = send
        arq.deliver = { [weak self] bytes in
            guard let self else { return }
            self.deliverCond.lock()
            self.deliverQueue.append(bytes)
            self.deliverCond.signal()
            self.deliverCond.unlock()
        }
        arq.onClosed = { [weak self] in self?.stop() }
        arq.onDeliverEOF = { [weak self] in
            guard let self else { return }
            self.deliverCond.lock(); self.deliverEOF = true; self.deliverCond.signal(); self.deliverCond.unlock()
        }

        startUplink()
        startDelivery()
        startTicker()
        // The initiator's constructor already fired the SYN; watch for the reply.
        if !isInitiator { signalEstablished() }
    }

    static func nowMS() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// Feed one inbound datagram from the substrate.
    func receive(_ dgram: [UInt8]) {
        arq.input(dgram, now: Self.nowMS())
        if arq.isEstablished { signalEstablished() }
    }

    /// Block until the ARQ handshake completes (or `timeout`). Dialer only.
    func waitEstablished(timeout: TimeInterval) -> Bool {
        if arq.isEstablished { return true }
        return estGate.wait(timeout: .now() + timeout) == .success && arq.isEstablished
    }

    func stop() {
        stateLock.lock()
        if stopped { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        arq.abort()
        signalEstablished()   // unblock any waiter
        deliverCond.lock(); deliverClosed = true; deliverCond.signal(); deliverCond.unlock()
        Darwin.shutdown(pumpFD, SHUT_RDWR)
        Darwin.close(pumpFD)
        Darwin.shutdown(localFD, SHUT_RDWR)
        // localFD is closed by the owner (FatForward.splice / the shim) — closing
        // it here too would double-close; shutdown is enough to wake its reader.
        onStop?()
    }

    private func signalEstablished() {
        stateLock.lock()
        let go = !estSignalled
        estSignalled = true
        stateLock.unlock()
        if go { estGate.signal() }
    }

    // localFD ← app writes → ARQ.write
    private func startUplink() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(self.pumpFD, &buf, buf.count)
                if n > 0 { self.arq.write(Array(buf[0..<n]), now: Self.nowMS()) }
                else { break }   // app closed its end → half-close the stream
            }
            self.arq.closeWrite(now: Self.nowMS())
        }
    }

    // ARQ in-order output → localFD (blocking, decoupled from the engine).
    private func startDelivery() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var didEOF = false
            while true {
                self.deliverCond.lock()
                while self.deliverQueue.isEmpty && !self.deliverClosed && !(self.deliverEOF && !didEOF) {
                    self.deliverCond.wait()
                }
                let batch = self.deliverQueue; self.deliverQueue.removeAll()
                let done = self.deliverClosed
                let doEOF = self.deliverEOF && !didEOF
                self.deliverCond.unlock()
                for chunk in batch where !Self.writeAll(self.pumpFD, chunk) { return }
                // All delivered peer bytes are written; now signal EOF to the
                // local consumer by half-closing the write side of the pipe.
                if doEOF { didEOF = true; Darwin.shutdown(self.pumpFD, SHUT_WR) }
                if done && batch.isEmpty { return }
            }
        }
    }

    // Drive the engine's timers on the cadence it requests.
    private func startTicker() {
        Thread.detachNewThread { [weak self] in
            while true {
                guard let self else { return }
                self.stateLock.lock(); let dead = self.stopped; self.stateLock.unlock()
                if dead || self.arq.isClosed { return }
                let next = self.arq.update(now: Self.nowMS())
                let ms = Int(min(max(next, 5), 500))   // clamp: responsive but not a spin
                usleep(useconds_t(ms * 1000))
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var off = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            while off < data.count {
                let w = Darwin.write(fd, base.advanced(by: off), data.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
    }
}
