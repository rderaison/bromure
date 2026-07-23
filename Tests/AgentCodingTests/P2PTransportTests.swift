import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bromure_ac

// The direct transport + loopback shim, exercised over real loopback sockets
// (no control plane, no VM). Proves that the endpoint the broker hands back
// really carries bytes to the winning candidate.

@Suite("P2P direct transport")
struct P2PTransportTests {

    /// An echo server on a loopback ephemeral port. Returns the port; the
    /// listener fd is closed when `stop()` is called.
    final class EchoServer: @unchecked Sendable {
        let port: Int
        private let lfd: Int32
        init?() {
            let (fd, port) = FatForward.listenEphemeral(bindAll: false)
            guard fd >= 0 else { return nil }
            lfd = fd; self.port = port
            Thread.detachNewThread { [lfd] in
                while true {
                    let c = Darwin.accept(lfd, nil, nil)
                    if c < 0 { break }
                    Thread.detachNewThread {
                        var buf = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = Darwin.read(c, &buf, buf.count)
                            if n <= 0 { break }
                            var off = 0
                            while off < n {
                                let w = buf.withUnsafeBytes { Darwin.write(c, $0.baseAddress!.advanced(by: off), n - off) }
                                if w <= 0 { break }
                                off += w
                            }
                        }
                        Darwin.close(c)
                    }
                }
            }
        }
        func stop() { Darwin.close(lfd) }
    }

    @Test("P2PTCP.connect succeeds to a live port, fails to a dead one")
    func tcpConnect() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        let ok = P2PTCP.connect(ip: "127.0.0.1", port: echo.port, timeout: 2)
        #expect(ok != nil)
        if let ok { Darwin.close(ok) }

        // A port nothing listens on refuses fast (or times out) → nil.
        let dead = P2PTCP.connect(ip: "127.0.0.1", port: 9, timeout: 1)
        #expect(dead == nil)
    }

    @Test("direct dialer skips an unreachable candidate for a reachable one")
    func dialerPicksReachable() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        let bad = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1", port: 9, prio: 1000)
        let good = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1", port: echo.port, prio: 10)
        let win = P2PDirectDialer.dial(candidates: [bad, good],
                                       perCandidateTimeout: 1,
                                       overallDeadline: Date().addingTimeInterval(5))
        let w = try #require(win)
        #expect(w.candidate.port == echo.port)
        Darwin.close(w.fd)
    }

    @Test("the dialer races candidates instead of walking them one by one")
    func dialerRacesInParallel() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        // TEST-NET-1 black-holes: each of these burns the whole per-candidate
        // budget. Walked in sequence they'd cost 3 × 1.5 s before the reachable
        // (lowest-priority) candidate got a turn; raced, they cost one budget.
        let blackHoles = (1...3).map {
            P2PCandidate(kind: .host, proto: .tcp, ip: "192.0.2.\($0)", port: 2222, prio: 1000)
        }
        let good = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1",
                                port: echo.port, prio: 10)
        let t0 = Date()
        let win = P2PDirectDialer.dial(candidates: blackHoles + [good],
                                       perCandidateTimeout: 1.5,
                                       overallDeadline: Date().addingTimeInterval(20))
        let elapsed = Date().timeIntervalSince(t0)
        let w = try #require(win)
        #expect(w.candidate.port == echo.port)
        #expect(elapsed < 3.0)   // sequential would need ≥ 4.5 s
        Darwin.close(w.fd)
    }

    @Test("a dead ladder gives up after the impatient budget, not the patient one")
    func dialerFastPassBudget() throws {
        // Nothing reachable: the caller gets its answer after the 1s pass plus
        // the 3s patient retry — NOT 3s per candidate, and not sooner than the
        // patient pass (a slow relay still gets its chance).
        let blackHoles = (1...3).map {
            P2PCandidate(kind: .host, proto: .tcp, ip: "192.0.2.\($0)", port: 2222)
        }
        let t0 = Date()
        let win = P2PDirectDialer.dial(candidates: blackHoles,
                                       overallDeadline: Date().addingTimeInterval(20))
        let elapsed = Date().timeIntervalSince(t0)
        #expect(win == nil)
        #expect(elapsed >= 1.0)   // the impatient pass really was 1s, not 0
        #expect(elapsed < 6.0)    // 1s + 3s patient, not 3s × 3 candidates
    }

    @Test("a reachable candidate returns well inside the impatient budget")
    func dialerFastPassWins() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        let dead = P2PCandidate(kind: .host, proto: .tcp, ip: "192.0.2.9",
                                port: 2222, prio: 1000)
        let good = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1",
                                port: echo.port, prio: 10)
        let t0 = Date()
        let win = P2PDirectDialer.dial(candidates: [dead, good],
                                       overallDeadline: Date().addingTimeInterval(20))
        let elapsed = Date().timeIntervalSince(t0)
        let w = try #require(win)
        #expect(w.candidate.port == echo.port)
        // Bounded by the impatient budget + the higher-priority upgrade grace,
        // never by the patient retry.
        #expect(elapsed < 1.5)
        Darwin.close(w.fd)
    }

    @Test("a higher-priority candidate still wins when both connect")
    func dialerPrefersHigherPriority() throws {
        let low = try #require(EchoServer())
        let high = try #require(EchoServer())
        defer { low.stop(); high.stop() }
        let win = P2PDirectDialer.dial(
            candidates: [P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1",
                                      port: low.port, prio: 10),
                         P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1",
                                      port: high.port, prio: 900)],
            perCandidateTimeout: 2,
            overallDeadline: Date().addingTimeInterval(5))
        let w = try #require(win)
        #expect(w.candidate.port == high.port)
        Darwin.close(w.fd)
    }

    @Test("a stopped shim reports itself dead so the broker can re-establish")
    func shimLiveness() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        let winner = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1", port: echo.port)
        let shim = try #require(P2PLoopbackShim(winner: winner))
        #expect(shim.isAlive)
        shim.stop()
        // Its port now refuses every dial — the cache entry must not be handed
        // out again (that was the "Connection refused" reconnect on iOS).
        #expect(!shim.isAlive)
        #expect(P2PTCP.connect(ip: "127.0.0.1", port: shim.port, timeout: 1) == nil)
    }

    @Test("loopback shim byte-pumps to the winning candidate")
    func shimSplice() throws {
        let echo = try #require(EchoServer())
        defer { echo.stop() }
        let winner = P2PCandidate(kind: .host, proto: .tcp, ip: "127.0.0.1", port: echo.port)
        let shim = try #require(P2PLoopbackShim(winner: winner))
        defer { shim.stop() }
        #expect(shim.port > 0)

        // Dial the shim's loopback endpoint and round-trip a message through it.
        let fd = try #require(P2PTCP.connect(ip: "127.0.0.1", port: shim.port, timeout: 2))
        defer { Darwin.close(fd) }
        let msg = Array("ping-through-shim".utf8)
        var m = msg
        #expect(Darwin.write(fd, &m, m.count) == m.count)

        // Read may need a beat while the shim establishes its downstream leg.
        var out = [UInt8]()
        let deadline = Date().addingTimeInterval(3)
        while out.count < msg.count && Date() < deadline {
            var tmp = [UInt8](repeating: 0, count: 64)
            let n = Darwin.read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            out.append(contentsOf: tmp[0..<n])
        }
        #expect(out == msg)
    }

    @Test("path label + report-kind mapping")
    func pathLabels() {
        #expect(P2PPath.lan.uiLabel == "Direct (LAN)")
        #expect(P2PPath.direct.uiLabel == "Direct")
        #expect(P2PPath.relay.uiLabel == "Relayed")
        #expect(P2PPath.lan.reportKind == .direct)
        #expect(P2PPath.relay.reportKind == .relay)
    }
}
