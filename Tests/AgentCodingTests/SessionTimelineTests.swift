import Foundation
import Testing
@testable import bromure_ac

@Suite("Session timeline")
struct SessionTimelineTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func item(_ id: Int, _ kind: TranscriptItem.Kind, _ s: Double) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, timestamp: at(s))
    }

    @Test("a turn runs from the message to the agent's last event; tools from call to result; model time between")
    func turnsToolsAndModel() {
        let items = [
            item(1, .userText("fix the build\nplease"), 0),
            item(2, .thinking("…"), 2),
            item(3, .toolUse(name: "Bash", summary: "swift build", detail: "{}"), 5),
            item(4, .toolResult(tool: "Bash", content: "ok", isError: false), 35),
            item(5, .assistantText("done"), 40),
            item(6, .userText("thanks"), 500),   // idle gap: not part of turn 1
            item(7, .assistantText("np"), 503),
        ]
        let tl = SessionTimeline.build(items)
        #expect(tl.turns.count == 2)
        let t = tl.turns[0]
        #expect(t.prompt == "fix the build")
        #expect(t.duration == 40)
        let bash = t.segments.first { $0.kind == .shell }
        #expect(bash?.duration == 30)
        #expect(bash?.detail == "swift build")
        // Model time: 0→2, 2→5 (before the call) and 35→40 (after it).
        let model = t.segments.filter { $0.kind == .model }.reduce(0) { $0 + $1.duration }
        #expect(model == 10)
        #expect(tl.busy == 43)
        #expect(tl.totals.first?.kind == .shell)
    }

    @Test("hours of silence inside a turn are idle, not work — unless a tool is running")
    func idleIsNotWork() {
        let items = [
            item(1, .userText("go"), 0),
            item(2, .assistantText("working"), 60),
            item(3, .assistantText("back"), 60 + 8 * 3600),   // overnight, nothing running
            item(4, .toolUse(name: "Bash", summary: "make", detail: "{}"), 60 + 8 * 3600 + 10),
            item(5, .toolResult(tool: "Bash", content: "", isError: false), 60 + 8 * 3600 + 10 + 3600),  // an hour-long build
        ]
        let tl = SessionTimeline.build(items)
        #expect(tl.turns.count == 2)
        #expect(tl.busy == 60 + 10 + 3600)
        #expect(tl.turns[1].prompt == "go")
    }

    @Test("a question to the user parks the turn: the night they took to answer isn't the agent's work")
    func questionParksTheTurn() {
        let q = TranscriptQuestion(question: "Which way?", header: "Way", multiSelect: false, options: [])
        let items = [
            item(1, .userText("do it"), 0),
            item(2, .toolUse(name: "Bash", summary: "make", detail: "{}"), 10),
            item(3, .toolResult(tool: "Bash", content: "", isError: false), 70),
            item(4, .question(q), 100),
            item(5, .question(q), 100),                        // a two-question round
            item(6, .toolResult(tool: "AskUserQuestion", content: "A", isError: false), 100 + 10 * 3600),
            item(7, .assistantText("on it"), 100 + 10 * 3600 + 5),
            item(8, .toolUse(name: "Bash", summary: "test", detail: "{}"), 100 + 10 * 3600 + 6),
            item(9, .toolResult(tool: "Bash", content: "", isError: false), 100 + 10 * 3600 + 66),
        ]
        let tl = SessionTimeline.build(items)
        #expect(tl.turns.count == 2)
        #expect(tl.turns.map(\.duration) == [100, 66])
        #expect(tl.turns[1].prompt == "do it")
        #expect(tl.busy == 166)
        #expect(tl.longestTurn?.duration == 100)
    }

    @Test("a result for a tool with no open call doesn't close another tool's call")
    func strayResultKeepsOtherCalls() {
        let items = [
            item(1, .userText("go"), 0),
            item(2, .toolUse(name: "Bash", summary: "long", detail: "{}"), 1),
            item(3, .toolResult(tool: "Monitor", content: "", isError: false), 5),
            item(4, .toolResult(tool: "Bash", content: "", isError: false), 61),
        ]
        let tl = SessionTimeline.build(items)
        #expect(tl.turns.first?.segments.first { $0.kind == .shell }?.duration == 60)
    }

    @Test("calls running in parallel stack into lanes")
    func parallelLanes() {
        let items = [
            item(1, .userText("look around"), 0),
            item(2, .toolUse(name: "Read", summary: "a.swift", detail: "{}"), 1),
            item(3, .toolUse(name: "Grep", summary: "TODO", detail: "{}"), 1),
            item(4, .toolResult(tool: "Read", content: "", isError: false), 3),
            item(5, .toolResult(tool: "Grep", content: "", isError: false), 6),
        ]
        let t = SessionTimeline.build(items).turns[0]
        let tools = t.segments.filter { $0.kind != .model }
        #expect(tools.count == 2)
        #expect(Set(tools.map(\.lane)) == [0, 1])
        #expect(t.lanes == 2)
    }

    @Test("a call with no result (interrupted) runs to the turn's end; untimed items are skipped")
    func interruptedAndUntimed() {
        var items = [
            item(1, .userText("go"), 0),
            item(2, .toolUse(name: "Bash", summary: "sleep 100", detail: "{}"), 1),
            item(3, .assistantText("stopping"), 9),
        ]
        items.append(TranscriptItem(id: 4, kind: .assistantText("no time"), timestamp: nil))
        let t = SessionTimeline.build(items).turns[0]
        #expect(t.duration == 9)
        #expect(t.segments.first { $0.kind == .shell }?.end == at(9))
        #expect(SessionTimeline.Kind.of(tool: "mcp__display__show_chart") == .mcp)
    }

    /// A day of work: one 30-minute turn per hour, for 48 hours.
    private func twoDays() -> SessionTimeline {
        var items: [TranscriptItem] = []
        for h in 0..<48 {
            let s = Double(h) * 3600
            items.append(item(items.count, .userText("task \(h)"), s))
            // An event every 200 s (under the idle gap) for 30 minutes.
            for k in 1...9 { items.append(item(items.count, .assistantText("step"), s + Double(k) * 200)) }
        }
        return SessionTimeline.build(items)
    }

    @Test("a chat holding only the transcript's end counts the index's earlier turns too")
    func liveWindowJoinsTheIndex() {
        let index = twoDays()
        #expect(index.busy == 48 * 1800)
        // The chat downloaded the last few minutes: it starts mid-turn (the
        // prompt cut off), then one whole turn.
        let lastStart = 47.0 * 3600
        let live = SessionTimeline.build([item(0, .assistantText("step"), lastStart - 3600 + 1600),
                                          item(1, .userText("task 47"), lastStart)]
            + (1...9).map { item(1 + $0, .assistantText("step"), lastStart + Double($0) * 200) })
        #expect(live.busy == 1800)
        let joined = SessionTimeline.live(live, startingMidFile: true, index: index)
        #expect(joined.busy == 48 * 1800)
        #expect(joined.turns.count == 48)
        // No bar shares an id with another.
        let ids = joined.turns.map(\.id) + joined.turns.flatMap { $0.segments.map(\.id) }
        #expect(Set(joined.turns.map(\.id)).count == joined.turns.count)
        #expect(Set(joined.turns.flatMap { $0.segments.map(\.id) }).count == ids.count - joined.turns.count)
    }

    @Test("a chat holding the whole transcript is the timeline, as is one the index doesn't know yet")
    func liveWholeOrUnknown() {
        let index = twoDays()
        let live = SessionTimeline.build([item(0, .userText("x"), 0), item(1, .assistantText("y"), 60)])
        #expect(SessionTimeline.live(live, startingMidFile: false, index: index) == live)
        #expect(SessionTimeline.live(live, startingMidFile: true, index: nil) == live)
        let empty = SessionTimeline(turns: [])
        #expect(SessionTimeline.live(empty, startingMidFile: true, index: index) == empty)
    }

    @Test("after a /clear in the chat's window, the index's old conversation isn't added back")
    func clearInTheWindow() {
        // The index has the two days before the clear, not yet the turn after.
        let index = twoDays()
        let after = 48.0 * 3600 + 600
        let live = SessionTimeline.build([item(0, .userText("fresh start"), after),
                                          item(1, .assistantText("ok"), after + 120)])
        #expect(SessionTimeline.live(live, startingMidFile: true, index: index) == live)
        // Once the index has read the clear it starts over: its turns are
        // the new conversation's, and the join counts the ones the chat lacks.
        let restarted = SessionTimeline.build([item(0, .userText("fresh start"), after - 7200),
                                               item(1, .assistantText("ok"), after - 7000),
                                               item(2, .userText("next"), after),
                                               item(3, .assistantText("ok"), after + 120)])
        let joined = SessionTimeline.live(live, startingMidFile: true, index: restarted)
        #expect(joined.turns.count == 2)
        #expect(joined.busy == 200 + 120)
    }

    @MainActor @Test("the store joins a mid-file chat with the index, and forgets that when the chat holds it all")
    func storeTracksMidFile() {
        let store = SessionTimelineStore()
        let id = UUID()
        let items = [item(0, .userText("x"), 0), item(1, .assistantText("y"), 60)]
        store.update(id, items: items, startingMidFile: true)
        #expect(store.startsMidFile.contains(id))
        // Same items, now loaded from the start ("load earlier"): the flag follows.
        store.update(id, items: items, startingMidFile: false)
        #expect(!store.startsMidFile.contains(id))
    }
}
