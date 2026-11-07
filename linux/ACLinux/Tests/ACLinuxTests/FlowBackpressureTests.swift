import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux
import SandboxEngine

/// A slow reader on the proxy's side never holds the switch: a flow's
/// blocking writes run on its port's queue, and a raw relay reads no faster
/// than its peer takes the bytes.
@Suite("Interception backpressure", .serialized)
struct FlowBackpressureTests {
    /// 4 MiB of in-order data into a flow whose application end nobody reads
    /// (its socketpair fills after a few hundred KiB): the caller, the
    /// switch's task, gets every segment handed off at once.
    @Test func aStalledFlowNeverBlocksTheSwitch() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: proxy, guestMTU: 1500) { _, ip in injected.withLockedValue { $0.append(ip) } }
        let app = NIOLockedValueBox<Int32>(-1)
        interceptor.handOffForTesting = { fd in app.withLockedValue { $0 = fd } }
        defer { interceptor.portClosed(portID: 7) }
        let dst = TestFrames.ip("203.0.113.9"), sport: UInt16 = 41000, isn: UInt32 = 5000
        interceptor.handleDivertedPacket(portID: 7, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x02, seq: isn, sport: sport).dropFirst(14)))
        // Our SYN-ACK: its sequence number.
        var ours: UInt32?
        for _ in 0..<200 where ours == nil {
            ours = injected.withLockedValue { $0 }.compactMap(UtunPacket.parse).first { $0.flags & UtunPacket.SYN != 0 }?.seq
            if ours == nil { usleep(10_000) }
        }
        let server = try #require(ours, "the flow answered the SYN")
        interceptor.handleDivertedPacket(portID: 7, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x10, seq: isn + 1, ack: server + 1, sport: sport).dropFirst(14)))
        let chunk = [UInt8](repeating: 0x5a, count: 1400), segments = 3000
        let handedOff = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var seq = isn + 1
            for _ in 0..<segments {
                let s = UtunPacket.TCPSegment(srcIP: TestFrames.guestIP, dstIP: dst, srcPort: sport, dstPort: 443,
                                              seq: seq, ack: server + 1, flags: UtunPacket.ACK, window: 65535, payload: chunk[...])
                interceptor.handleDivertedPacket(portID: 7, profileID: UUID(), ipPacket: UtunPacket.build(s))
                seq &+= UInt32(chunk.count)
            }
            handedOff.signal()
        }
        #expect(handedOff.wait(timeout: .now() + 5) == .success, "the switch's caller was never held by the full socket")
        // What waits for the stuck flow is bounded: past its budget the guest's
        // segments were dropped (its TCP sends them again), not queued.
        #expect(interceptor.queuedBytes <= SwitchInterceptor.flowBudget, "queued \(interceptor.queuedBytes) bytes")
        // Drain the application end: what was taken arrives in order, and the
        // flow's queue finishes (no write left blocked).
        let fd = app.withLockedValue { $0 }
        var got = 0, buf = [UInt8](repeating: 0, count: 65536)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            #expect(buf[0..<n].allSatisfy { $0 == 0x5a })
            got += n
        }
        #expect(got > 0 && got < segments * chunk.count,
                "what the end's buffer took arrived, the rest was left unacknowledged for a resend: \(got)")
        for _ in 0..<200 where interceptor.queuedBytes > 0 { usleep(10_000) }
        #expect(interceptor.queuedBytes == 0, "the queue drained")
        close(fd)
    }

    /// One stuck flow doesn't hold the VM's others: each has its own queue.
    @Test func aStuckFlowDoesntHoldAnotherOnTheSamePort() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: proxy, guestMTU: 1500) { _, ip in injected.withLockedValue { $0.append(ip) } }
        let apps = NIOLockedValueBox<[Int32]>([])
        interceptor.handOffForTesting = { fd in apps.withLockedValue { $0.append(fd) } }
        defer { interceptor.portClosed(portID: 3); for fd in apps.withLockedValue({ $0 }) { close(fd) } }
        let dst = TestFrames.ip("203.0.113.9"), isn: UInt32 = 7000
        func open(_ sport: UInt16) throws -> UInt32 {
            interceptor.handleDivertedPacket(portID: 3, profileID: UUID(),
                                             ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x02, seq: isn, sport: sport).dropFirst(14)))
            var ours: UInt32?
            for _ in 0..<200 where ours == nil {
                ours = injected.withLockedValue { $0 }.compactMap(UtunPacket.parse)
                    .first { $0.flags & UtunPacket.SYN != 0 && $0.dstPort == sport }?.seq
                if ours == nil { usleep(10_000) }
            }
            let server = try #require(ours)
            interceptor.handleDivertedPacket(portID: 3, profileID: UUID(),
                                             ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x10, seq: isn + 1, ack: server + 1, sport: sport).dropFirst(14)))
            return server
        }
        func data(_ sport: UInt16, _ server: UInt32, _ n: Int, byte: UInt8) {
            var seq = isn + 1
            for _ in 0..<n {
                let s = UtunPacket.TCPSegment(srcIP: TestFrames.guestIP, dstIP: dst, srcPort: sport, dstPort: 443, seq: seq, ack: server + 1,
                                              flags: UtunPacket.ACK, window: 65535, payload: [UInt8](repeating: byte, count: 1400)[...])
                interceptor.handleDivertedPacket(portID: 3, profileID: UUID(), ipPacket: UtunPacket.build(s))
                seq &+= 1400
            }
        }
        let stuck = try open(42000)
        data(42000, stuck, 1000, byte: 1)          // ~1.4 MB into an end nobody reads: its write blocks
        let other = try open(42001)
        data(42001, other, 10, byte: 2)
        let fd = try #require(apps.withLockedValue { $0 }.last)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var got = 0, buf = [UInt8](repeating: 0, count: 65536)
        while got < 14_000 { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; got += n }
        #expect(got == 14_000, "the second flow's bytes arrived while the first is stuck: \(got)")
        // The first is still stuck (nobody read it): closing the port doesn't
        // wait on it (a write never blocks with the flow's lock held).
        let closed = DispatchSemaphore(value: 0)
        Thread.detachNewThread { interceptor.portClosed(portID: 3); closed.signal() }
        #expect(closed.wait(timeout: .now() + 3) == .success, "the port closed with a flow whose reader never drained")
    }

    /// TCPFlow (shared): a flow whose application end is never read closes
    /// at once, with segments still coming in for it.
    @Test func aFlowWhoseReaderNeverDrainsClosesAtOnce() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: proxy, guestMTU: 1500) { _, ip in injected.withLockedValue { $0.append(ip) } }
        let app = NIOLockedValueBox<Int32>(-1)
        interceptor.handOffForTesting = { fd in app.withLockedValue { $0 = fd } }
        defer { close(app.withLockedValue { $0 }) }
        let dst = TestFrames.ip("203.0.113.9"), sport: UInt16 = 43000, isn: UInt32 = 9000
        interceptor.handleDivertedPacket(portID: 5, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x02, seq: isn, sport: sport).dropFirst(14)))
        var ours: UInt32?
        for _ in 0..<200 where ours == nil {
            ours = injected.withLockedValue { $0 }.compactMap(UtunPacket.parse).first { $0.flags & UtunPacket.SYN != 0 }?.seq
            if ours == nil { usleep(10_000) }
        }
        let server = try #require(ours)
        interceptor.handleDivertedPacket(portID: 5, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x10, seq: isn + 1, ack: server + 1, sport: sport).dropFirst(14)))
        // Keep sending (as a guest would retransmit) while the port closes.
        let stop = NIOLockedValueBox(false)
        Thread.detachNewThread {
            var seq = isn + 1
            while !stop.withLockedValue({ $0 }) {
                let s = UtunPacket.TCPSegment(srcIP: TestFrames.guestIP, dstIP: dst, srcPort: sport, dstPort: 443, seq: seq, ack: server + 1,
                                              flags: UtunPacket.ACK, window: 65535, payload: [UInt8](repeating: 9, count: 1400)[...])
                interceptor.handleDivertedPacket(portID: 5, profileID: UUID(), ipPacket: UtunPacket.build(s))
                seq &+= 1400
            }
        }
        defer { stop.withLockedValue { $0 = true } }
        usleep(300_000)      // its socket's buffer is full by now
        let closed = DispatchSemaphore(value: 0)
        Thread.detachNewThread { interceptor.portClosed(portID: 5); closed.signal() }
        #expect(closed.wait(timeout: .now() + 3) == .success, "closing didn't wait on the full socket")
        #expect(interceptor.openFlows == 0)
    }

    /// A raw relay whose peer doesn't read: the relaying side stops reading
    /// once the peer's buffer is full, rather than buffering everything.
    @Test func aRelayReadsNoFasterThanItsPeerTakes() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        // The peer: a TCP server that accepts and never reads.
        let stalled = NIOLockedValueBox<Channel?>(nil)
        let server = try ServerBootstrap(group: group)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { ch in stalled.withLockedValue { $0 = ch }; return ch.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { server.close(promise: nil) }
        let (guest, app) = try GuestEnd.pair()
        defer { close(guest) }
        let loop = group.next()
        let glue = ByteGlue(peer: nil)
        let guestCh = try loop.submit {
            try NIOPipeBootstrap(group: loop).channelInitializer { $0.pipeline.addHandler(glue) }
        }.wait().takingOwnershipOfDescriptor(inputOutput: app).wait()
        defer { guestCh.close(promise: nil) }
        let up = try ClientBootstrap(group: loop).channelInitializer { $0.pipeline.addHandler(ByteGlue(peer: guestCh)) }
            .connect(host: "127.0.0.1", port: server.localAddress!.port!).wait()
        defer { up.close(promise: nil) }
        try loop.submit { glue.attach(up) }.wait()
        // The guest writes 64 MiB as fast as it can, non-blocking: with
        // backpressure the relay stops reading, the socketpair fills, and
        // the guest's writes stop going in long before 64 MiB.
        let flags = fcntl(guest, F_GETFL)
        _ = fcntl(guest, F_SETFL, flags | O_NONBLOCK)
        let chunk = [UInt8](repeating: 7, count: 65536)
        var sent = 0
        let end = Date().addingTimeInterval(3)
        while Date() < end, sent < 64 << 20 {
            let n = chunk.withUnsafeBytes { send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n > 0 { sent += n } else { usleep(5_000) }
        }
        #expect(sent < 32 << 20, "the relay held back once its peer stopped taking: \(sent >> 10) KiB went in")
    }

    /// Before its peer connects, a relay holds a bounded amount and then
    /// stops reading; attached, it reads (and forwards) the rest.
    @Test func aRelayHoldsABoundedAmountUntilItsPeerConnects() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let (guest, app) = try GuestEnd.pair()
        defer { close(guest) }
        let loop = group.next()
        let glue = ByteGlue(peer: nil)
        let guestCh = try loop.submit {
            try NIOPipeBootstrap(group: loop).channelInitializer { $0.pipeline.addHandler(glue) }
        }.wait().takingOwnershipOfDescriptor(inputOutput: app).wait()
        defer { guestCh.close(promise: nil) }
        _ = fcntl(guest, F_SETFL, fcntl(guest, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: 7, count: 65536)
        func pump(_ seconds: Double) -> Int {
            var sent = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, sent < 64 << 20 {
                let n = chunk.withUnsafeBytes { send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                if n > 0 { sent += n } else { usleep(5_000) }
            }
            return sent
        }
        let before = pump(2)
        #expect(before < 16 << 20, "unattached, it stopped reading: \(before >> 10) KiB went in")
        // Attached to a sink that reads: the guest's writes flow again.
        let sunk = NIOLockedValueBox(0)
        final class Sink: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            let n: NIOLockedValueBox<Int>
            init(_ n: NIOLockedValueBox<Int>) { self.n = n }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let b = unwrapInboundIn(data); n.withLockedValue { $0 += b.readableBytes }
            }
        }
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Sink(sunk)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { server.close(promise: nil) }
        let up = try ClientBootstrap(group: loop).channelInitializer { $0.pipeline.addHandler(ByteGlue(peer: guestCh)) }
            .connect(host: "127.0.0.1", port: server.localAddress!.port!).wait()
        defer { up.close(promise: nil) }
        try loop.submit { glue.attach(up) }.wait()
        let after = pump(1)
        #expect(after > 1 << 20, "attached, it reads again: \(after >> 10) KiB more went in")
        for _ in 0..<200 where sunk.withLockedValue({ $0 }) < before { usleep(10_000) }
        #expect(sunk.withLockedValue { $0 } >= before, "what it held went on first")
    }

    /// TCPFlow (shared) advertises what its remote socket can take: the
    /// window closes as the socket fills, and a window update follows when
    /// it drains (no waiting on the client's retransmission timer).
    @Test func theWindowIsTheSocketsRoomAndReopensWhenItDrains() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let injected = NIOLockedValueBox<[[UInt8]]>([])
        let interceptor = SwitchInterceptor(proxy: proxy, guestMTU: 1500) { _, ip in injected.withLockedValue { $0.append(ip) } }
        let app = NIOLockedValueBox<Int32>(-1)
        interceptor.handOffForTesting = { fd in app.withLockedValue { $0 = fd } }
        defer { interceptor.portClosed(portID: 6); close(app.withLockedValue { $0 }) }
        let dst = TestFrames.ip("203.0.113.9"), sport: UInt16 = 44000, isn: UInt32 = 11000
        interceptor.handleDivertedPacket(portID: 6, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x02, seq: isn, sport: sport).dropFirst(14)))
        var synack: UtunPacket.TCPSegment?
        for _ in 0..<200 where synack == nil {
            synack = injected.withLockedValue { $0 }.compactMap(UtunPacket.parse).first { $0.flags & UtunPacket.SYN != 0 }
            if synack == nil { usleep(10_000) }
        }
        let server = try #require(synack).seq
        #expect(try #require(synack).window > 0)
        interceptor.handleDivertedPacket(portID: 6, profileID: UUID(),
                                         ipPacket: Array(TestFrames.tcp(to: dst, port: 443, flags: 0x10, seq: isn + 1, ack: server + 1, sport: sport).dropFirst(14)))
        // Fill it: nobody reads the application end.
        var seq = isn + 1
        for _ in 0..<1000 {
            let s = UtunPacket.TCPSegment(srcIP: TestFrames.guestIP, dstIP: dst, srcPort: sport, dstPort: 443, seq: seq, ack: server + 1,
                                          flags: UtunPacket.ACK, window: 65535, payload: [UInt8](repeating: 7, count: 1400)[...])
            interceptor.handleDivertedPacket(portID: 6, profileID: UUID(), ipPacket: UtunPacket.build(s))
            seq &+= 1400
        }
        for _ in 0..<200 where interceptor.queuedBytes > 0 { usleep(10_000) }
        let acks = injected.withLockedValue { $0 }.compactMap(UtunPacket.parse).filter { $0.flags & UtunPacket.ACK != 0 && $0.flags & UtunPacket.SYN == 0 }
        let last = try #require(acks.last)
        #expect(last.window < 1400, "the window closed with the socket full: \(last.window)")
        let before = injected.withLockedValue { $0.count }
        // Drain it: a window update arrives on its own.
        let fd = app.withLockedValue { $0 }
        var buf = [UInt8](repeating: 0, count: 65536)
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while recv(fd, &buf, buf.count, 0) > 0 {}
        var update: UtunPacket.TCPSegment?
        for _ in 0..<200 where update == nil {
            update = injected.withLockedValue { Array($0.dropFirst(before)) }.compactMap(UtunPacket.parse).first { $0.window >= 1400 }
            if update == nil { usleep(10_000) }
        }
        #expect(update != nil, "a window update once the socket drained")
    }
}
