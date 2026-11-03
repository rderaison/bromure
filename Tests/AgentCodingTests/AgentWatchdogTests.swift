import Foundation
import Testing
@testable import bromure_ac

@Suite("Agent watchdog")
struct AgentWatchdogTests {
    final class Trips: @unchecked Sendable { var list: [(UUID, AgentWatchdogMode, Int)] = [] }

    private func make(_ mode: AgentWatchdogMode) -> (AgentWatchdog, UUID, Trips) {
        let w = AgentWatchdog()
        let pid = UUID()
        let trips = Trips()
        w.modeProvider = { _ in mode }
        w.onTrip = { p, m, s in trips.list.append((p, m, s.reduce(0) { $0 + $1.weight })) }
        return (w, pid, trips)
    }

    private func deny(_ w: AgentWatchdog, _ pid: UUID, at t: Date, layer: String = "sni") {
        w.observe(profileID: pid, eventType: "egress.firewall",
                  eventData: ["action": .string("deny"), "layer": .string(layer), "host": .string("x.example")], now: t)
    }

    @Test("A burst of denials within the window trips once")
    func burst() {
        let (w, pid, trips) = make(.quarantine)
        let t0 = Date()
        for i in 0..<19 { deny(w, pid, at: t0.addingTimeInterval(Double(i))) }
        #expect(trips.list.isEmpty)
        deny(w, pid, at: t0.addingTimeInterval(20))
        #expect(trips.list.count == 1)
        #expect(trips.list.first?.1 == .quarantine)
        for i in 0..<30 { deny(w, pid, at: t0.addingTimeInterval(21 + Double(i))) }
        #expect(trips.list.count == 1)                         // already tripped
        w.release(profileID: pid)
        #expect(w.score(profileID: pid, now: t0.addingTimeInterval(52)) == 0)
    }

    @Test("Signals older than the window don't count")
    func window() {
        let (w, pid, trips) = make(.alert)
        let t0 = Date()
        for i in 0..<15 { deny(w, pid, at: t0.addingTimeInterval(Double(i) * 10)) }   // spread over 150 s
        #expect(trips.list.isEmpty)
    }

    @Test("Heavy signals trip fast: unmanaged credentials, tampering")
    func heavy() {
        let (w, pid, trips) = make(.alert)
        let t0 = Date()
        w.observe(profileID: pid, eventType: "credential.unmanaged",
                  eventData: ["kind": .string("github-token"), "host": .string("evil.example")], now: t0)
        deny(w, pid, at: t0.addingTimeInterval(1), layer: "identity")          // attestor impersonation: 10
        w.observe(profileID: pid, eventType: "credential.unmanaged",
                  eventData: ["kind": .string("aws-access-key"), "host": .string("evil.example")], now: t0.addingTimeInterval(2))
        #expect(trips.list.count == 1)
    }

    @Test("Off does nothing; new destinations count only after the session settles")
    func offAndDestinations() {
        let (off, opid, offTrips) = make(.off)
        for i in 0..<50 { deny(off, opid, at: Date().addingTimeInterval(Double(i))) }
        #expect(offTrips.list.isEmpty)

        let (w, pid, _) = make(.alert)
        let t0 = Date()
        w.observe(profileID: pid, eventType: "egress.firewall",
                  eventData: ["action": .string("allowed"), "host": .string("early.example")], now: t0)
        #expect(w.score(profileID: pid, now: t0) == 0)
        let late = t0.addingTimeInterval(AgentWatchdog.settleTime + 5)
        w.observe(profileID: pid, eventType: "egress.firewall",
                  eventData: ["action": .string("allowed"), "host": .string("late.example")], now: late)
        #expect(w.score(profileID: pid, now: late) == 1)
        w.observe(profileID: pid, eventType: "egress.firewall",
                  eventData: ["action": .string("allowed"), "host": .string("late.example")], now: late)
        #expect(w.score(profileID: pid, now: late) == 1)       // seen already
    }

    @Test("Outbound volume far above the session's baseline is a signal")
    func volume() {
        let (w, pid, _) = make(.alert)
        let t0 = Date()
        var total: UInt64 = 0
        for i in 0..<12 {                                       // ~100 KB/s baseline
            total += 500_000
            w.sampleBytes(profileID: pid, total: total, now: t0.addingTimeInterval(Double(i) * 5), interval: 5)
        }
        #expect(w.score(profileID: pid, now: t0.addingTimeInterval(60)) == 0)
        total += 100_000_000                                    // 20 MB/s burst
        let t = t0.addingTimeInterval(65)
        w.sampleBytes(profileID: pid, total: total, now: t, interval: 5)
        #expect(w.score(profileID: pid, now: t) == 8)
    }
}
