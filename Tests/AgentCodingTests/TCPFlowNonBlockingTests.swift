import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// TCPFlow (shared by the utun tunnel, the macOS switch MITM and the Linux
/// interceptor) against a remote end that never reads: nothing blocks under
/// its lock (a close returns at once), the window it advertises shrinks to
/// what the socket can take, and opens again when it drains.
@Suite("TCPFlow against a remote end that never reads", .serialized)
struct TCPFlowNonBlockingTests {
    final class Rig: @unchecked Sendable {
#if canImport(Glibc)
        static let stream = Int32(SOCK_STREAM.rawValue)
#else
        static let stream = SOCK_STREAM
#endif
        let lock = NSLock()
        var segments: [UtunPacket.TCPSegment] = []
        var closed = false
        let ours: Int32, theirs: Int32
        let flow: TCPFlow
        let client: UInt32 = 0x0A00_0002, server: UInt32 = 0xCB00_7109
        let isn: UInt32 = 5000
        init() throws {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, Self.stream, 0, &fds) == 0 else { throw POSIXError(.EIO) }
            ours = fds[0]; theirs = fds[1]
            let syn = UtunPacket.TCPSegment(srcIP: client, dstIP: server, srcPort: 41000, dstPort: 443, seq: isn, ack: 0,
                                            flags: UtunPacket.SYN, window: 65535, payload: [][...])
            let endA = ours
            var me: Rig?
            flow = TCPFlow(key: UtunPacket.FlowKey(syn), clientISN: isn, mss: 1400, dial: { endA },
                           send: { s in me?.lock.lock(); me?.segments.append(s); me?.lock.unlock() },
                           onClosed: { _ in me?.lock.lock(); me?.closed = true; me?.lock.unlock() })
            me = self
        }
        func sent() -> [UtunPacket.TCPSegment] { lock.lock(); defer { lock.unlock() }; return segments }
        func seg(_ seq: UInt32, ack: UInt32, payload: [UInt8] = []) -> UtunPacket.TCPSegment {
            UtunPacket.TCPSegment(srcIP: client, dstIP: server, srcPort: 41000, dstPort: 443, seq: seq, ack: ack,
                                  flags: UtunPacket.ACK, window: 65535, payload: payload[...])
        }
        /// The handshake; returns our ISN.
        func open() throws -> UInt32 {
            flow.start()
            var synack: UtunPacket.TCPSegment?
            for _ in 0..<300 where synack == nil {
                synack = sent().first { $0.flags & UtunPacket.SYN != 0 }
                if synack == nil { usleep(10_000) }
            }
            let s = try #require(synack)
            flow.onInbound(seg(isn + 1, ack: s.seq + 1))
            return s.seq
        }
    }

    @Test func aFullRemoteSocketNeverHoldsTheFlow() throws {
        let rig = try Rig(); defer { close(rig.theirs) }
        let server = try rig.open()
        // The remote socket has room for a window's worth (a macOS
        // socketpair's default is 8 KiB).
        var sndbuf: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(rig.ours, SOL_SOCKET, SO_SNDBUF, &sndbuf, &len)
        #expect(sndbuf >= 256 << 10, "its send buffer: \(sndbuf)")
        // 2 MiB into an end nobody reads, from another thread: each segment
        // is taken or refused at once, never waited on.
        let done = DispatchSemaphore(value: 0)
        let isn = rig.isn
        Thread.detachNewThread {
            var seq = isn + 1
            for _ in 0..<1500 {
                rig.flow.onInbound(rig.seg(seq, ack: server + 1, payload: [UInt8](repeating: 1, count: 1400)))
                seq &+= 1400
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success, "no segment waited on the full socket")
        let acks = rig.sent().filter { $0.flags & UtunPacket.SYN == 0 }
        #expect((acks.last?.window ?? 65535) < 1400, "the window closed with the socket: \(acks.last?.window ?? 0)")
        #expect((acks.last?.ack ?? 0) &- (isn + 1) < 1500 * 1400, "the refused part isn't acknowledged")
        // Drained: a window update arrives on its own.
        let before = rig.sent().count
        var buf = [UInt8](repeating: 0, count: 65536)
        _ = fcntl(rig.theirs, F_SETFL, fcntl(rig.theirs, F_GETFL) | O_NONBLOCK)
        let end = Date().addingTimeInterval(1)
        while Date() < end { if read(rig.theirs, &buf, buf.count) <= 0 { usleep(5_000) } }
        var update = false
        for _ in 0..<200 where !update {
            update = rig.sent().dropFirst(before).contains { $0.window >= 1400 }
            if !update { usleep(10_000) }
        }
        #expect(update, "a window update once the socket drained")
        // A zero-window probe (a bare segment at snd.una − 1) is answered with
        // an ACK and the window as it is.
        let acked = rig.sent().last?.ack ?? 0
        let n0 = rig.sent().count
        rig.flow.onInbound(rig.seg(acked &- 1, ack: server + 1))
        #expect(rig.sent().count > n0 && rig.sent().last?.ack == acked, "the probe was answered")
        // And a close, with the socket full again, returns at once.
        var seq = isn + 1 + UInt32(acks.last.map { $0.ack &- (isn + 1) } ?? 0)
        for _ in 0..<300 { rig.flow.onInbound(rig.seg(seq, ack: server + 1, payload: [UInt8](repeating: 2, count: 1400))); seq &+= 1400 }
        let closed = DispatchSemaphore(value: 0)
        Thread.detachNewThread { rig.flow.close(); closed.signal() }
        #expect(closed.wait(timeout: .now() + 3) == .success, "the close didn't wait on the full socket")
    }

    /// Open descriptors in this process (a scan: works on both systems).
    static func openFDs() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }

    @Test func aClosedFlowLeavesNoDescriptorBehind() throws {
        // 500 flows: a leak of 2 descriptors each would show as ~1000, far
        // past what other tests running alongside open meanwhile.
        let before = Self.openFDs()
        for _ in 0..<500 {
            let rig = try Rig()
            _ = try rig.open()
            rig.flow.close()
            close(rig.theirs)
        }
        var after = Self.openFDs()
        for _ in 0..<300 where after > before + 200 { usleep(10_000); after = Self.openFDs() }
        #expect(after < before + 200, "descriptors: \(before) before, \(after) after 500 flows")
    }

    @Test func noSpinAfterTheRemotesEOF() throws {
        let rig = try Rig()
        _ = try rig.open()
        close(rig.theirs)                            // the remote's gone (its hang-up); the client keeps its side open
        usleep(200_000)
        let t0 = rig.flow.readerTurnsForTesting
        usleep(1_000_000)
        let turns = rig.flow.readerTurnsForTesting - t0
        #expect(turns < 20, "the idle reader's turns in 1 s after the remote's EOF: \(turns)")
        rig.flow.close()
    }

    @Test func acknowledgedBytesReachTheRemoteAfterBothFINs() throws {
        let rig = try Rig()
        let server = try rig.open()
        // The remote half-closes; our FIN goes to the client, which ACKs it.
        shutdown(rig.theirs, Int32(SHUT_WR))
        var fin: UtunPacket.TCPSegment?
        for _ in 0..<300 where fin == nil {
            fin = rig.sent().first { $0.flags & UtunPacket.FIN != 0 }
            if fin == nil { usleep(10_000) }
        }
        let ourFin = try #require(fin)
        rig.flow.onInbound(rig.seg(rig.isn + 1, ack: ourFin.seq + 1))
        // The client's last bytes (more than the socket takes at once), then
        // its FIN, all acknowledged; then the remote reads.
        var seq = rig.isn + 1
        for _ in 0..<600 {
            rig.flow.onInbound(rig.seg(seq, ack: ourFin.seq + 1, payload: [UInt8](repeating: 3, count: 1400)))
            seq &+= 1400
        }
        let acked = Int((rig.sent().last?.ack ?? 0) &- (rig.isn + 1))
        rig.flow.onInbound(UtunPacket.TCPSegment(srcIP: rig.client, dstIP: rig.server, srcPort: 41000, dstPort: 443,
                                                 seq: rig.isn + 1 + UInt32(acked), ack: ourFin.seq + 1,
                                                 flags: UtunPacket.FIN | UtunPacket.ACK, window: 65535, payload: [][...]))
        var got = 0, buf = [UInt8](repeating: 0, count: 65536)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(rig.theirs, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true { let n = read(rig.theirs, &buf, buf.count); if n <= 0 { break }; got += n }
        #expect(got == acked && acked > 0, "every acknowledged byte reached the remote: \(got) of \(acked)")
        _ = server
        close(rig.theirs)
    }

    /// Bytes pending (the socket full), then the remote closes: the reader
    /// finds out (the flush's EPIPE) instead of spinning on the hang-up.
    @Test func noSpinWhenTheRemoteClosesWithBytesPending() throws {
        let rig = try Rig()
        let server = try rig.open()
        var seq = rig.isn + 1
        for _ in 0..<600 {
            rig.flow.onInbound(rig.seg(seq, ack: server + 1, payload: [UInt8](repeating: 5, count: 1400)))
            seq &+= 1400
        }
        close(rig.theirs)
        usleep(300_000)
        let t0 = rig.flow.readerTurnsForTesting
        usleep(1_000_000)
        let turns = rig.flow.readerTurnsForTesting - t0
        #expect(turns < 20, "the reader's turns in 1 s after the remote closed with bytes pending: \(turns)")
        rig.flow.close()
    }
}
