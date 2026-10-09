import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import bromure_ac

// The fat client on a high-latency link (Japan → a US server, through a TURN
// relay): RTT estimation, adaptive timeouts, the reconnect hysteresis that
// keeps one slow poll from flipping the window to "Reconnecting…", and the
// simulated-latency knob used to reproduce it on a LAN.

@Suite("Fat-client link health")
struct FatClientLinkHealthTests {

    // MARK: RTT estimator

    @Test("first sample seeds SRTT and RTTVAR = R/2 (RFC 6298)")
    func firstSample() {
        var e = LinkRTTEstimator()
        e.add(0.2)
        #expect(e.srtt == 0.2)
        #expect(abs(e.rttvar - 0.1) < 1e-9)
        #expect(e.minRTT == 0.2)
        #expect(e.samples == 1)
    }

    @Test("SRTT converges toward a new steady RTT; min tracks the floor")
    func converges() {
        var e = LinkRTTEstimator()
        e.add(0.005)                       // LAN
        for _ in 0..<60 { e.add(0.25) }    // moved to a trans-Pacific path
        #expect(abs((e.srtt ?? 0) - 0.25) < 0.01)
        #expect(e.rttvar < 0.01)
        #expect(e.minRTT == 0.005)
    }

    @Test("throughput ignores small replies, smooths big ones")
    func throughput() {
        var t = ThroughputEstimator()
        t.add(bytes: 1_000, seconds: 0.001)              // too small to mean anything
        #expect(t.bytesPerSecond == nil)
        t.add(bytes: 1_000_000, seconds: 1)
        #expect(t.bytesPerSecond == 1_000_000)
        t.add(bytes: 2_000_000, seconds: 1)
        #expect(abs((t.bytesPerSecond ?? 0) - 1_300_000) < 1)
    }

    // MARK: Adaptive timeouts

    @Test("timeouts keep the LAN values on a fast or unmeasured link")
    func lanUnchanged() {
        #expect(LinkTimeouts.recvIdle(base: 12, srtt: nil, rttvar: 0) == 12)
        #expect(LinkTimeouts.recvIdle(base: 12, srtt: 0.004, rttvar: 0.001) == 12)
        #expect(LinkTimeouts.recvIdle(base: 75, srtt: 0.3, rttvar: 0.1) == 75)   // caller's long budget wins
        #expect(LinkTimeouts.pollGap(srtt: nil) == 0.75)
        #expect(LinkTimeouts.pollGap(srtt: 0.02) == 0.75)
    }

    @Test("a slow, jittery link stretches the read timeout, up to a cap")
    func wanStretches() {
        // ~800 ms request RTT ± 200 ms: a poll over a relay from Japan.
        let t = LinkTimeouts.recvIdle(base: 12, srtt: 0.8, rttvar: 0.2)
        #expect(t > 12)
        #expect(abs(t - (8 + 16 * (0.8 + 0.8))) < 1e-9)
        // A pathological link still gives up eventually.
        #expect(LinkTimeouts.recvIdle(base: 12, srtt: 5, rttvar: 3) == LinkTimeouts.recvIdleCap)
        // Polls space out with RTT, never past 3 s.
        #expect(LinkTimeouts.pollGap(srtt: 0.8) == 2.0)
        #expect(LinkTimeouts.pollGap(srtt: 4) == 3.0)
    }

    @Test("LinkStats feeds the timeout and the readout")
    func statsReadout() {
        let s = LinkStats()
        #expect(s.recvIdleTimeout(base: 12) == 12)
        s.recordLatency(0.8)
        #expect(s.recvIdleTimeout(base: 12) > 12)
        s.recordTransfer(bytes: 1_048_576, seconds: 1)
        let line = LinkStats.describe(s.snapshot(), path: "P2P relay (bromure.io)")
        #expect(line.contains("800 ms"))
        #expect(line.contains("P2P relay"))
        #expect(LinkStats.shared(for: UUID()) !== LinkStats.shared(for: UUID()))
        let id = UUID()
        #expect(LinkStats.shared(for: id) === LinkStats.shared(for: id))
    }

