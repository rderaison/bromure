import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - One userspace TCP connection, bridged to a forward channel

/// A single TCP flow terminated in userspace and spliced to a
/// `RemoteTransport.forwardDial` SSH channel. Drives the 3-way handshake, both
/// data directions (respecting the local kernel's receive window), and teardown.
/// State is guarded by `cond` (an NSCondition doubling as the lock); the reader
/// thread blocks on it for send-window room and is woken by inbound ACKs.
final class TCPFlow {
    private let key: UtunForwarder.FlowKey
    /// Opens the upstream byte stream for this flow and returns its fd, or nil to
    /// RST. The target is captured by the closure — this keeps TCPFlow transport-
    /// agnostic (an SSH forward channel for the utun tunnel, a socketpair end for
    /// the switch MiTM forwarder).
    private let dial: () -> Int32?
    private let send: (UtunPacket.TCPSegment) -> Void
    private let onClosed: (UtunForwarder.FlowKey) -> Void

    private let cond = NSCondition()
    private enum State { case connecting, synReceived, established, closing, closed }
    private var state: State = .connecting
    private var sndNxt: UInt32          // next seq we send
    private var sndUna: UInt32          // oldest unacked (client advances via ACK)
    private var rcvNxt: UInt32          // next seq we expect from the client
    private var clientWindow: UInt32 = 65535
    private var rfd: Int32 = -1
    private var finSent = false
    private var clientFin = false

    /// Max segment size we emit. utun path: 1460 (MTU 1500 − IP/TCP). Switch
    /// path: 1240, since the guest NIC MTU is 1280 (VMConfig.resolvedNICMTU).
    private let mss: Int
    private static let ourWindow: UInt16 = 65535

    init(key: UtunForwarder.FlowKey, clientISN: UInt32,
         mss: Int = 1460,
         dial: @escaping () -> Int32?,
         send: @escaping (UtunPacket.TCPSegment) -> Void,
         onClosed: @escaping (UtunForwarder.FlowKey) -> Void) {
        self.key = key
        self.mss = mss
        self.dial = dial
        self.send = send
        self.onClosed = onClosed
        self.rcvNxt = clientISN &+ 1     // SYN consumes one seq
        let isn = arc4random()
        self.sndNxt = isn
        self.sndUna = isn
    }

    /// Dial the remote (blocking) off-thread; on success complete the handshake,
    /// on failure RST. The client keeps retransmitting its SYN meanwhile.
    func start() {
        let dial = self.dial
        Thread.detachNewThread { [weak self] in
            let fd = dial() ?? -1
            guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
            self.cond.lock()
            guard self.state == .connecting else { self.cond.unlock(); if fd >= 0 { Darwin.close(fd) }; return }
            if fd < 0 {
                self.sendRSTLocked(); self.closeLocked(); self.cond.unlock(); return
            }
            self.rfd = fd
            FDGuard.adopt(fd, "tcpflow.rfd")
            self.state = .synReceived
            // SYN-ACK: seq = our ISN, ack = rcvNxt.
            self.emitLocked(flags: UtunPacket.SYN | UtunPacket.ACK, payload: [][...])
            self.sndNxt = self.sndNxt &+ 1   // our SYN consumes a seq
            self.cond.unlock()
        }
    }

    // MARK: Inbound (from the local kernel via utun)

    func onInbound(_ seg: UtunPacket.TCPSegment) {
        cond.lock(); defer { cond.unlock() }
        guard state != .closed else { return }

        if seg.flags & UtunPacket.RST != 0 { closeLocked(); return }

        if seg.flags & UtunPacket.ACK != 0 {
            // Advance the send window; wake the reader if it was blocked.
            if seqLE(sndUna, seg.ack), seqLE(seg.ack, sndNxt) { sndUna = seg.ack }
            clientWindow = UInt32(seg.window)
            cond.broadcast()
            if state == .synReceived, seg.ack == sndNxt {
                state = .established
                startReader()
            }
            closeIfFullyClosedLocked()   // may be the ACK of our FIN
        }

        // Data (in order only; duplicates get a re-ACK, gaps are dropped and the
        // client retransmits).
        if !seg.payload.isEmpty {
            if seg.seq == rcvNxt {
                let bytes = Array(seg.payload)
                if rfd >= 0 { _ = writeAll(rfd, bytes) }
                rcvNxt = rcvNxt &+ UInt32(bytes.count)
                emitLocked(flags: UtunPacket.ACK, payload: [][...])
            } else if seqLT(seg.seq, rcvNxt) {
                emitLocked(flags: UtunPacket.ACK, payload: [][...])   // dup → re-ACK
            }
        }

        // FIN (possibly piggybacked on the last data segment — matched by
        // sequence INCLUDING any payload the data branch just consumed).
        if seg.flags & UtunPacket.FIN != 0, seg.seq &+ UInt32(seg.payload.count) == rcvNxt {
            rcvNxt = rcvNxt &+ 1
            emitLocked(flags: UtunPacket.ACK, payload: [][...])
            if rfd >= 0 { shutdown(rfd, SHUT_WR) }   // half-close toward the remote
            clientFin = true
            closeIfFullyClosedLocked()
        }
    }

