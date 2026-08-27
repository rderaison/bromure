import Foundation

// Live token streaming for local inference (external engines).
//
// The repair proxy historically forced `stream: false` upstream, ran the
// repair pipeline on the complete message, and re-emitted the whole SSE
// stream in one burst — correct, but on a slow local model the agent sits
// silent for the entire generation. These two types let the proxy stream
// text deltas to the guest AS THEY ARRIVE while preserving every repair
// behavior:
//
//  - `ChatStreamClient` drives the upstream `/v1/chat/completions` call with
//    `stream: true`, feeds each text snapshot to the caller, and assembles
//    the exact non-streaming `chat.completion` object the buffered pipeline
//    would have received — so repair/continuation/tracing see no difference.
//  - `LocalStreamEmitter` writes the guest-wire SSE incrementally. It holds
//    back a small tail (and stops releasing at a leaked-tool-call marker) so
//    ToolCallRepair can still strip a leaked call the guest never saw; the
//    repaired remainder + tool blocks + terminal events are emitted at
//    finish. A stuck-preamble continuation replaces the turn's outcome, so
//    its text is appended as a fresh paragraph after the released preamble.

/// Incremental guest-wire SSE writer for one streamed local-inference turn.
final class LocalStreamEmitter {
    private let fd: Int32
    private let wire: Wire
    private let model: String
    private(set) var headerSent = false
    private var closed = false

    /// Full upstream text accumulated so far, and how much of it was released.
    private var raw = ""
    private var releasedCount = 0
    /// Tail kept unreleased so an end-of-text leaked tool call can still be
    /// stripped before the guest sees it.
    private let holdback = 320
    /// A leaked call can also start mid-text; release stops at the earliest
    /// marker. Deliberately narrow — plain ``` fences are everyday markdown,
    /// while these forms are how local models actually leak calls.
    private static let leakMarkers = [
        "<function", "<tool_call", "<invoke", "```json", "```xml", "```tool",
    ]

    private var seq = 0                 // responses-wire sequence number
    private let turnID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()

    init(fd: Int32, wire: Wire, model: String) {
        self.fd = fd
        self.wire = wire
        self.model = model
    }

    // MARK: Low-level writes

    private func write(_ s: String) {
        guard !closed else { return }
        var data = Data(s.utf8)
        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var base = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n > 0 { base += n; remaining -= n }
                else if n < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
        if !ok { closed = true }
    }

    private func event(_ type: String?, _ payload: [String: Any]) {
        let d = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        write(type.map { "event: \($0)\ndata: \(d)\n\n" } ?? "data: \(d)\n\n")
    }

    private func responsesEvent(_ type: String, _ payload: [String: Any]) {
        var p = payload; p["type"] = type; p["sequence_number"] = seq; seq += 1
        event(type, p)
    }

    private func chatChunk(_ delta: [String: Any], _ finish: Any) {
        event(nil, ["id": "chatcmpl-\(turnID)", "object": "chat.completion.chunk",
                    "created": 0, "model": model,
                    "choices": [["index": 0, "delta": delta, "finish_reason": finish]]])
    }

    // MARK: Stream lifecycle