    // MARK: Reconnect hysteresis

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("before the first answer: connecting, then down on failure")
    func firstConnect() {
        var m = LinkHealthMonitor()
        #expect(m.state(at: t0) == .connecting)
        m.recordFailure()
        #expect(m.state(at: t0) == .down)
        m.recordSuccess(at: t0)
        #expect(m.state(at: t0) == .live)
    }

    @Test("one failed poll on an established link is 'slow', not a drop")
    func singleFailureIsSlow() {
        var m = LinkHealthMonitor()
        m.recordSuccess(at: t0)
        m.recordFailure()
        // Even well after the last success, ONE failure isn't a drop…
        #expect(m.state(at: t0.addingTimeInterval(20)) == .slow)
        // …until the link has been silent long enough.
        #expect(m.state(at: t0.addingTimeInterval(LinkHealthMonitor.downAfterSilence)) == .down)
    }

    @Test("fast consecutive failures go down only after the minimum silence")
    func fastFailures() {
        var m = LinkHealthMonitor()
        m.recordSuccess(at: t0)
        for _ in 0..<LinkHealthMonitor.downAfterFailures { m.recordFailure() }
        #expect(m.state(at: t0.addingTimeInterval(2)) == .slow)        // a blip
        #expect(m.state(at: t0.addingTimeInterval(LinkHealthMonitor.minSilenceBeforeDown)) == .down)
    }

    @Test("bytes still arriving elsewhere keep a struggling link out of 'down'")
    func progressKeepsItUp() {
        var m = LinkHealthMonitor()
        m.recordSuccess(at: t0)
        for _ in 0..<5 { m.recordFailure() }
        let now = t0.addingTimeInterval(60)
        // A transcript download is still streaming: saturated, not gone.
        #expect(m.state(at: now, lastProgressAt: now.addingTimeInterval(-1)) == .slow)
        #expect(m.state(at: now, lastProgressAt: t0) == .down)
    }

    @Test("a success heals at once; high RTT alone reads 'slow'")
    func healsAndSlowRTT() {
        var m = LinkHealthMonitor()
        m.recordSuccess(at: t0)
        for _ in 0..<5 { m.recordFailure() }
        #expect(m.state(at: t0.addingTimeInterval(40)) == .down)
        m.recordSuccess(at: t0.addingTimeInterval(41))
        #expect(m.state(at: t0.addingTimeInterval(41)) == .live)
        #expect(m.consecutiveFailures == 0)
        #expect(m.state(at: t0.addingTimeInterval(41), srtt: 0.3) == .live)
        #expect(m.state(at: t0.addingTimeInterval(41), srtt: LinkHealthMonitor.slowRTT + 0.5) == .slow)
    }