    // MARK: Outbound (remote → client) reader

    private func startReader() {
        let fd = rfd
        let mss = self.mss
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: mss)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    guard let self, self.sendData(Array(buf[0..<n])) else { break }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    self?.remoteClosed(); break   // EOF or error
                }
            }
        }
    }

    /// Send `bytes` to the client as one segment, blocking until the receive
    /// window has room. Returns false if the flow closed.
    private func sendData(_ bytes: [UInt8]) -> Bool {
        cond.lock(); defer { cond.unlock() }
        var off = 0
        while off < bytes.count {
            while state == .established && inFlight() >= clientWindow { cond.wait() }
            guard state == .established else { return false }
            let room = Int(clientWindow) - Int(inFlight())
            let n = min(bytes.count - off, mss, max(room, 1))
            emitLocked(flags: UtunPacket.PSH | UtunPacket.ACK, payload: bytes[off..<(off + n)])
            sndNxt = sndNxt &+ UInt32(n)
            off += n
        }
        return true
    }

    private func remoteClosed() {
        cond.lock(); defer { cond.unlock() }
        guard state == .established || state == .synReceived, !finSent else { return }
        emitLocked(flags: UtunPacket.FIN | UtunPacket.ACK, payload: [][...])
        sndNxt = sndNxt &+ 1
        finSent = true
        state = .closing
        closeIfFullyClosedLocked()
    }

    /// Once both directions have FINed and our FIN has been ACKed, the flow is
    /// done: close the channel fd and drop it from the forwarder. Without this
    /// a normal FIN teardown parked the flow in `.closing` forever, leaking
    /// `rfd` per connection. Waiting for the FIN-ACK (sndUna == sndNxt) rather
    /// than closing on the second FIN also keeps the client's final ACK from
    /// hitting an already-removed flow and drawing a spurious RST.
    private func closeIfFullyClosedLocked() {
        if finSent && clientFin && sndUna == sndNxt { closeLocked() }
    }

    func close() { cond.lock(); closeLocked(); cond.unlock() }

    // MARK: Locked helpers (call with `cond` held)

    private func inFlight() -> UInt32 { sndNxt &- sndUna }

    private func emitLocked(flags: UInt8, payload: ArraySlice<UInt8>) {
        send(UtunPacket.TCPSegment(
            srcIP: key.dstIP, dstIP: key.srcIP, srcPort: key.dstPort, dstPort: key.srcPort,
            seq: sndNxt, ack: rcvNxt, flags: flags, window: TCPFlow.ourWindow, payload: payload))
    }

    private func sendRSTLocked() {
        send(UtunPacket.TCPSegment(
            srcIP: key.dstIP, dstIP: key.srcIP, srcPort: key.dstPort, dstPort: key.srcPort,
            seq: sndNxt, ack: rcvNxt, flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...]))
    }

    private func closeLocked() {
        guard state != .closed else { return }
        state = .closed
        if rfd >= 0 { FDGuard.close(rfd, "tcpflow.rfd"); rfd = -1 }
        cond.broadcast()
        onClosed(key)
    }

    // MARK: Utilities

    /// Modular seq comparisons (RFC 793 "less than" over the 32-bit space).
    private func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
    private func seqLE(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int {
        var off = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while off < bytes.count {
                let n = Darwin.write(fd, base + off, bytes.count - off)
                if n > 0 { off += n }
                else if n < 0 && (errno == EINTR) { continue }
                else { break }
            }
        }
        return off
    }
}
