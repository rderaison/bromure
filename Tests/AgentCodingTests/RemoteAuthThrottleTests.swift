import Foundation
import Testing
@testable import bromure_ac

@Suite("Remote auth throttle")
struct RemoteAuthThrottleTests {

    @Test("Burst budget passes immediately, then attempts serialize")
    func serialization() {
        let t = RemoteAuthThrottle(capacity: 3, refillPerSec: 0.5, maxDelay: 8)
        // Burst: first `capacity` attempts run now.
        for _ in 0..<3 {
            #expect(t.reserve(ip: "10.0.0.1") == 0)
        }
        // Past the burst, each attempt gets a LATER slot than the previous —
        // the monotonic schedule, not a shared capped delay.
        var last: TimeInterval = -1
        for _ in 0..<3 {
            guard let d = t.reserve(ip: "10.0.0.1") else {
                Issue.record("refused before the queue was full"); return
            }
            #expect(d > last)
            last = d
        }
    }

    @Test("A flood is refused once the schedule exceeds maxDelay")
    func floodRefused() {
        let t = RemoteAuthThrottle(capacity: 2, refillPerSec: 0.5, maxDelay: 4)
        var accepted = 0
        var refused = 0
        for _ in 0..<50 {
            if t.reserve(ip: "10.0.0.2") != nil { accepted += 1 } else { refused += 1 }
        }
        // 2 burst + ~maxDelay/interval queued; the other ~45 refused outright.
        #expect(accepted <= 5)
        #expect(refused >= 45)
    }

    @Test("IPs are throttled independently")
    func perIP() {
        let t = RemoteAuthThrottle(capacity: 1, refillPerSec: 0.5, maxDelay: 2)
        #expect(t.reserve(ip: "10.0.0.3") == 0)   // burst token
        _ = t.reserve(ip: "10.0.0.3")             // takes the immediate slot
        // The schedule is now occupied: the next attempt waits (or is refused).
        let third = t.reserve(ip: "10.0.0.3")
        #expect(third == nil || third! > 0)
        #expect(t.reserve(ip: "10.0.0.4") == 0)   // other IP: unaffected
    }

    @Test("Global verification concurrency is bounded and releasable")
    func inFlightCap() {
        let t = RemoteAuthThrottle()
        var held = 0
        while t.beginVerification() { held += 1; if held > 100 { break } }
        #expect(held == 16)
        t.endVerification()
        #expect(t.beginVerification())
    }
}