    @Test("a silently stalled link (no failure yet) reads 'slow' once quiet past a poll gap")
    func silentStall() {
        var m = LinkHealthMonitor()
        m.recordSuccess(at: t0)
        // Normal poll gaps (≤ 5 s with push) stay live.
        #expect(m.state(at: t0.addingTimeInterval(6)) == .live)
        // Black-holed: nothing fails until a timeout, but it's been quiet.
        #expect(m.state(at: t0.addingTimeInterval(LinkHealthMonitor.slowAfterSilence + 1)) == .slow)
        // Bytes still arriving on another request count as alive.
        #expect(m.state(at: t0.addingTimeInterval(LinkHealthMonitor.slowAfterSilence + 1),
                        lastProgressAt: t0.addingTimeInterval(LinkHealthMonitor.slowAfterSilence)) == .live)
    }

    @Test("the window presentation follows the hysteresis, auth verdicts bypass it")
    @MainActor
    func presentation() {
        #expect(RemoteHostController.linkPresentation(connected: true, hasSnapshot: true, verdict: nil) == .live)
        #expect(RemoteHostController.linkPresentation(connected: false, hasSnapshot: true, verdict: .unreachable) == .reconnecting)
        #expect(RemoteHostController.linkPresentation(connected: false, hasSnapshot: true, verdict: .authFailed) == .needsKey)
    }

    // MARK: ControlClient over a slow responder

    /// A fake control socket: answers one request after `delay`, from a
    /// socketpair the client "dials".
    private func slowServer(delay: TimeInterval, body: String = #"{"ok":true}"#) -> Int32 {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = fds[1]
        // The client may give up first and close its end: no SIGPIPE.
        var one: Int32 = 1
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(server, &buf, buf.count)
            Thread.sleep(forTimeInterval: delay)
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = resp.withCString { Darwin.write(server, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: 0.2)
            Darwin.close(server)
        }
        return fds[0]
    }

    @Test("a reply slower than the fixed timeout fails without link stats")
    func fixedTimeoutFails() {
        let fd = slowServer(delay: 2.2)
        let client = ControlClient(socketPath: "test") { fd }
        #expect(throws: (any Error).self) {
            _ = try client.request("GET", "/state", recvTimeoutSeconds: 1)
        }
    }

    @Test("over a measured slow link the same reply is waited for, and timed")
    func adaptiveTimeoutWaits() throws {
        let stats = LinkStats()
        stats.recordLatency(0.5)       // a slow link, measured
        let fd = slowServer(delay: 2.2)
        var client = ControlClient(socketPath: "test") { fd }
        client.linkStats = stats
        let resp = try client.request("GET", "/state", recvTimeoutSeconds: 1)
        #expect(resp.status == 200)
        #expect(resp.json["ok"] as? Bool == true)
        let snap = stats.snapshot()
        #expect(snap.samples == 2)                    // /state is an RTT sample
        #expect((snap.lastRTT ?? 0) >= 2.0)
        #expect(snap.lastProgressAt != nil)
    }

    @Test("work-running calls aren't taken as RTT samples")
    func onlyCheapCallsSample() {
        #expect(ControlClient.samplesLatency("GET", "/state"))
        #expect(ControlClient.samplesLatency("GET", "/health"))
        #expect(!ControlClient.samplesLatency("POST", "/vms/x/exec"))
        #expect(!ControlClient.samplesLatency("GET", "/agent-sessions/x/transcript"))
    }

    // MARK: Simulated slow link

    @Test("simulation knob reads env (and is off by default)")
    func simulationConfig() {
        #expect(!LinkSimulation.fromEnvironment([:], defaults: UserDefaults(suiteName: "linktest-\(UUID())")).isActive)
        let s = LinkSimulation.fromEnvironment(["BROMURE_FATCLIENT_SIM_RTT_MS": "300",
                                                "BROMURE_FATCLIENT_SIM_JITTER_MS": "40",
                                                "BROMURE_FATCLIENT_SIM_KBPS": "200"])
        #expect(s == LinkSimulation(rttMs: 300, jitterMs: 40, kbps: 200))
        #expect(s.isActive)
        #expect(s.label.contains("300"))
    }

    @Test("simulated link delays reads by half the RTT, in order, and paces bandwidth")
    func simulatedHandler() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(handler: SimulatedLinkHandler(LinkSimulation(rttMs: 200, kbps: 100)),
                                      loop: loop)
        var a = channel.allocator.buffer(capacity: 8); a.writeString("first")
        var b = channel.allocator.buffer(capacity: 8); b.writeString("second")
        try channel.writeInbound(a)
        try channel.writeInbound(b)
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)   // still "in flight"
        loop.advanceTime(by: .milliseconds(99))
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        loop.advanceTime(by: .milliseconds(5))
        #expect(try channel.readInbound(as: ByteBuffer.self).map { String(buffer: $0) } == "first")
        loop.advanceTime(by: .milliseconds(5))
        #expect(try channel.readInbound(as: ByteBuffer.self).map { String(buffer: $0) } == "second")

        // 100 KB/s: a 50 KB chunk takes ~0.5 s on the wire before its 100 ms hop.
        var big = channel.allocator.buffer(capacity: 51_200)
        big.writeBytes([UInt8](repeating: 7, count: 51_200))
        try channel.writeInbound(big)
        loop.advanceTime(by: .milliseconds(400))
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        loop.advanceTime(by: .milliseconds(300))
        #expect(try channel.readInbound(as: ByteBuffer.self)?.readableBytes == 51_200)

        // Writes are delayed too.
        var out = channel.allocator.buffer(capacity: 4); out.writeString("ping")
        channel.write(out, promise: nil)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        loop.advanceTime(by: .milliseconds(101))
        #expect(try channel.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) } == "ping")
        _ = try? channel.finish()
    }
}
