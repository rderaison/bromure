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
    private let host: RemoteHost
    private let targetIP: String
    private let targetPort: Int
    private let dial: (RemoteHost, String, Int) -> Int32?
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

    private static let mss = 1460       // utun MTU 1500 − IP(20) − TCP(20)
    private static let ourWindow: UInt16 = 65535

    init(key: UtunForwarder.FlowKey, clientISN: UInt32, host: RemoteHost,
         targetIP: String, targetPort: Int,
         dial: @escaping (RemoteHost, String, Int) -> Int32?,
         send: @escaping (UtunPacket.TCPSegment) -> Void,
         onClosed: @escaping (UtunForwarder.FlowKey) -> Void) {
        self.key = key
        self.host = host
        self.targetIP = targetIP
        self.targetPort = targetPort
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
        let ip = targetIP, port = targetPort, host = self.host, dial = self.dial
        Thread.detachNewThread { [weak self] in
            let fd = dial(host, ip, port) ?? -1
            guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
            self.cond.lock()
            guard self.state == .connecting else { self.cond.unlock(); if fd >= 0 { Darwin.close(fd) }; return }
            if fd < 0 {
                self.sendRSTLocked(); self.closeLocked(); self.cond.unlock(); return
            }
            self.rfd = fd
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

        if seg.flags & UtunPacket.FIN != 0, seg.seq == rcvNxt {
            rcvNxt = rcvNxt &+ 1
            emitLocked(flags: UtunPacket.ACK, payload: [][...])
            if rfd >= 0 { shutdown(rfd, SHUT_WR) }   // half-close toward the remote
        }
    }

    // MARK: Outbound (remote → client) reader

    private func startReader() {
        let fd = rfd
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: TCPFlow.mss)
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
            let n = min(bytes.count - off, TCPFlow.mss, max(room, 1))
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
        if rfd >= 0 { Darwin.close(rfd); rfd = -1 }
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
