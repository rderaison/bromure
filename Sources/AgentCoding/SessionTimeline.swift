import Foundation
import Observation

// MARK: - Where a session's time went
//
// Built from the transcript alone (every agent's items carry timestamps): a
// turn runs from the user's message to the agent's last event before the
// next one; inside it, each tool call runs from the call to its result, and
// the time between tool calls is the model's own (thinking, writing). The
// flamegraph (per session) and the room timeline (per room) draw from this.

struct SessionTimeline: Equatable {
    enum Kind: String, CaseIterable {
        case model, shell, edit, read, web, agent, mcp, other

        var label: String {
            switch self {
            case .model: return NSLocalizedString("Thinking & writing", comment: "timeline kind")
            case .shell: return NSLocalizedString("Shell", comment: "timeline kind")
            case .edit:  return NSLocalizedString("Edits", comment: "timeline kind")
            case .read:  return NSLocalizedString("Reading & search", comment: "timeline kind")
            case .web:   return NSLocalizedString("Web", comment: "timeline kind")
            case .agent: return NSLocalizedString("Sub-agents", comment: "timeline kind")
            case .mcp:   return NSLocalizedString("MCP tools", comment: "timeline kind")
            case .other: return NSLocalizedString("Other tools", comment: "timeline kind")
            }
        }

        static func of(tool name: String) -> Kind {
            let n = name.lowercased()
            if n.hasPrefix("mcp__") || n.contains("__") { return .mcp }
            if ["bash", "shell", "exec", "run_command", "local_shell", "terminal"].contains(where: { n.contains($0) }) { return .shell }
            if ["edit", "write", "patch", "multiedit", "notebookedit", "apply"].contains(where: { n.contains($0) }) { return .edit }
            if ["read", "grep", "glob", "search", "find", "ls", "list", "view"].contains(where: { n.contains($0) }) { return .read }
            if ["web", "fetch", "url", "browse"].contains(where: { n.contains($0) }) { return .web }
            if ["task", "agent", "delegate"].contains(where: { n.contains($0) }) { return .agent }
            return .other
        }
    }

    struct Segment: Equatable, Identifiable {
        let id: Int
        var kind: Kind
        /// The tool's name ("model" for the model's own time).
        var name: String
        /// What it did (the command, the file…), one line.
        var detail: String
        var start: Date
        var end: Date
        /// Stacked lane inside its turn (tool calls running in parallel).
        var lane: Int = 0
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Turn: Equatable, Identifiable {
        let id: Int
        /// The user's message, one line.
        var prompt: String
        var start: Date
        var end: Date
        var segments: [Segment]
        var duration: TimeInterval { end.timeIntervalSince(start) }
        var lanes: Int { (segments.map(\.lane).max() ?? -1) + 1 }
    }

    var turns: [Turn]

    /// Tool calls made (not the model's own time).
    var toolCalls: Int { turns.reduce(0) { $0 + $1.segments.filter { $0.kind != .model }.count } }
    /// Distinct files the agent edited or wrote.
    var filesTouched: Int {
        Set(turns.flatMap { $0.segments.filter { $0.kind == .edit && !$0.detail.isEmpty }.map(\.detail) }).count
    }
    /// The longest stretch it worked with nobody prompting it.
    var longestTurn: Turn? { turns.max { $0.duration < $1.duration } }

    var start: Date? { turns.first?.start }
    var end: Date? { turns.last?.end }
    var busy: TimeInterval { turns.reduce(0) { $0 + $1.duration } }

    /// Time per kind across the whole session (the breakdown under the graph).
    var totals: [(kind: Kind, time: TimeInterval)] {
        var t: [Kind: TimeInterval] = [:]
        for turn in turns { for s in turn.segments { t[s.kind, default: 0] += s.duration } }
        return Kind.allCases.compactMap { k in t[k].map { (k, $0) } }.filter { $0.time > 0.5 }
            .sorted { $0.time > $1.time }
    }

    /// Gaps under this are the agent streaming between two events, not time
    /// worth a bar of its own.
    private static let minGap: TimeInterval = 0.4
    /// Silence longer than this with no tool running is idle, not work.
    static let idleGap: TimeInterval = 5 * 60

