import Foundation

// The host-side state for streamed planning sessions (plan-stream v1).
// PlanEventBridge delivers decoded guest events here; the hub renders them
// into the same TranscriptItem vocabulary the plan window already draws, so
// the window needs no second rendering path. One session per (profile,
// branch); sessions survive window close/reopen and feed the fat client
// through a seq cursor.

/// One live (or just-ended) streamed planning session.
@MainActor
final class PlanStreamSession {
    let profileID: Profile.ID
    let branch: String
    /// Session identity for the fat-client relay: a Plan retry can reuse the
    /// branch (minute-resolution slugs), and the client must detect that its
    /// cached items belong to a dead session rather than splice transcripts.
    let token = UUID().uuidString
    private(set) var tool: String = ""
    /// Rendered event log — TranscriptItem ids are positions, so `items.count`
    /// doubles as the fat client's monotonic cursor.
    private(set) var items: [TranscriptItem] = []
    /// The unanswered structured question round, if any (qid the driver
    /// expects back in the answer command).
    private(set) var pendingQID: String?
    /// Set on result/fatal — the session is over; `hasLiveStream` turns false.
    private(set) var ended: (ok: Bool, error: String?)?

    init(profileID: Profile.ID, branch: String) {
        self.profileID = profileID
        self.branch = branch
    }

    private func append(_ kind: TranscriptItem.Kind) {
        items.append(TranscriptItem(id: items.count, kind: kind, timestamp: Date()))
    }

