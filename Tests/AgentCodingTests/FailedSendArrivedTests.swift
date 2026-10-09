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
}
