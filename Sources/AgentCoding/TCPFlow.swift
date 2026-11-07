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
    private let key: UtunPacket.FlowKey
    /// Opens the upstream byte stream for this flow and returns its fd, or nil to
    /// RST. The target is captured by the closure — this keeps TCPFlow transport-
    /// agnostic (an SSH forward channel for the utun tunnel, a socketpair end for
    /// the switch MiTM forwarder).
    private let dial: () -> Int32?
    private let send: (UtunPacket.TCPSegment) -> Void
    private let onClosed: (UtunPacket.FlowKey) -> Void

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
    /// In-window bytes from the client the remote socket couldn't take yet
    /// (its buffer full), at most a window's worth: written out as it drains
    /// (the reader watches for room while any wait). The window we advertise
    /// is what's left of 64 KiB, so in-window data is never refused and the
    /// window never shrinks past what was sent under it.
    private var pending: [UInt8] = []
    /// The client's FIN arrived while bytes were pending: the half-close
    /// toward the remote follows them.
    private var shutdownPending = false
    /// The reader's turns of its poll loop (tests: an idle flow takes about
    /// one a second, never a spin).
    private var readerTurns = 0
    var readerTurnsForTesting: Int { cond.lock(); defer { cond.unlock() }; return readerTurns }
    /// The window last advertised, to send an update once it has grown.
    private var lastWindow = 65535
    /// A pipe that wakes the reader out of poll when bytes start pending, so
    /// it watches for room at once (not after its poll timeout).
    private var wake: (read: Int32, write: Int32) = (-1, -1)
    /// The reader thread runs: it, not closeLocked, closes the socket when
    /// it stops (it may be in poll or read on that number).
    private var readerStarted = false

    /// Max segment size we emit. utun path: 1460 (MTU 1500 − IP/TCP). Switch
    /// path: 1240, since the guest NIC MTU is 1280 (VMConfig.resolvedNICMTU).
    private let mss: Int
    private static let maxWindow = 65535
    /// The remote socket's send buffer (as far as the system allows): a
    /// macOS socketpair's default is 8 KiB, which refused most of a burst.
    private static let remoteBuffer: Int32 = 256 << 10

    init(key: UtunPacket.FlowKey, clientISN: UInt32,
         mss: Int = 1460,
         dial: @escaping () -> Int32?,
         send: @escaping (UtunPacket.TCPSegment) -> Void,
         onClosed: @escaping (UtunPacket.FlowKey) -> Void) {
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
            guard let self else { if fd >= 0 { fdClose(fd) }; return }
            self.cond.lock()
            guard self.state == .connecting else { self.cond.unlock(); if fd >= 0 { fdClose(fd) }; return }
            if fd < 0 {
                self.sendRSTLocked(); self.closeLocked(); self.cond.unlock(); return
            }
            self.rfd = fd
            FDGuard.adopt(fd, "tcpflow.rfd")
            // Writes to it never block (onInbound holds the lock, and close()
            // takes it): non-blocking, with room for a window's worth.
            fdSetNonBlocking(fd)
            fdNoSigPipe(fd)
            fdRaiseSendBuffer(fd, TCPFlow.remoteBuffer)
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
            // Whatever's pending goes out with any segment from the client
            // (not only on POLLOUT: the reader may be waiting on the client's
            // window in sendData).
            flushLocked()
            closeIfFullyClosedLocked()   // may be the ACK of our FIN
        }

        // A bare segment from before what we expect (the client's zero-window
        // probe: seq = snd.una − 1, no payload) is answered with an ACK and
        // the window as it is now (RFC 793).
        if seg.payload.isEmpty, seg.flags & (UtunPacket.SYN | UtunPacket.FIN | UtunPacket.RST) == 0, seqLT(seg.seq, rcvNxt) {
            emitLocked(flags: UtunPacket.ACK, payload: [][...])
        }

        // Data (in order only; duplicates get a re-ACK, gaps are dropped and the
        // client retransmits). None before our SYN-ACK went out (the remote
        // isn't dialed yet).
        if !seg.payload.isEmpty, state != .connecting {
            if seg.seq == rcvNxt {
                // Within the window: taken, written as far as the socket goes
                // now (never blocking: the lock is held), the rest kept until
                // it drains. Past the window (a client that ignored it): not
                // acknowledged, sent again later.
                let accept = min(seg.payload.count, max(0, TCPFlow.maxWindow - pending.count))
                rcvNxt = rcvNxt &+ UInt32(accept)
                if pending.isEmpty, rfd >= 0 {
                    // Nothing waiting: straight from the segment, only the
                    // rest kept (no copy on the common path).
                    let (written, gone) = writeAvailable(rfd, seg.payload.prefix(accept))
                    if !gone, written < accept { pending.append(contentsOf: seg.payload.dropFirst(written).prefix(accept - written)) }
                } else {
                    pending.append(contentsOf: seg.payload.prefix(accept))
                    flushLocked(announce: false)   // the ACK below carries the window
                }
                if !pending.isEmpty { wakeReaderLocked() }
                emitLocked(flags: UtunPacket.ACK, payload: [][...])
            } else if seqLT(seg.seq, rcvNxt) {
                emitLocked(flags: UtunPacket.ACK, payload: [][...])   // dup → re-ACK
            }
        }

        // FIN (possibly piggybacked on the last data segment — matched by
        // sequence INCLUDING any payload the data branch just consumed).
        if seg.flags & UtunPacket.FIN != 0, state != .connecting, seg.seq &+ UInt32(seg.payload.count) == rcvNxt {
            rcvNxt = rcvNxt &+ 1
            emitLocked(flags: UtunPacket.ACK, payload: [][...])
            // Half-close toward the remote, once what's pending went out.
            if pending.isEmpty { if rfd >= 0 { fdShutdownWrite(rfd) } } else { shutdownPending = true }
            clientFin = true
            closeIfFullyClosedLocked()
        }
    }

    // MARK: Outbound (remote → client) reader

    private func startReader() {
        let fd = rfd
        let mss = self.mss
        readerStarted = true
        var p: [Int32] = [-1, -1]
        if pipe(&p) == 0 { fdSetNonBlocking(p[0]); fdSetNonBlocking(p[1]); wake = (p[0], p[1]) }
        // Its own copies: the flow may be gone by the time the reader stops
        // (it holds it weakly), and the pipe is closed either way.
        let wakeRead = p[0], wakeWrite = p[1]
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: mss)
            var eof = false
            while true {
                // The socket is non-blocking: wait for data (until the remote
                // side's EOF), and while bytes are pending for room to write
                // too (even after the EOF: the client's data still goes to it).
                // After the EOF with nothing pending, only the wake pipe: the
                // socket would report its hang-up again and again.
                guard let watching = self?.readerWatch() else { break }
                let events = (eof ? 0 : Int16(POLLIN)) | (watching ? Int16(POLLOUT) : 0)
                var fds = [pollfd(fd: events == 0 ? -1 : fd, events: events, revents: 0),
                           pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
                let r = poll(&fds, wakeRead >= 0 ? 2 : 1, 1000)
                if r < 0 { if errno == EINTR { continue }; self?.close(); break }
                if r == 0 { continue }
                if fds[1].revents & Int16(POLLIN) != 0 {
                    var drain = [UInt8](repeating: 0, count: 64)
                    while fdRead(wakeRead, &drain, drain.count) > 0 {}
                }
                let p = fds[0]
                // Room, or the socket's hang-up or error (macOS reports a closed
                // peer's full socket as POLLHUP alone): the flush finds out
                // (EPIPE clears what's pending), so this never spins.
                if watching, p.revents & (Int16(POLLOUT) | Int16(POLLHUP) | Int16(POLLERR)) != 0,
                   self?.windowMayOpen() == false {
                    usleep(10_000)   // nothing went (a passing error): no spin
                }
                guard !eof, p.revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 else { continue }
                let n = buf.withUnsafeMutableBytes { fdRead(fd, $0.baseAddress!, $0.count) }
                if n > 0 {
                    guard let self, self.sendData(Array(buf[0..<n])) else { break }
                } else if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    eof = true
                    self?.remoteClosed()   // EOF or error: our FIN; the flow ends once both sides are done
                }
            }
            // The flow is closed (closeLocked shut the socket and let go of
            // it): the numbers are closed here, once nothing waits on them,
            // and the pipe can't be written to any more.
            self?.close()
            self?.dropWake()
            FDGuard.close(fd, "tcpflow.rfd")
            if wakeRead >= 0 { fdClose(wakeRead) }
            if wakeWrite >= 0 { fdClose(wakeWrite) }
        }
    }

    /// Wakes the reader out of poll (lock held).
    private func wakeReaderLocked() {
        guard wake.write >= 0 else { return }
        var one: UInt8 = 1
        _ = fdWrite(wake.write, &one, 1)
    }

    /// Nothing writes to the wake pipe from now on (the reader closes it).
    private func dropWake() {
        cond.lock(); defer { cond.unlock() }
        wake = (-1, -1)
    }

    /// nil once the flow closed (the reader stops); else whether bytes are
    /// pending (the reader watches for room to write them).
    private func readerWatch() -> Bool? {
        cond.lock(); defer { cond.unlock() }
        readerTurns += 1
        return state == .closed ? nil : !pending.isEmpty
    }

    /// The remote socket has room: what's pending goes out, and once the
    /// window has grown by two segments, or to half of it, a window update
    /// tells the client (it resumes without waiting on its retransmission
    /// timer).
    /// False when there was something to write and nothing went.
    @discardableResult
    private func windowMayOpen() -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard state != .closed, !pending.isEmpty else { return true }
        let before = pending.count
        flushLocked()
        return pending.count < before || pending.isEmpty
    }

    /// Writes what's pending as far as the remote socket takes it (never
    /// blocking), then the half-close the client asked for if all went.
    /// `announce`: once the window has grown by two segments, or back to
    /// half, a window update tells the client (whichever path drained it:
    /// the reader's POLLOUT, a segment from the client, sendData's wait),
    /// so it never waits on its persist timer. Not when an ACK follows
    /// anyway (the data path).
    private func flushLocked(announce: Bool = true) {
        guard !pending.isEmpty else { return }
        defer {
            if announce, state != .closed {
                let now = TCPFlow.maxWindow - pending.count
                if now - lastWindow >= 2 * mss || (lastWindow < TCPFlow.maxWindow / 2 && now >= TCPFlow.maxWindow / 2) {
                    emitLocked(flags: UtunPacket.ACK, payload: [][...])
                }
            }
        }
        guard rfd >= 0 else { pending.removeAll(); return }
        let (written, gone) = writeAvailable(rfd, pending)
        if gone { pending.removeAll() } else if written > 0 { pending.removeFirst(written) }
        if pending.isEmpty, shutdownPending, rfd >= 0 { shutdownPending = false; fdShutdownWrite(rfd) }
        closeIfFullyClosedLocked()
    }

    /// Send `bytes` to the client as one segment, blocking until the receive
    /// window has room. Returns false if the flow closed.
    private func sendData(_ bytes: [UInt8]) -> Bool {
        cond.lock(); defer { cond.unlock() }
        var off = 0
        while off < bytes.count {
            // Timed: the pending bytes toward the remote keep going out while
            // this waits on the client's window (a bulk flow both ways).
            while state == .established && inFlight() >= clientWindow {
                if pending.isEmpty { cond.wait(); continue }
                _ = cond.wait(until: Date().addingTimeInterval(0.05))
                flushLocked()
            }
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
        // Not with acknowledged bytes still on their way to the remote.
        if finSent && clientFin && sndUna == sndNxt && pending.isEmpty && !shutdownPending { closeLocked() }
    }

    func close() { cond.lock(); closeLocked(); cond.unlock() }

    // MARK: Locked helpers (call with `cond` held)

    private func inFlight() -> UInt32 { sndNxt &- sndUna }

    private func emitLocked(flags: UInt8, payload: ArraySlice<UInt8>) {
        send(UtunPacket.TCPSegment(
            srcIP: key.dstIP, dstIP: key.srcIP, srcPort: key.dstPort, dstPort: key.srcPort,
            seq: sndNxt, ack: rcvNxt, flags: flags, window: advertisedWindowLocked(), payload: payload))
    }

    /// The free space in the remote socket's send buffer, up to 64 KiB (no
    /// window scaling): what we can take without refusing anything.
    /// What's left of a 64 KiB window once the pending bytes are counted:
    /// exact (our own accounting, no syscall), and never refused.
    private func advertisedWindowLocked() -> UInt16 {
        lastWindow = max(0, TCPFlow.maxWindow - pending.count)
        return UInt16(lastWindow)
    }

    private func sendRSTLocked() {
        send(UtunPacket.TCPSegment(
            srcIP: key.dstIP, dstIP: key.srcIP, srcPort: key.dstPort, dstPort: key.srcPort,
            seq: sndNxt, ack: rcvNxt, flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...]))
    }

    private func closeLocked() {
        guard state != .closed else { return }
        state = .closed
        // Shut before the close: the reader thread blocks in read(2) on this
        // fd, and on Linux a close doesn't wake it, so a cut or a RST would
        // leave the upstream leg running.
        // The reader, if there is one, closes the number itself once it's out
        // of poll and read (closed here, it could be another flow's by then).
        if rfd >= 0 {
            fdShutdownBoth(rfd)
            if !readerStarted { FDGuard.close(rfd, "tcpflow.rfd") }
            rfd = -1
        }
        wakeReaderLocked()   // out of its poll now, not at its timeout
        cond.broadcast()
        onClosed(key)
    }

    // MARK: Utilities

    /// Modular seq comparisons (RFC 793 "less than" over the 32-bit space).
    private func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
    private func seqLE(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }

    /// Writes what `fd` takes without blocking: the count written (short
    /// when its buffer filled, or a write failed for a passing reason), and
    /// whether the remote side is gone (EPIPE, ECONNRESET, ENOTCONN, EBADF:
    /// the flow is ending, nothing more will be read from it).
    private func writeAvailable(_ fd: Int32, _ bytes: some Collection<UInt8> & ContiguousBytes) -> (written: Int, gone: Bool) {
        var off = 0
        var gone = false
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while off < raw.count {
                let n = fdSendNonBlocking(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0, [EPIPE, ECONNRESET, ENOTCONN, EBADF].contains(errno) { gone = true }
                break
            }
        }
        return (off, gone)
    }
}