    static func build(_ items: [TranscriptItem]) -> SessionTimeline {
        var turns: [Turn] = []
        var current: Turn?
        var cursor: Date?
        var open: [(name: String, detail: String, start: Date)] = []
        var nextID = 0
        /// The prompt of a turn parked on a question to the user: their
        /// answer picks the work up again as a turn of its own — the time
        /// they took (a night, sometimes) is theirs, not the agent's.
        var askedPrompt: String?

        func segment(_ kind: Kind, _ name: String, _ detail: String, _ a: Date, _ b: Date) {
            guard b > a else { return }
            // The model's time between two of its own events is one stretch,
            // not a sliver per streamed message.
            if kind == .model, let last = current?.segments.last, last.kind == .model,
               a.timeIntervalSince(last.end) < 1.0 {
                let i = last.id
                if let k = current?.segments.lastIndex(where: { $0.id == i }) { current?.segments[k].end = b }
                return
            }
            nextID += 1
            current?.segments.append(Segment(id: nextID, kind: kind, name: name, detail: detail, start: a, end: b))
        }
        func advance(to t: Date) {
            guard current != nil else { return }
            // Nothing happening for a long while (no tool running): the agent
            // was idle, not working — waiting on the user, parked. Close the
            // turn there and pick it up again when events resume, so hours
            // of nothing never count as work.
            if let c = cursor, open.isEmpty, t.timeIntervalSince(c) > Self.idleGap, let prompt = current?.prompt {
                closeTurn()
                nextID += 1
                current = Turn(id: nextID, prompt: prompt, start: t, end: t, segments: [])
                cursor = t
                return
            }
            if let c = cursor, t.timeIntervalSince(c) > minGap, open.isEmpty {
                segment(.model, "model", "", c, t)
            }
            if cursor == nil || t > cursor! { cursor = t }
            if let cur = current, t > cur.end { current?.end = t }
        }
        func closeTurn() {
            guard var t = current else { return }
            // A call with no result by the turn's end (interrupted): up to the end.
            for o in open where t.end > o.start {
                nextID += 1
                t.segments.append(Segment(id: nextID, kind: Kind.of(tool: o.name), name: o.name,
                                          detail: o.detail, start: o.start, end: t.end))
            }
            open.removeAll()
            t.segments = Self.laned(t.segments)
            if t.duration > 0 { turns.append(t) }
            current = nil
            cursor = nil
        }

        for item in items {
            guard let ts = item.timestamp else { continue }
            switch item.kind {
            case .userText(let text):
                closeTurn()
                askedPrompt = nil
                nextID += 1
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                current = Turn(id: nextID, prompt: String(line.prefix(140)), start: ts, end: ts, segments: [])
                cursor = ts
            case .toolUse(let name, let summary, _):
                advance(to: ts)
                open.append((name, summary, ts))
            case .question:
                advance(to: ts)
                if let prompt = current?.prompt {
                    closeTurn()
                    askedPrompt = prompt
                }
            case .toolResult(let tool, _, _):
                if current == nil, let prompt = askedPrompt {
                    // The answer to the question: back to work.
                    askedPrompt = nil
                    nextID += 1
                    current = Turn(id: nextID, prompt: prompt, start: ts, end: ts, segments: [])
                    cursor = ts
                    continue
                }
                guard current != nil else { continue }
                // The oldest open call of that tool (results come back in
                // order); an unnamed result takes the oldest of any.
                let i = open.firstIndex { $0.name == tool } ?? (tool == "tool" && !open.isEmpty ? 0 : nil)
                if let i {
                    let o = open.remove(at: i)
                    segment(Kind.of(tool: o.name), o.name, o.detail, o.start, max(ts, o.start))
                }
                if cursor == nil || ts > cursor! { cursor = ts }
                if let cur = current, ts > cur.end { current?.end = ts }
            case .assistantText, .thinking, .todo:
                if current == nil, let prompt = askedPrompt {
                    // Answered without a result we saw: resume here.
                    askedPrompt = nil
                    nextID += 1
                    current = Turn(id: nextID, prompt: prompt, start: ts, end: ts, segments: [])
                    cursor = ts
                    continue
                }
                advance(to: ts)
            case .agentError:
                // The turn ends where the provider refused it.
                advance(to: ts)
                closeTurn()
            }
        }
        closeTurn()
        return SessionTimeline(turns: turns)
    }

    /// First-fit lanes so overlapping segments (parallel tool calls) stack.
    private static func laned(_ segs: [Segment]) -> [Segment] {
        var laneEnds: [Date] = []
        return segs.sorted { $0.start < $1.start }.map { s in
            var s = s
            if let i = laneEnds.firstIndex(where: { $0 <= s.start }) {
                s.lane = i
                laneEnds[i] = s.end
            } else {
                s.lane = laneEnds.count
                laneEnds.append(s.end)
            }
            return s
        }
    }
}

/// The latest timeline of every session a chat has parsed on this Mac (the
/// session on stage, a room's cells — local or through a fat client).
@MainActor
@Observable
final class SessionTimelineStore {
    static let shared = SessionTimelineStore()
    private(set) var timelines: [UUID: SessionTimeline] = [:]
    @ObservationIgnored private var itemCounts: [UUID: Int] = [:]

    func update(_ session: UUID, items: [TranscriptItem]) {
        // Rebuilt only when the transcript grew.
        guard itemCounts[session] != items.count else { return }
        itemCounts[session] = items.count
        let t = SessionTimeline.build(items)
        if timelines[session] != t { timelines[session] = t }
    }

    /// The live one (a chat showing it), else this Mac's transcript index
    /// (a session no chat has open — a sleeping room member).
    func timeline(_ session: UUID) -> SessionTimeline? {
        #if os(macOS)
        return timelines[session] ?? TranscriptSearchIndex.shared.timeline(session)
        #else
        return timelines[session]
        #endif
    }
}
