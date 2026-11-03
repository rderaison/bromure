import Foundation
import Testing
@testable import bromure_ac

/// Board finding (CWE-670): when a Bromure AC relay parked at the Sidecar's
/// delegation hub, every local stream holding a call took that one offer as
/// its own and closed; their shims all reconnected, one got the relay, the
/// rest landed back on the local fallback and were refused 20 s later while
/// a relay was up. A park is reserved for the one stream it kicks.
@Suite("Sidecar delegation hub: which stream a parked relay is for")
struct DelegationFallbacksTests {
    @Test("a park picks one stream — a waiting call first; the others keep waiting, in order")
    func oneParkOneStream() {
        var f = DelegationFallbacks()
        f.add(5); f.add(6); f.add(7); f.add(8)
        f.hold(7); f.hold(6)                 // two calls waiting, 7's first
        #expect(f.kick() == 7)
        #expect(f.kicked(7))
        #expect(!f.kicked(6) && !f.kicked(5) && !f.kicked(8))   // not theirs: they wait on
        #expect(f.kick() == 6)               // the next park: the next waiting call
        #expect(f.kick() == 5)               // then the oldest idle stream
        #expect(f.streams == [8])
    }

    @Test("a call that gave up, or a stream that ended, isn't picked; a reused number starts fresh")
    func releasedAndEnded() {
        var f = DelegationFallbacks()
        f.add(5); f.add(6)
        f.hold(6); f.release(6)              // refused after the grace
        f.hold(9)                            // not a local stream: ignored
        #expect(f.kick() == 5)
        f.hold(6)
        f.remove(6)                          // its shim hung up
        #expect(f.kick() == nil)
        f.add(6)                             // the number again, a new stream
        #expect(!f.kicked(6))
        #expect(f.kick() == 6)
    }
}
