import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: a message sent to a busy agent showed "Delivered — queued by …"
/// above the composer, and sometimes it never went away (until the user
/// switched sessions), with an Edit link on it. A delivered row now leaves
/// after 30 s whatever the transcript shows, and offers no Edit.
@Suite("Delivered queue rows leave, and can't be edited")
@MainActor
struct DeliveredRowTests {
    private func row(held: Bool = false, editable: Bool = true, delivered: Bool = false,
                     handedOver: Bool = false, at: Date? = nil) -> QueuedMessage {
        var q = QueuedMessage(text: "also run the tests", held: held, editable: editable, baseline: 0)
        q.delivered = delivered ? true : nil
        q.handedOver = handedOver ? true : nil
        q.deliveredAt = at
        return q
    }

    @Test("a delivered row expires 30 s after delivery; a waiting one never does")
    func expiry() {
        let now = Date()
        let fresh = row(delivered: true, at: now.addingTimeInterval(-5))
        let old = row(delivered: true, at: now.addingTimeInterval(-31))
        let handed = row(handedOver: true, at: now.addingTimeInterval(-40))
        let waiting = row(held: true, at: now.addingTimeInterval(-600))
        let unstamped = row(delivered: true, at: nil)            // saved before the stamp existed
        #expect(!fresh.deliveredExpired(at: now))
        #expect(old.deliveredExpired(at: now))
        #expect(handed.deliveredExpired(at: now))
        #expect(!waiting.deliveredExpired(at: now), "held by Bromure: still to be sent")
        #expect(!unstamped.deliveredExpired(at: now))
        // The strip stops showing it even with no reconcile to drop it.
        let shown = QueuedMessagesStrip.shown([fresh, old, handed, waiting], at: now)
        #expect(shown.map(\.id) == [fresh.id, waiting.id])
    }

    @Test("Edit is offered on what's still waiting, never on what the agent has")
    func noEditOnceDelivered() {
        #expect(!row(delivered: true, at: Date()).offersEdit(alwaysEditable: false))
        #expect(!row(handedOver: true, at: Date()).offersEdit(alwaysEditable: false))
        #expect(!row(delivered: true, at: Date()).offersEdit(alwaysEditable: true), "the paused view too")
        #expect(row(held: true).offersEdit(alwaysEditable: false))
        #expect(!row(editable: false).offersEdit(alwaysEditable: false))
        #expect(row(editable: false).offersEdit(alwaysEditable: true))
        var failed = row(delivered: true, at: Date()); failed.failure = "Not delivered"
        #expect(failed.offersEdit(alwaysEditable: false), "a failure can be taken back")
        var sending = row(held: true); sending.sending = true
        #expect(!sending.offersEdit(alwaysEditable: true))
    }

    @Test("a message Bromure types in is stamped delivered at that moment")
    func stampedOnDelivery() async {
        let store = ChatQueueStore(fileURL: nil)
        store.update("k") { $0.append(QueuedMessage(text: "next", held: true, editable: true, baseline: 0,
                                                    target: .chat(window: 3, windowID: "@41", display: nil, worktree: nil))) }
        let before = Date()
        let driver = ChatQueueStore.Driver(isWorking: { false }, deliver: { _, _ in .typed })
        _ = await store.deliverHeld("k", driver: driver, fallback: nil)
        let q = store.messages("k").first
        #expect(q?.agentHasIt == true)
        #expect((q?.deliveredAt ?? .distantPast) >= before)
    }

    @Test("an older saved queue (no stamp) still decodes")
    func decodesOld() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","text":"x","queuedAt":0,"held":false,"editable":true,"baseline":0,"offset":0,"sending":false,"delivered":true}]"#
        let rows = try JSONDecoder().decode([QueuedMessage].self, from: Data(json.utf8))
        #expect(rows.first?.deliveredAt == nil && rows.first?.agentHasIt == true)
    }
}
