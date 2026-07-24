import Foundation
import Testing
@testable import bromure_ac

// The RelayARQ protocol engine, driven on a virtual clock through a simulated
// channel we can make as hostile as we like. `ARQConnection` is pure (time
// injected, no sockets), so two engines wired output→peer.input reproduce a full
// session deterministically — the same seed always exercises the same loss and
// reordering pattern.

@Suite("RelayARQ")
struct RelayARQTests {

    /// A deterministic channel: drops, duplicates, and reorders datagrams under
    /// a seeded LCG so failures reproduce exactly.
    final class Link {
        struct Pkt { let at: Int64; let to: Int; let bytes: [UInt8] }
        private(set) var inflight: [Pkt] = []
        private var state: UInt64
        private let loss: Double
        private let dup: Double
        private let jMin: Int64
        private let jMax: Int64

        init(seed: UInt64, loss: Double, dup: Double, jitterMin: Int64, jitterMax: Int64) {
            self.state = seed &* 2862933555777941757 &+ 3037000493
            self.loss = loss; self.dup = dup; self.jMin = jitterMin; self.jMax = jitterMax
        }

        private func rand() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        private func jitter() -> Int64 { jMin + Int64(rand() * Double(max(1, jMax - jMin))) }

        func send(now: Int64, to: Int, bytes: [UInt8]) {
            if rand() < loss { return }                       // dropped
            inflight.append(Pkt(at: now + jitter(), to: to, bytes: bytes))
            if rand() < dup { inflight.append(Pkt(at: now + jitter(), to: to, bytes: bytes)) }
        }

        /// Deliver every packet whose scheduled time has arrived.
        func drain(now: Int64, deliver: (Int, [UInt8]) -> Void) {
            let due = inflight.filter { $0.at <= now }
            inflight.removeAll { $0.at <= now }
            for p in due { deliver(p.to, p.bytes) }
        }
    }

    /// Deterministic pseudo-random payload so byte-exactness is checkable.
    private func payload(_ n: Int, seed: UInt64) -> [UInt8] {
        var s = seed | 1
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: s >> 33)
        }
    }

    /// Run a full bidirectional session over `link` and return what each side
    /// received. Fails (returns nil) if it doesn't complete within the budget.
    private func runSession(conv: UInt32, aToB: [UInt8], bToA: [UInt8],
                            link: Link, maxMs: Int64 = 400_000)
        -> (aRecv: [UInt8], bRecv: [UInt8])? {
        var now: Int64 = 0
        let a = ARQConnection(conv: conv, isInitiator: true, now: now, mss: 1100)
        let b = ARQConnection(conv: conv, isInitiator: false, now: now, mss: 1100)
        var aRecv: [UInt8] = []; var bRecv: [UInt8] = []
        // `now` is captured by reference — output fires synchronously inside the
        // write/input/update calls below, so it always reads the current tick.
        a.output = { link.send(now: now, to: 1, bytes: $0) }
        b.output = { link.send(now: now, to: 0, bytes: $0) }
        a.deliver = { aRecv += $0 }
        b.deliver = { bRecv += $0 }

        a.update(now: now); b.update(now: now)     // kick the handshake
        a.write(aToB, now: now)
        b.write(bToA, now: now)

        while now < maxMs {
            now += 1
            link.drain(now: now) { to, bytes in
                if to == 0 { a.input(bytes, now: now) } else { b.input(bytes, now: now) }
            }
            a.update(now: now); b.update(now: now)
            if bRecv.count >= aToB.count && aRecv.count >= bToA.count { break }
        }
        guard bRecv.count == aToB.count, aRecv.count == bToA.count else { return nil }
        return (aRecv, bRecv)
    }

    @Test("clean link: exact bidirectional transfer")
    func cleanTransfer() {
        let aToB = payload(64_000, seed: 1)
        let bToA = payload(9_000, seed: 2)
        let link = Link(seed: 7, loss: 0, dup: 0, jitterMin: 2, jitterMax: 8)
        let r = runSession(conv: 0x11223344, aToB: aToB, bToA: bToA, link: link)
        #expect(r != nil)
        #expect(r?.bRecv == aToB)
        #expect(r?.aRecv == bToA)
    }

    @Test("20% loss + reordering + dups: bytes still exact and in order")
    func lossyReordered() {
        let aToB = payload(120_000, seed: 42)
        let bToA = payload(20_000, seed: 43)
        let link = Link(seed: 20260724, loss: 0.20, dup: 0.05, jitterMin: 5, jitterMax: 60)
        let r = runSession(conv: 0xA1B2C3D4, aToB: aToB, bToA: bToA, link: link)
        #expect(r != nil)
        #expect(r?.bRecv == aToB)
        #expect(r?.aRecv == bToA)
    }

    @Test("severe 40% loss still converges")
    func severeLoss() {
        let aToB = payload(40_000, seed: 99)
        let link = Link(seed: 555, loss: 0.40, dup: 0.02, jitterMin: 10, jitterMax: 120)
        let r = runSession(conv: 0xDEADBEEF, aToB: aToB, bToA: [], link: link)
        #expect(r != nil)
        #expect(r?.bRecv == aToB)
    }

    @Test("half-close propagates a FIN and both ends close")
    func closePropagation() {
        var now: Int64 = 0
        let conv: UInt32 = 0xCAFEF00D
        let a = ARQConnection(conv: conv, isInitiator: true, now: now, mss: 1100)
        let b = ARQConnection(conv: conv, isInitiator: false, now: now, mss: 1100)
        let link = Link(seed: 3, loss: 0.1, dup: 0, jitterMin: 2, jitterMax: 10)
        var bRecv: [UInt8] = []
        var bEOF = 0
        a.output = { link.send(now: now, to: 1, bytes: $0) }
        b.output = { link.send(now: now, to: 0, bytes: $0) }
        b.deliver = { bRecv += $0 }
        b.onDeliverEOF = { bEOF += 1 }

        a.update(now: now); b.update(now: now)
        let msg = payload(5_000, seed: 8)
        a.write(msg, now: now)
        a.closeWrite(now: now)          // A is done writing after `msg`
        b.closeWrite(now: now)          // B has nothing to send; close too

        while now < 200_000 {
            now += 1
            link.drain(now: now) { to, bytes in
                if to == 0 { a.input(bytes, now: now) } else { b.input(bytes, now: now) }
            }
            a.update(now: now); b.update(now: now)
            if a.isClosed && b.isClosed { break }
        }
        #expect(bRecv == msg)           // all data delivered before the FIN
        #expect(bEOF == 1)              // peer-EOF signalled exactly once
        #expect(a.isClosed)
        #expect(b.isClosed)
    }
}