    /// Fold one guest event into the rendered log. Returns false for events
    /// that change nothing visible (heartbeat states).
    @discardableResult
    func apply(_ event: PlanEvent) -> Bool {
        if ended != nil { return false }   // protocol rule: ignore after terminal
        switch event {
        case .hello(_, let tool):
            self.tool = tool
            return false
        case .state:
            return false
        case .text(let role, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            append(role == "user" ? .userText(t) : .assistantText(t))
        case .thinking(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            append(.thinking(t))
        case .tool(let name, let summary):
            append(.toolUse(name: name, summary: summary, detail: ""))
        case .toolResult(let name, let ok, let summary):
            append(.toolResult(tool: name, content: summary, isError: !ok))
        case .question(let qid, let questions):
            pendingQID = qid
            // One item per question — the window's trailing-run batch logic
            // (openBatch) picks them up exactly like transcript questions.
            for q in questions { append(.question(q)) }
        case .questionResolved(let qid):
            if pendingQID == qid { pendingQID = nil }
            return false
        case .result(let ok, let error):
            ended = (ok, error)
            pendingQID = nil
        case .fatal(let error):
            ended = (false, error)
            pendingQID = nil
            append(.assistantText(String(format: NSLocalizedString(
                "The planning session failed: %@", comment: "plan stream"), error)))
        }
        return true
    }

    /// An answer for `qid` was successfully forwarded to the driver —
    /// consume the pending round so a second submit reports "no pending
    /// question" instead of a fake success the driver would discard.
    func markAnswered(qid: String) {
        if pendingQID == qid { pendingQID = nil }
    }
}

/// Registry of streamed planning sessions, keyed by (profile, branch).
/// `ACAppDelegate` feeds it from the per-workspace `PlanEventBridge`s and
/// consults it for the plan windows, the engine's lifecycle hooks, and the
/// fat-client relay routes.
@MainActor
final class PlanStreamHub {
    private var sessions: [String: PlanStreamSession] = [:]
    /// Fired after every visible change (and on session start/end) so open
    /// plan windows can refresh immediately instead of on the next poll.
    var onChanged: ((_ profileID: Profile.ID, _ branch: String) -> Void)?
    /// Fired once per session on its terminal event — the engine's
    /// completion/abort hook.
    var onEnded: ((_ profileID: Profile.ID, _ branch: String,
                   _ ok: Bool, _ error: String?) -> Void)?
    /// Fired on hello — the engine cancels the tab-based plan watchdog.
    var onStarted: ((_ profileID: Profile.ID, _ branch: String) -> Void)?

    private func key(_ profileID: Profile.ID, _ branch: String) -> String {
        profileID.uuidString + "|" + branch
    }

    func session(profileID: Profile.ID, branch: String) -> PlanStreamSession? {
        sessions[key(profileID, branch)]
    }

    /// The session is streaming (started, not yet ended) — the plan
    /// watchdog treats this like "the tab exists and the agent is running".
    func isLive(profileID: Profile.ID, branch: String) -> Bool {
        guard let s = sessions[key(profileID, branch)] else { return false }
        return s.ended == nil
    }

    func handle(profileID: Profile.ID, branch: String, event: PlanEvent) {
        let k = key(profileID, branch)
        var isHello = false
        if case .hello = event { isHello = true }
        let session: PlanStreamSession
        if let existing = sessions[k], existing.ended == nil || !isHello {
            session = existing
        } else {
            // First contact — or a fresh hello for a branch whose previous
            // session ENDED: slugs have minute resolution, so a Plan retry
            // can reuse the branch key. Only a hello replaces the record;
            // post-terminal stragglers from the dead driver still hit the
            // ended session and are ignored per the protocol rule. A
            // mid-session reconnect hello reuses the live record (ended nil).
            session = PlanStreamSession(profileID: profileID, branch: branch)
            sessions[k] = session
        }
        if isHello, session.ended == nil {
            onStarted?(profileID, branch)
        }
        let changed = session.apply(event)
        if let end = session.ended, isTerminal(event) {
            onEnded?(profileID, branch, end.ok, end.error)
        }
        if changed { onChanged?(profileID, branch) }
    }

    private func isTerminal(_ event: PlanEvent) -> Bool {
        switch event {
        case .result, .fatal: return true
        default: return false
        }
    }

    /// Drop a session's record (workspace teardown; a finished session's
    /// window keeps its own copy of the items until closed).
    func removeSessions(profileID: Profile.ID) {
        sessions = sessions.filter { $0.value.profileID != profileID }
    }
}

// MARK: - Wire codec (fat-client relay)

/// TranscriptItem ⇄ JSON dicts for the `/tasks/{id}/plan-events` route —
/// the fat client re-renders the same items the local window shows.
enum TranscriptItemWire {
    static func encode(_ item: TranscriptItem) -> [String: Any] {
        var d: [String: Any] = ["id": item.id]
        if let t = item.timestamp { d["ts"] = t.timeIntervalSince1970 }
        switch item.kind {
        case .userText(let s):       d["k"] = "user";      d["text"] = s
        case .assistantText(let s):  d["k"] = "assistant"; d["text"] = s
        case .thinking(let s):       d["k"] = "thinking";  d["text"] = s
        case .toolUse(let name, let summary, let detail):
            d["k"] = "tool"; d["name"] = name; d["summary"] = summary
            if !detail.isEmpty { d["detail"] = detail }
        case .toolResult(let tool, let content, let isError):
            d["k"] = "tool_result"; d["name"] = tool
            d["content"] = content; d["error"] = isError
        case .question(let q):
            d["k"] = "question"
            d["question"] = ["question": q.question, "header": q.header,
                             "multiSelect": q.multiSelect,
                             "options": q.options.map {
                                 ["label": $0.label, "description": $0.description]
                             }] as [String: Any]
        }
        return d
    }

    static func decode(_ d: [String: Any]) -> TranscriptItem? {
        guard let id = d["id"] as? Int, let k = d["k"] as? String else { return nil }
        let ts = (d["ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let kind: TranscriptItem.Kind
        switch k {
        case "user":      kind = .userText(d["text"] as? String ?? "")
        case "assistant": kind = .assistantText(d["text"] as? String ?? "")
        case "thinking":  kind = .thinking(d["text"] as? String ?? "")
        case "tool":
            kind = .toolUse(name: d["name"] as? String ?? "tool",
                            summary: d["summary"] as? String ?? "",
                            detail: d["detail"] as? String ?? "")
        case "tool_result":
            kind = .toolResult(tool: d["name"] as? String ?? "tool",
                               content: d["content"] as? String ?? "",
                               isError: d["error"] as? Bool ?? false)
        case "question":
            guard let qd = d["question"] as? [String: Any] else { return nil }
            // TranscriptQuestion.parse takes the tool-input shape (an array
            // under "questions") — reuse it so option parsing can't drift.
            guard let q = TranscriptQuestion.parse(["questions": [qd]]).first
            else { return nil }
            kind = .question(q)
        default:
            return nil
        }
        return TranscriptItem(id: id, kind: kind, timestamp: ts)
    }
}
