import Foundation

// The plan-stream protocol (v1, NDJSON over vsock 5832): what the guest's
// planning driver sends and what the host sends back. Foundation only:
// shared by the macOS bridge (PlanEventBridge, on the VZ socket device) and
// the Linux daemon's.

// MARK: - Plan-stream events (guest → host)

/// One decoded event from the plan-stream protocol (v1, NDJSON over vsock
/// port 5832). The guest planning driver pushes these as the agent works;
/// unlike the task-board MCP this is event-push, not request/response.
enum PlanEvent: Equatable {
    /// First line after every (re)connect — names the worktree branch this
    /// connection belongs to and which agent tool is driving.
    case hello(branch: String, tool: String)
    case state(String)
    /// A COMPLETED message (no deltas in v1), attributed to a role.
    case text(role: String, text: String)
    case thinking(String)
    case tool(name: String, summary: String)
    case toolResult(name: String, ok: Bool, summary: String)
    /// The agent asking the user — the questions payload has exactly the
    /// AskUserQuestion shape, so it reuses the transcript's question model
    /// (and therefore its rendering) instead of a parallel type.
    case question(qid: String, questions: [TranscriptQuestion])
    /// The question was resolved elsewhere (or cancelled) — drop the card.
    case questionResolved(qid: String)
    /// TERMINAL: session over.
    case result(ok: Bool, error: String?)
    /// TERMINAL: the driver or agent died.
    case fatal(String)

    /// Decode one NDJSON line. Tolerant by protocol contract: unknown
    /// events and malformed lines return nil (the host must survive a
    /// newer guest), and missing fields take safe defaults rather than
    /// failing the whole line.
    static func parse(line: Data) -> PlanEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ev = obj["ev"] as? String else { return nil }
        switch ev {
        case "hello":
            return .hello(branch: obj["branch"] as? String ?? "",
                          tool: obj["tool"] as? String ?? "")
        case "state":
            return .state(obj["state"] as? String ?? "")
        case "text":
            return .text(role: obj["role"] as? String ?? "assistant",
                         text: obj["text"] as? String ?? "")
        case "thinking":
            return .thinking(obj["text"] as? String ?? "")
        case "tool":
            return .tool(name: obj["name"] as? String ?? "",
                         summary: obj["summary"] as? String ?? "")
        case "tool_result":
            return .toolResult(name: obj["name"] as? String ?? "",
                               ok: obj["ok"] as? Bool ?? true,
                               summary: obj["summary"] as? String ?? "")
        case "question":
            // The event object itself carries the "questions" array, which
            // is exactly what TranscriptQuestion.parse expects.
            return .question(qid: obj["qid"] as? String ?? "",
                             questions: TranscriptQuestion.parse(obj))
        case "question_resolved":
            return .questionResolved(qid: obj["qid"] as? String ?? "")
        case "result":
            // ok's default follows the error field: a result that lost its
            // ok flag but carries an error string is still a failure.
            let error = obj["error"] as? String
            return .result(ok: obj["ok"] as? Bool ?? (error == nil), error: error)
        case "fatal":
            return .fatal(obj["error"] as? String ?? "")
        default:
            return nil
        }
    }
}

// MARK: - Plan-stream commands (host → guest)

/// A command the host sends back on the plan stream. Encoded as
/// protocol-shape NDJSON — one JSON object per line.
enum PlanCommand {
    /// A new user turn.
    case user(String)
    /// Answers a "question" event. `labels` are the chosen option labels;
    /// `other` carries free-form text when the user typed their own answer.
    case answer(qid: String, answers: [(question: String, labels: [String], other: String?)])
    case interrupt
    /// Tear the session down; the driver replies with result then exits.
    case end

    /// One wire-ready NDJSON line, trailing newline included.
    func jsonLine() -> Data {
        let obj: [String: Any]
        switch self {
        case .user(let text):
            obj = ["cmd": "user", "text": text]
        case .answer(let qid, let answers):
            obj = ["cmd": "answer", "qid": qid,
                   "answers": answers.map { a -> [String: Any] in
                       ["question": a.question,
                        "labels": a.labels,
                        // Explicit null, not an absent key — the wire shape
                        // in the frozen protocol shows "other":null.
                        "other": (a.other as Any?) ?? NSNull()]
                   }]
        case .interrupt:
            obj = ["cmd": "interrupt"]
        case .end:
            obj = ["cmd": "end"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(0x0A)
        return data
    }
}
