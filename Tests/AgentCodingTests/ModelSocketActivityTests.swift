import Foundation
import Testing
@testable import bromure_ac

// Codex's whole session is one WebSocket to OpenAI: frames flowing over it
// are what says it's working — keep-alives aren't, and it's throttled.

@Suite("Model WebSocket activity")
struct ModelSocketActivityTests {
    final class Counter: @unchecked Sendable { var n = 0 }

    @Test("streaming frames beat at most every couple of seconds; pings and pongs never")
    func beat() {
        let c = Counter()
        let beat = HTTPMitmConnection.ActivityBeat(fire: { c.n += 1 })
        let text = Data([0x81, 0x7E, 0x00, 0x80]) + Data(repeating: 0x61, count: 128)   // a text frame
        beat.tick(text)
        beat.tick(text)
        #expect(c.n == 1)   // throttled
        let idle = HTTPMitmConnection.ActivityBeat(fire: { c.n += 100 })
        idle.tick(Data([0x89, 0x00]))   // ping
        idle.tick(Data([0x8A, 0x04, 1, 2, 3, 4]))   // pong
        #expect(c.n == 1)
        idle.tick(text)
        #expect(c.n == 101)
        // Not a model host: no signal at all.
        HTTPMitmConnection.ActivityBeat(fire: nil).tick(text)
        #expect(c.n == 101)
    }
}
