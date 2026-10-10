import Foundation
import Testing
@testable import bromure_ac

/// A message marked failed whose turn shows up after all went through —
/// the fat client's "it says it didn't go through, but it did".
@Suite("Failed sends that arrived anyway")
struct FailedSendArrivedTests {

    private func held(_ text: String, baseline: Int, failure: String?) -> QueuedMessage {
        QueuedMessage(text: text, held: true, editable: true, baseline: baseline,
                      path: nil, offset: 0, target: nil, failure: failure)
    }

    @Test("Not sent, Not delivered and not taken all clear once a later turn carries the text")
    func everyFailureClears() {
        let turns = ["earlier", "please run the tests"]
        for f in [ChatQueueStore.notTypedText, ChatQueueStore.notDeliveredText,
                  BeautifiedSessionModel.notTakenText] {
            #expect(BeautifiedSessionModel.arrivedAnyway(held("please run the tests", baseline: 1, failure: f),
                                                         turns: turns))
        }
    }

    @Test("A turn counted before the send was marked failed is still seen")
    func baselineBeforeTheSend() {
        // The send's turn was read while the send was still out (a slow
        // fat-client type): counted from before the send, it is found.
        let turns = ["earlier", "please run the tests"]
        #expect(BeautifiedSessionModel.arrivedAnyway(
            held("please run the tests", baseline: 1, failure: ChatQueueStore.notTypedText), turns: turns))
        // From after it (the old baseline), it never was.
        #expect(!BeautifiedSessionModel.arrivedAnyway(
            held("please run the tests", baseline: 2, failure: ChatQueueStore.notTypedText), turns: turns))
    }

    @Test("A held message with no failure, or a turn from before it, stays")
    func othersStay() {
        let turns = ["please run the tests"]
        #expect(!BeautifiedSessionModel.arrivedAnyway(
            held("please run the tests", baseline: 0, failure: nil), turns: turns))
        #expect(!BeautifiedSessionModel.arrivedAnyway(
            held("please run the tests", baseline: 1, failure: ChatQueueStore.notTypedText), turns: turns))
        #expect(!BeautifiedSessionModel.arrivedAnyway(
            held("something else", baseline: 0, failure: ChatQueueStore.notTypedText), turns: turns))
    }

    // Finding 82159FB7: older history read in front moved the baseline.

    @Test("older turns read in front shift by their count; turns after don't, nor a fresh read")
    func prependShift() {
        let tail = ["A", "B"]
        #expect(BeautifiedSessionModel.turnsPrepended(old: tail, new: ["W", "X", "Y", "Z", "A", "B"]) == 4)
        // Prepended while new turns came in at the end.
        #expect(BeautifiedSessionModel.turnsPrepended(old: tail, new: ["W", "A", "B", "C"]) == 1)
        #expect(BeautifiedSessionModel.turnsPrepended(old: tail, new: ["A", "B", "C"]) == 0)
        #expect(BeautifiedSessionModel.turnsPrepended(old: tail, new: ["P", "Q", "R"]) == 0)
        #expect(BeautifiedSessionModel.turnsPrepended(old: [], new: ["A"]) == 0)
    }

    @Test("a Not sent row stays when Load Earlier brings back an older turn with the same text")
    func olderTurnAfterPrepend() {
        // Sent "B" again with [A, B] loaded: baseline 2. Backfill reads
        // [W, X, Y, Z] in front; the baseline moves with them.
        let before = ["A", "B"], after = ["W", "X", "Y", "Z", "A", "B"]
        let shifted = 2 + BeautifiedSessionModel.turnsPrepended(old: before, new: after)
        let q = held("B", baseline: shifted, failure: ChatQueueStore.notTypedText)
        #expect(!BeautifiedSessionModel.arrivedAnyway(q, turns: after))
        // Its own turn, when it does come, still clears it.
        #expect(BeautifiedSessionModel.arrivedAnyway(q, turns: after + ["B"]))
    }

    @Test("Not sent clears only on a turn that is the message, not one containing or starting like it")
    func notSentWholeMessage() {
        let text = "please run the whole test suite again"
        let q = held(text, baseline: 0, failure: ChatQueueStore.notTypedText)
        #expect(!BeautifiedSessionModel.arrivedAnyway(q, turns: ["earlier: \(text), and then fix it"]))
        #expect(!BeautifiedSessionModel.arrivedAnyway(q, turns: ["please run the whole test suite on CI instead"]))
        #expect(BeautifiedSessionModel.arrivedAnyway(q, turns: ["please run the whole\n test suite again "]))
        // Typed by Bromure and not taken: a turn it became still clears it.
        let typed = held(text, baseline: 0, failure: BeautifiedSessionModel.notTakenText)
        #expect(BeautifiedSessionModel.arrivedAnyway(typed, turns: ["please run the whole test suite again — all of it"]))
    }
}