    /// HTTP header + the wire's opening events. Called lazily on the first
    /// released text so a pre-stream upstream failure can still fall back to
    /// the buffered error path.
    private func begin() {
        guard !headerSent else { return }
        headerSent = true
        write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
              + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
        switch wire {
        case .messages:
            event("message_start", ["type": "message_start", "message": [
                "type": "message", "id": "msg_bromure-\(turnID)", "role": "assistant",
                "model": model, "content": [],
                "stop_reason": NSNull(), "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0]]])
            event("content_block_start", ["type": "content_block_start", "index": 0,
                "content_block": ["type": "text", "text": ""]])
        case .chat:
            chatChunk(["role": "assistant"], NSNull())
        case .responses:
            let envelope: [String: Any] = ["id": "resp_bromure-\(turnID)",
                "object": "response", "model": model, "status": "in_progress",
                "output": [], "usage": ["input_tokens": 0, "output_tokens": 0]]
            responsesEvent("response.created", ["response": envelope])
            responsesEvent("response.in_progress", ["response": envelope])
            responsesEvent("response.output_item.added", ["output_index": 0,
                "item": ["type": "message", "id": "item_0", "role": "assistant",
                         "status": "in_progress", "content": []]])
            responsesEvent("response.content_part.added", ["item_id": "item_0",
                "output_index": 0, "content_index": 0,
                "part": ["type": "output_text", "text": "", "annotations": []]])
        }
    }

    /// New accumulated upstream text; releases whatever the holdback allows.
    func textDelta(_ full: String) {
        raw = full
        var limit = max(0, full.count - holdback)
        for marker in Self.leakMarkers {
            if let r = full.range(of: marker) {
                limit = min(limit, full.distance(from: full.startIndex, to: r.lowerBound))
            }
        }
        guard limit > releasedCount else { return }
        release(String(full.prefix(limit).dropFirst(releasedCount)))
        releasedCount = limit
    }

    private func release(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        begin()
        switch wire {
        case .messages:
            event("content_block_delta", ["type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": chunk]])
        case .chat:
            chatChunk(["content": chunk], NSNull())
        case .responses:
            responsesEvent("response.output_text.delta", ["item_id": "item_0",
                "output_index": 0, "content_index": 0, "delta": chunk])
        }
    }

    /// Close the turn with the repaired final wire message. `continued` marks
    /// a stuck-preamble continuation: its message REPLACES the turn's outcome,
    /// so its text appends after the (fully released) preamble instead of
    /// being prefix-matched against it.
    func finish(final: [String: Any], continued: Bool) {
        begin()
        let finalText = Self.assistantText(of: final, wire: wire)
        let released = String(raw.prefix(releasedCount))
        var textOut = released
        if continued {
            release(String(raw.dropFirst(releasedCount)))   // the full preamble
            textOut = raw
            if !finalText.isEmpty {
                let sep = raw.isEmpty ? "" : "\n\n"
                release(sep + finalText)
                textOut += sep + finalText
            }
        } else if finalText.hasPrefix(released) {
            release(String(finalText.dropFirst(released.count)))
            textOut = finalText
        }
        // else: the repair rewrote text the guest already saw (a mid-text
        // leak slipped past the markers) — stop the text here; the tool
        // blocks below still carry the action.

        switch wire {
        case .messages:
            event("content_block_stop", ["type": "content_block_stop", "index": 0])
            let blocks = (final["content"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "tool_use" }
            for (i, b) in blocks.enumerated() {
                let idx = i + 1
                event("content_block_start", ["type": "content_block_start", "index": idx,
                    "content_block": ["type": "tool_use", "id": b["id"] as? String ?? "",
                                      "name": b["name"] as? String ?? "", "input": [:]]])
                let pj = (try? JSONSerialization.data(withJSONObject: b["input"] ?? [:]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                event("content_block_delta", ["type": "content_block_delta", "index": idx,
                    "delta": ["type": "input_json_delta", "partial_json": pj]])
                event("content_block_stop", ["type": "content_block_stop", "index": idx])
            }
            let usage = final["usage"] as? [String: Any] ?? ["input_tokens": 0, "output_tokens": 0]
            event("message_delta", ["type": "message_delta",
                "delta": ["stop_reason": final["stop_reason"] as? String ?? "end_turn",
                          "stop_sequence": NSNull()],
                "usage": usage])
            event("message_stop", ["type": "message_stop"])
        case .chat:
            let choice = (final["choices"] as? [[String: Any]])?.first ?? [:]
            let message = choice["message"] as? [String: Any] ?? [:]
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for (i, tc) in toolCalls.enumerated() {
                    let fn = tc["function"] as? [String: Any] ?? [:]
                    chatChunk(["tool_calls": [["index": i, "id": tc["id"] ?? "", "type": "function",
                        "function": ["name": fn["name"] ?? "", "arguments": ""]]]], NSNull())
                    chatChunk(["tool_calls": [["index": i,
                        "function": ["arguments": fn["arguments"] ?? "{}"]]]], NSNull())
                }
                chatChunk([:], "tool_calls")
            } else {
                chatChunk([:], choice["finish_reason"] as? String ?? "stop")
            }
            write("data: [DONE]\n\n")
        case .responses:
            responsesEvent("response.output_text.done", ["item_id": "item_0",
                "output_index": 0, "content_index": 0, "text": textOut])
            responsesEvent("response.content_part.done", ["item_id": "item_0",
                "output_index": 0, "content_index": 0,
                "part": ["type": "output_text", "text": textOut, "annotations": []]])
            let messageItem: [String: Any] = ["type": "message", "id": "item_0",
                "role": "assistant", "status": "completed",
                "content": [["type": "output_text", "text": textOut, "annotations": []]]]
            responsesEvent("response.output_item.done", ["output_index": 0, "item": messageItem])
            let calls = (final["output"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "function_call" }
            for (i, item) in calls.enumerated() {
                let idx = i + 1
                let itemID = item["id"] as? String ?? "fc_\(idx)"
                responsesEvent("response.output_item.added", ["output_index": idx, "item": item])
                let args = item["arguments"] as? String ?? "{}"
                responsesEvent("response.function_call_arguments.delta",
                               ["item_id": itemID, "output_index": idx, "delta": args])
                responsesEvent("response.function_call_arguments.done",
                               ["item_id": itemID, "output_index": idx, "arguments": args])
                responsesEvent("response.output_item.done", ["output_index": idx, "item": item])
            }
            var done = final
            done["status"] = "completed"
            done["output"] = [messageItem] + calls
            var u = (done["usage"] as? [String: Any]) ?? ["input_tokens": 0, "output_tokens": 0]
            if u["total_tokens"] == nil {
                u["total_tokens"] = ((u["input_tokens"] as? Int) ?? 0) + ((u["output_tokens"] as? Int) ?? 0)
            }
            done["usage"] = u
            responsesEvent("response.completed", ["response": done])
        }
    }

    /// Assistant text of a complete wire message (post-repair).
    private static func assistantText(of message: [String: Any], wire: Wire) -> String {
        switch wire {
        case .messages:
            return (message["content"] as? [[String: Any]] ?? [])
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined()
        case .chat:
            let m = (message["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return m?["content"] as? String ?? ""
        case .responses:
            return (message["output"] as? [[String: Any]] ?? []).flatMap { item -> [String] in
                guard (item["type"] as? String) == "message" else { return [] }
                return (item["content"] as? [[String: Any]] ?? [])
                    .compactMap { ($0["type"] as? String) == "output_text" ? $0["text"] as? String : nil }
            }.joined()
        }
    }
}

/// Streaming upstream `/v1/chat/completions` client: drives the request with
/// `stream: true`, feeds each accumulated-text snapshot to `onText`, and
/// assembles the exact non-streaming `chat.completion` object the buffered
/// pipeline expects.
enum ChatStreamClient {
    private final class Delegate: NSObject, URLSessionDataDelegate {
        let onChunk: (Data) -> Void
        let done = DispatchSemaphore(value: 0)
        var status = 0
        init(onChunk: @escaping (Data) -> Void) { self.onChunk = onChunk }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            onChunk(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            done.signal()
        }
    }

    /// Blocking send. Returns the assembled chat.completion (nil on transport
    /// failure / non-200 / unparseable stream) plus the HTTP status and the
    /// raw bytes received (error bodies ride the same channel).
    static func send(chatBody: [String: Any], config: ExternalEngine.Config,
                     onText: @escaping (String) -> Void) -> (chat: [String: Any]?, status: Int, raw: Data) {
        var body = chatBody
        body["stream"] = true
        // The final usage frame; servers without support just omit it.
        body["stream_options"] = ["include_usage": true]

        var req = URLRequest(url: config.base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = config.apiKey, !k.isEmpty {
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        // Assembly state, mutated only from the session's delegate queue.
        var text = ""
        var toolCalls: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?
        var usage: [String: Any]?
        var meta: (id: String, model: String, created: Int)?
        var pending = ""
        var raw = Data()

        let delegate = Delegate { data in
            raw.append(data)
            pending += String(decoding: data, as: UTF8.self)
            // SSE frames are newline-delimited `data: {...}` lines.
            while let nl = pending.range(of: "\n") {
                let line = String(pending[..<nl.lowerBound]).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(..<nl.upperBound)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", !payload.isEmpty,
                      let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
                else { continue }
                if meta == nil {
                    meta = (obj["id"] as? String ?? "chatcmpl-x",
                            obj["model"] as? String ?? "",
                            obj["created"] as? Int ?? 0)
                }
                if let u = obj["usage"] as? [String: Any] { usage = u }
                guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                if let fr = choice["finish_reason"] as? String { finishReason = fr }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                if let c = delta["content"] as? String, !c.isEmpty {
                    text += c
                    onText(text)
                }
                for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let idx = tc["index"] as? Int ?? 0
                    var cur = toolCalls[idx] ?? (id: "call_\(idx)", name: "", args: "")
                    if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { cur.name = n }
                        if let a = fn["arguments"] as? String { cur.args += a }
                    }
                    toolCalls[idx] = cur
                }
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: req).resume()
        delegate.done.wait()

        guard delegate.status == 200, meta != nil || !text.isEmpty || !toolCalls.isEmpty else {
            return (nil, delegate.status, raw)
        }
        var message: [String: Any] = ["role": "assistant",
                                      "content": text.isEmpty ? NSNull() : text]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.sorted { $0.key < $1.key }.map { _, tc in
                ["id": tc.id, "type": "function",
                 "function": ["name": tc.name, "arguments": tc.args.isEmpty ? "{}" : tc.args]]
            }
        }
        let chat: [String: Any] = [
            "id": meta?.id ?? "chatcmpl-x", "object": "chat.completion",
            "created": meta?.created ?? 0, "model": meta?.model ?? "",
            "choices": [["index": 0, "message": message,
                         "finish_reason": finishReason ?? (toolCalls.isEmpty ? "stop" : "tool_calls")]],
            "usage": usage ?? ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
        ]
        return (chat, 200, raw)
    }
}
