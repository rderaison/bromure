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

    /// Claude JSONL user turns, one per line.
    private func jsonl(_ texts: [String], from second: Int = 0) -> Data {
        Data(texts.enumerated().map { i, t in
            #"{"type":"user","message":{"role":"user","content":"\#(t)"},"timestamp":"2026-10-10T10:00:\#(String(format: "%02d", second + i)).000Z"}"#
        }.joined(separator: "\n").appending("\n").utf8)
    }

    @Test("the turns Load Earlier puts in front are counted from its bytes, repeated prompts and all")
    func prependedFromBytes() {
        // The finding's under-shift: the tail is ["thanks"]; the earlier
        // chunk starts with "thanks" too. Two turns came in front.
        #expect(BeautifiedSessionModel.userTurnsPrepended(jsonl(["thanks", "ship the fix"]),
                                                         before: jsonl(["thanks"], from: 30)) == 2)
        // Its over-shift: old ["continue"], one older turn in front, while
        // a new "continue" came in at the end — still 1, not 2.
        #expect(BeautifiedSessionModel.userTurnsPrepended(jsonl(["older"]),
                                                         before: jsonl(["continue", "continue"], from: 30)) == 1)
        #expect(BeautifiedSessionModel.userTurnsPrepended(Data(), before: jsonl(["a"])) == 0)
    }

    @Test("a Not sent row stays when Load Earlier brings back an older turn with the same text")
    func olderTurnAfterPrepend() {
        // Sent "thanks" again with ["thanks"] loaded: baseline 1. Load
        // Earlier reads ["thanks", "ship the fix"] in front.
        let shifted = 1 + BeautifiedSessionModel.userTurnsPrepended(jsonl(["thanks", "ship the fix"]),
                                                                   before: jsonl(["thanks"], from: 30))
        let after = ["thanks", "ship the fix", "thanks"]
        let q = held("thanks", baseline: shifted, failure: ChatQueueStore.notTypedText)
        #expect(!BeautifiedSessionModel.arrivedAnyway(q, turns: after))
        // Its own turn, when it does come, still clears it.
        #expect(BeautifiedSessionModel.arrivedAnyway(q, turns: after + ["thanks"]))
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
