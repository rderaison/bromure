import Foundation
import Testing
@testable import bromure_ac

/// Board request: over a slow link (trains, tunnels) what the user sent sat
/// in the queue with nothing showing it was still on its way. The fat
/// client's title bar now says "Sending…" — once a send has waited a beat,
/// so a quick link never flickers it.
@Suite("Fat client: the Sending… cue")
struct OutgoingIndicatorTests {
    @Test("shows only once the oldest send has waited past the delay")
    func showsAfterABeat() {
        let now = Date()
        #expect(!OutgoingIndicator.shows(oldest: nil, now: now))
        #expect(!OutgoingIndicator.shows(oldest: now.addingTimeInterval(-0.1), now: now))
        #expect(OutgoingIndicator.shows(oldest: now.addingTimeInterval(-OutgoingIndicator.delay - 0.01), now: now))
        #expect(OutgoingIndicator.shows(oldest: now.addingTimeInterval(-30), now: now))
    }
}
