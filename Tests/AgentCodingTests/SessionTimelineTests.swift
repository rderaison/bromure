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
}
