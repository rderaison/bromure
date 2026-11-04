import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

@Suite("Transcript indicators")
@MainActor
struct TranscriptIndicatorsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }

    private func user(_ id: Int, _ at: Date?) -> TranscriptItem { TranscriptItem(id: id, kind: .userText("q"), timestamp: at) }
    private func reply(_ id: Int, _ at: Date?, _ s: String = "a") -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistantText(s), timestamp: at)
    }
    private func tool(_ id: Int, _ at: Date?) -> TranscriptItem {
        TranscriptItem(id: id, kind: .toolUse(name: "Bash", summary: "ls", detail: ""), timestamp: at)
    }
    private func store() -> ChatSeenStore {
        ChatSeenStore(defaults: UserDefaults(suiteName: "chat-seen-\(UUID().uuidString)")!)
    }

    @Test("the day is marked at the top and where it changes; a long pause is marked, a short one isn't")
    func markers() {
        let m = TranscriptTimeline.markers([
            .item(reply(1, t0)),
            .item(reply(2, t0.addingTimeInterval(60))),
            .item(reply(3, t0.addingTimeInterval(60 + TranscriptTimeline.gap))),
            .item(reply(4, t0.addingTimeInterval(86_400))),
        ], calendar: cal)
        #expect(m[1]?.kind == .day)
        #expect(m[2] == nil)
        #expect(m[3]?.kind == .time)
        #expect(m[4]?.kind == .day)
    }

    @Test("your message already says its time, so a pause adds no marker over it; a new day still does")
    func noDoubleTime() {
        let m = TranscriptTimeline.markers([
            .item(reply(1, t0)),
            .item(user(2, t0.addingTimeInterval(TranscriptTimeline.gap))),
            .item(user(3, t0.addingTimeInterval(86_400))),
        ], calendar: cal)
        #expect(m[2] == nil)
        #expect(m[3]?.kind == .day)
    }

    @Test("rows with no time are stepped over")
    func untimed() {
        let m = TranscriptTimeline.markers([.item(reply(1, nil)), .item(reply(2, t0))], calendar: cal)
        #expect(m[1] == nil)
        #expect(m[2]?.kind == .day)
    }

    @Test("today and yesterday read as words")
    func labels() {
        #expect(TranscriptTimeline.dayLabel(t0, now: t0, calendar: cal) == "Today")
        #expect(TranscriptTimeline.dayLabel(t0, now: t0.addingTimeInterval(86_400), calendar: cal) == "Yesterday")
        #expect(TranscriptTimeline.dayLabel(t0, now: t0.addingTimeInterval(86_400 * 5), calendar: cal) != "Yesterday")
    }

    @Test("what's new counts the agent's work since then, not your messages, and shows its latest words")
    func summary() throws {
        let items = [reply(1, t0), user(2, t0.addingTimeInterval(10)), tool(3, t0.addingTimeInterval(20)),
                     reply(4, t0.addingTimeInterval(30), "## **Done**, all `green`.\nMore."), reply(5, nil)]
        let s = try #require(UnseenSummary.compute(items, since: t0))
        #expect(s.replies == 1 && s.steps == 1)
        #expect(s.firstItemIndex == 2)
        #expect(s.latest == "Done, all green.")
        #expect(s.counts == "1 reply · 1 step")
    }

    @Test("only your own messages since then isn't news")
    func onlyMine() {
        #expect(UnseenSummary.compute([reply(1, t0), user(2, t0.addingTimeInterval(9))], since: t0) == nil)
    }

    @Test("the divider goes above the first new row of the agent's, inside a run of steps too")
    func dividerRow() {
        let rows: [TranscriptRow] = [.item(reply(1, t0)), .item(user(2, t0.addingTimeInterval(1))),
                                     .activity([tool(3, t0), tool(4, t0.addingTimeInterval(2))]),
                                     .item(reply(5, t0.addingTimeInterval(3)))]
        #expect(UnseenSummary.firstRow(rows, since: t0) == 3)
        #expect(UnseenSummary.firstRow(rows, since: t0.addingTimeInterval(9)) == nil)
    }

    @Test("what's been seen only moves forward, per session, and stays bounded")
    func seenStore() {
        let st = store(); let a = UUID(), b = UUID()
        st.note(a, upTo: t0)
        st.note(a, upTo: t0.addingTimeInterval(-50))
        #expect(st.seen(a) == t0)
        #expect(st.seen(b) == nil)
        for i in 0..<320 { st.note(UUID(), upTo: t0.addingTimeInterval(Double(i + 1))) }
        #expect(st.seen(a) == nil, "the oldest entry should have made way")
    }

    @Test("a chat never seen before reports nothing, and starts from its end")
    func firstOpen() {
        let st = store(); let id = UUID(); var tr = ChatArrivalTracker()
        #expect(tr.tick(id: id, items: [reply(1, t0)], ready: true, active: true, atEnd: true, store: st) == nil)
        #expect(st.seen(id) == t0)
    }

    @Test("opening a chat reports what came in since it was last read, once")
    func arriving() throws {
        let st = store(); let id = UUID(); st.note(id, upTo: t0)
        var tr = ChatArrivalTracker()
        let items = [reply(1, t0), reply(2, t0.addingTimeInterval(5))]
        #expect(tr.tick(id: id, items: items, ready: false, active: true, atEnd: true, store: st) == nil,
                "not before the transcript has been brought up to date")
        let arrived = tr.tick(id: id, items: items, ready: true, active: true, atEnd: true, store: st)
        let found = try #require(arrived)
        #expect(found.since == t0, "the mark stays where the user left off, though what's seen moved on")
        #expect(st.seen(id) == t0.addingTimeInterval(5))
        #expect(tr.tick(id: id, items: items, ready: true, active: true, atEnd: true, store: st) == nil)
    }

    @Test("away in another app or scrolled up, nothing counts as seen; coming back reports it")
    func awayAndBack() throws {
        let st = store(); let id = UUID(); var tr = ChatArrivalTracker()
        let a = [reply(1, t0)], b = a + [reply(2, t0.addingTimeInterval(5))]
        _ = tr.tick(id: id, items: a, ready: true, active: true, atEnd: true, store: st)
        #expect(tr.tick(id: id, items: b, ready: true, active: false, atEnd: true, store: st) == nil)
        #expect(st.seen(id) == t0)
        let returned = tr.tick(id: id, items: b, ready: true, active: true, atEnd: true, store: st)
        let back = try #require(returned)
        #expect(back.replies == 1)
        // In front, but scrolled up reading: a new reply isn't seen yet.
        let c = b + [reply(3, t0.addingTimeInterval(9))]
        _ = tr.tick(id: id, items: c, ready: true, active: true, atEnd: false, store: st)
        #expect(st.seen(id) == t0.addingTimeInterval(5))
    }

    @Test("the floating label shows only when scrolling back, and tells the time at the top edge")
    func scrubLabel() {
        let st = ScrubLabelState()
        let a = t0, b = t0.addingTimeInterval(3_600)
        st.rowsMoved([.init(date: a, minY: -100), .init(date: b, minY: 300)], following: true)
        st.rowsMoved([.init(date: a, minY: -80), .init(date: b, minY: 320)], following: true)
        #expect(st.label == nil, "following the end: no label")
        st.rowsMoved([.init(date: a, minY: -60), .init(date: b, minY: 340)], following: false)
        #expect(st.label == TranscriptTimeline.scrubLabel(a))
        st.rowsMoved([.init(date: a, minY: -300), .init(date: b, minY: 5)], following: false)
        #expect(st.label == TranscriptTimeline.scrubLabel(b))
        st.rowsMoved([.init(date: a, minY: -300), .init(date: b, minY: 5)], following: true)
        #expect(st.label == nil)
    }
}
