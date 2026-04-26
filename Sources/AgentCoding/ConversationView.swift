import AppKit
import SwiftUI

/// Normalised view of one AI chat exchange — what the request body
/// represents (the agent's full conversation history sent on this
/// turn) plus the assistant's reply parsed from the response body.
///
/// We keep this format provider-agnostic so the UI doesn't have to
/// special-case Anthropic vs. OpenAI vs. Google: the parser flattens
/// each provider's quirks (system prompt placement, tool_use blocks,
/// SSE streaming, etc.) into the same shape.
struct Conversation {
    var provider: Provider
    var model: String?
    var systemPrompt: String?
    var messages: [Message]
    var inputTokens: Int?
    var outputTokens: Int?
    var raw: Bool   // true when we built this from a non-canonical body shape

    enum Provider: String { case anthropic, openai, gemini, cohere, unknown }

    struct Message: Identifiable {
        let id = UUID()
        var role: Role
        var content: [Block]

        enum Role: String { case system, user, assistant, tool }
    }

    enum Block {
        case text(String)
        case toolUse(name: String, input: String)
        case toolResult(toolUseId: String?, content: String, isError: Bool)
        case image(mediaType: String)  // not rendered, just noted
    }
}

// MARK: - Parser

enum ConversationParser {
    /// Best-effort parse. Returns nil when neither body looks like a
    /// known AI exchange — caller falls back to the raw view.
    ///
    /// Routing by host:
    ///   anthropic.com          → /v1/messages
    ///   openai.com,
    ///     mistral.ai,
    ///     api.x.ai,
    ///     api.groq.com,
    ///     perplexity.ai        → /v1/chat/completions or /v1/responses
    ///                            (these vendors all expose the
    ///                            OpenAI request/response shape)
    ///   googleapis.com,
    ///     google.com           → :generateContent (Gemini)
    ///   cohere.com             → /v1/chat (Cohere's chat_history layout)
    static func parse(host: String,
                      requestBody: Data?,
                      responseBody: Data?) -> Conversation? {
        // The bodies we get from the trace store are the FULL HTTP
        // wire frames (request line / status line + headers + body).
        // Provider parsers expect just the JSON / SSE body, so we
        // strip the HTTP framing here. Without this, JSONSerialization
        // chokes on "POST /v1/messages HTTP/1.1\r\n..." and the
        // request side never gets parsed (the response SSE path
        // tolerates the leading frame because it filters by "data:"
        // lines, which is why answers showed up but questions
        // didn't).
        let req = stripHTTPFraming(requestBody)
        let res = stripHTTPFraming(responseBody)

        let h = host.lowercased()
        if h.contains("anthropic.com") {
            return parseAnthropic(req: req, res: res)
        }
        if h.contains("openai.com")
            || h.contains("mistral.ai")
            || h.contains("x.ai")
            || h.contains("groq.com")
            || h.contains("perplexity.ai") {
            // openai.com vendor + OpenAI-compatible providers all
            // share the same wire shape (chat/completions or, for
            // Codex / newer SDKs, /v1/responses).
            return parseOpenAI(req: req, res: res)
        }
        if h.contains("googleapis.com") || h.contains("google.com") {
            return parseGemini(req: req, res: res)
        }
        if h.contains("cohere.com") {
            return parseCohere(req: req, res: res)
        }
        return nil
    }

    /// Drop the HTTP request/status line + headers, return everything
    /// after the `\r\n\r\n` (or `\n\n`) delimiter. Pass-through if
    /// the input doesn't look framed (e.g. someone hands us a raw
    /// body directly).
    private static func stripHTTPFraming(_ raw: Data?) -> Data? {
        guard let raw, !raw.isEmpty else { return raw }
        let crlf = Data("\r\n\r\n".utf8)
        if let r = raw.range(of: crlf) {
            return raw.subdata(in: r.upperBound..<raw.count)
        }
        let lf = Data("\n\n".utf8)
        if let r = raw.range(of: lf) {
            return raw.subdata(in: r.upperBound..<raw.count)
        }
        return raw
    }

    // MARK: Anthropic /v1/messages

    private static func parseAnthropic(req: Data?, res: Data?) -> Conversation? {
        var convo = Conversation(provider: .anthropic, model: nil,
                                 systemPrompt: nil, messages: [],
                                 inputTokens: nil, outputTokens: nil, raw: false)

        if let req, let json = try? JSONSerialization.jsonObject(with: req) as? [String: Any] {
            convo.model = json["model"] as? String
            // System prompt: either a string or an array of content blocks.
            if let sys = json["system"] as? String {
                convo.systemPrompt = sys
            } else if let sysArr = json["system"] as? [[String: Any]] {
                let texts = sysArr.compactMap { $0["text"] as? String }
                convo.systemPrompt = texts.joined(separator: "\n\n")
            }
            if let msgs = json["messages"] as? [[String: Any]] {
                for m in msgs {
                    guard let role = m["role"] as? String,
                          let r = Conversation.Message.Role(rawValue: role) else { continue }
                    let blocks = anthropicBlocks(from: m["content"])
                    convo.messages.append(Conversation.Message(role: r, content: blocks))
                }
            }
        }

        if let res {
            // Two shapes: full JSON (non-streaming) or SSE chunks.
            if let json = try? JSONSerialization.jsonObject(with: res) as? [String: Any] {
                if let blocks = json["content"] as? [[String: Any]] {
                    convo.messages.append(Conversation.Message(
                        role: .assistant, content: blocks.compactMap(anthropicBlock(_:))))
                }
                if let usage = json["usage"] as? [String: Any] {
                    convo.inputTokens = usage["input_tokens"] as? Int
                    convo.outputTokens = usage["output_tokens"] as? Int
                }
            } else if let sseText = String(data: res, encoding: .utf8) {
                let assistant = parseAnthropicSSE(sseText)
                if !assistant.content.isEmpty {
                    convo.messages.append(assistant)
                }
            }
        }

        return convo.messages.isEmpty ? nil : convo
    }

    /// Anthropic content can be a plain string or an array of blocks.
    private static func anthropicBlocks(from any: Any?) -> [Conversation.Block] {
        if let s = any as? String { return [.text(s)] }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap(anthropicBlock(_:))
        }
        return []
    }

    private static func anthropicBlock(_ b: [String: Any]) -> Conversation.Block? {
        guard let type = b["type"] as? String else { return nil }
        switch type {
        case "text":
            return .text((b["text"] as? String) ?? "")
        case "tool_use":
            let name = (b["name"] as? String) ?? "tool"
            let input = (b["input"] as? [String: Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0,
                                                       options: [.prettyPrinted, .sortedKeys]) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .toolUse(name: name, input: input)
        case "tool_result":
            let id = b["tool_use_id"] as? String
            let isError = (b["is_error"] as? Bool) ?? false
            // content is either string or [block]
            var text = ""
            if let s = b["content"] as? String {
                text = s
            } else if let arr = b["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return .toolResult(toolUseId: id, content: text, isError: isError)
        case "image":
            let mediaType = ((b["source"] as? [String: Any])?["media_type"] as? String) ?? "image"
            return .image(mediaType: mediaType)
        default:
            return nil
        }
    }

    /// Walk an SSE stream of Anthropic events, accumulate deltas
    /// keyed by content_block index, return the assembled assistant
    /// message.
    private static func parseAnthropicSSE(_ text: String) -> Conversation.Message {
        // Per content_block index → accumulator. We support text blocks
        // and tool_use blocks (the latter accumulate JSON via
        // input_json_delta into a partial_json string).
        struct Accum {
            var type: String = "text"
            var text: String = ""
            var toolName: String = ""
            var toolJSON: String = ""
        }
        var blocksByIndex: [Int: Accum] = [:]
        var maxIndex = -1

        for chunk in text.components(separatedBy: "\n\n") {
            // Each SSE event is "event: name\ndata: {json}". Pull the data lines.
            let dataLines = chunk
                .split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
            guard let dataStr = dataLines.first,
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_start":
                if let idx = obj["index"] as? Int,
                   let block = obj["content_block"] as? [String: Any] {
                    var a = blocksByIndex[idx] ?? Accum()
                    a.type = (block["type"] as? String) ?? "text"
                    if a.type == "tool_use" {
                        a.toolName = (block["name"] as? String) ?? "tool"
                    }
                    blocksByIndex[idx] = a
                    maxIndex = max(maxIndex, idx)
                }
            case "content_block_delta":
                guard let idx = obj["index"] as? Int,
                      let delta = obj["delta"] as? [String: Any] else { break }
                var a = blocksByIndex[idx] ?? Accum()
                if let t = delta["text"] as? String { a.text += t }
                if let pj = delta["partial_json"] as? String { a.toolJSON += pj }
                blocksByIndex[idx] = a
                maxIndex = max(maxIndex, idx)
            default:
                continue
            }
        }

        var blocks: [Conversation.Block] = []
        for i in 0...max(maxIndex, 0) {
            guard let a = blocksByIndex[i] else { continue }
            switch a.type {
            case "tool_use":
                blocks.append(.toolUse(name: a.toolName, input: a.toolJSON))
            default:
                if !a.text.isEmpty { blocks.append(.text(a.text)) }
            }
        }
        return Conversation.Message(role: .assistant, content: blocks)
    }

    // MARK: OpenAI — dispatches between Chat Completions + Responses APIs

    /// OpenAI's two chat-shaped endpoints diverge enough that they
    /// each get their own parser. Detection by request key:
    ///   `messages` → /v1/chat/completions
    ///   `input`    → /v1/responses (newer; what Codex talks)
    private static func parseOpenAI(req: Data?, res: Data?) -> Conversation? {
        // Sniff the request to pick the right parser. If the request
        // is missing (rare, but possible if only response was kept),
        // sniff the response: chat/completions has `choices`,
        // responses has `output`.
        let reqJSON = req.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let r = reqJSON {
            if r["input"] != nil || r["instructions"] != nil {
                return parseOpenAIResponses(reqJSON: r, res: res)
            }
            if r["messages"] != nil {
                return parseOpenAIChat(reqJSON: r, res: res)
            }
        }
        // Response-only sniff.
        let resJSON = res.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let s = resJSON {
            if s["output"] != nil { return parseOpenAIResponses(reqJSON: nil, res: res) }
            if s["choices"] != nil { return parseOpenAIChat(reqJSON: nil, res: res) }
        }
        // SSE response (no JSON sniff) — try both, take whichever
        // produces a non-empty assistant message.
        if let res, let sse = String(data: res, encoding: .utf8) {
            if sse.contains("event: response.") {
                return parseOpenAIResponses(reqJSON: nil, res: res)
            }
            if sse.contains("\"choices\"") {
                return parseOpenAIChat(reqJSON: nil, res: res)
            }
        }
        return nil
    }

    /// Classic Chat Completions API + most OpenAI-compatible vendors.
    private static func parseOpenAIChat(reqJSON: [String: Any]?, res: Data?) -> Conversation? {
        var convo = Conversation(provider: .openai, model: nil,
                                 systemPrompt: nil, messages: [],
                                 inputTokens: nil, outputTokens: nil, raw: false)
        if let json = reqJSON {
            convo.model = json["model"] as? String
            if let msgs = json["messages"] as? [[String: Any]] {
                for m in msgs {
                    guard let role = m["role"] as? String else { continue }
                    let normalized: Conversation.Message.Role
                    switch role {
                    case "developer", "system": normalized = .system
                    case "tool", "function":    normalized = .tool
                    case "assistant":           normalized = .assistant
                    default:                    normalized = .user
                    }
                    if normalized == .system, convo.systemPrompt == nil,
                       let s = m["content"] as? String {
                        convo.systemPrompt = s
                        continue
                    }
                    let blocks = openAIBlocks(from: m["content"])
                    convo.messages.append(Conversation.Message(role: normalized, content: blocks))
                }
            }
        }
        if let res {
            if let json = try? JSONSerialization.jsonObject(with: res) as? [String: Any] {
                if let choices = json["choices"] as? [[String: Any]] {
                    for c in choices {
                        if let message = c["message"] as? [String: Any] {
                            let blocks = openAIBlocks(from: message["content"])
                            convo.messages.append(Conversation.Message(
                                role: .assistant, content: blocks))
                        }
                    }
                }
                if let usage = json["usage"] as? [String: Any] {
                    convo.inputTokens = usage["prompt_tokens"] as? Int
                    convo.outputTokens = usage["completion_tokens"] as? Int
                }
            } else if let sseText = String(data: res, encoding: .utf8) {
                let assistant = parseOpenAIChatSSE(sseText)
                if !assistant.content.isEmpty {
                    convo.messages.append(assistant)
                }
            }
        }
        return convo.messages.isEmpty ? nil : convo
    }

    /// Responses API (/v1/responses) — what Codex and the latest
    /// OpenAI SDK use. Different shape: `input`/`instructions` in,
    /// `output` array out, SSE events of the `response.*` family.
    private static func parseOpenAIResponses(reqJSON: [String: Any]?, res: Data?) -> Conversation? {
        var convo = Conversation(provider: .openai, model: nil,
                                 systemPrompt: nil, messages: [],
                                 inputTokens: nil, outputTokens: nil, raw: false)
        if let json = reqJSON {
            convo.model = json["model"] as? String
            // `instructions` is the system prompt equivalent.
            if let inst = json["instructions"] as? String {
                convo.systemPrompt = inst
            }
            // `input` is either a string (one user message) or an
            // array of input items with role + content.
            if let s = json["input"] as? String, !s.isEmpty {
                convo.messages.append(Conversation.Message(
                    role: .user, content: [.text(s)]))
            } else if let items = json["input"] as? [[String: Any]] {
                for item in items {
                    let blocks = responsesItemBlocks(from: item)
                    let role = mapResponsesRole(item["role"] as? String)
                    if !blocks.isEmpty {
                        convo.messages.append(Conversation.Message(
                            role: role, content: blocks))
                    }
                }
            }
        }
        if let res {
            if let json = try? JSONSerialization.jsonObject(with: res) as? [String: Any] {
                if let output = json["output"] as? [[String: Any]] {
                    for item in output {
                        let role = mapResponsesRole(item["role"] as? String)
                        let blocks = responsesItemBlocks(from: item)
                        if !blocks.isEmpty {
                            convo.messages.append(Conversation.Message(
                                role: role, content: blocks))
                        }
                    }
                }
                if let usage = json["usage"] as? [String: Any] {
                    convo.inputTokens = usage["input_tokens"] as? Int
                    convo.outputTokens = usage["output_tokens"] as? Int
                }
            } else if let sseText = String(data: res, encoding: .utf8) {
                let assistant = parseOpenAIResponsesSSE(sseText)
                if !assistant.content.isEmpty {
                    convo.messages.append(assistant)
                }
            }
        }
        return convo.messages.isEmpty ? nil : convo
    }

    private static func mapResponsesRole(_ raw: String?) -> Conversation.Message.Role {
        switch raw {
        case "system", "developer": return .system
        case "assistant":           return .assistant
        case "tool", "function":    return .tool
        default:                    return .user
        }
    }

    /// One item in the Responses input/output arrays. Items can be
    /// plain message text, structured content blocks, function/tool
    /// calls, or function/tool outputs.
    private static func responsesItemBlocks(from item: [String: Any]) -> [Conversation.Block] {
        // Tool / function call ("type":"function_call" or "tool_call").
        if let type = item["type"] as? String {
            switch type {
            case "function_call", "tool_call":
                let name = (item["name"] as? String)
                    ?? (item["call_id"] as? String)
                    ?? "tool"
                let argsString: String
                if let s = item["arguments"] as? String {
                    argsString = s
                } else if let obj = item["arguments"] as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: obj,
                                                                 options: [.prettyPrinted, .sortedKeys]),
                          let s = String(data: data, encoding: .utf8) {
                    argsString = s
                } else {
                    argsString = ""
                }
                return [.toolUse(name: name, input: argsString)]
            case "function_call_output", "tool_call_output", "function_output":
                let id = item["call_id"] as? String
                let output = (item["output"] as? String) ?? ""
                return [.toolResult(toolUseId: id, content: output, isError: false)]
            default:
                break
            }
        }
        // Regular message content: `content` is a string or an
        // array of typed blocks.
        if let content = item["content"] as? String {
            return [.text(content)]
        }
        if let arr = item["content"] as? [[String: Any]] {
            return arr.compactMap { part in
                let t = part["type"] as? String
                switch t {
                case "input_text", "output_text", "text":
                    if let s = part["text"] as? String { return .text(s) }
                    return nil
                case "input_image", "image":
                    return .image(mediaType: "image")
                default:
                    return nil
                }
            }
        }
        return []
    }

    /// SSE for /v1/responses — `event: response.output_text.delta`
    /// chunks accumulate the assistant text. Tool call deltas land
    /// on `event: response.function_call_arguments.delta` (kept
    /// per item id so multi-tool turns reassemble correctly).
    private static func parseOpenAIResponsesSSE(_ text: String) -> Conversation.Message {
        var combined = ""
        var toolByItem: [String: (name: String, args: String)] = [:]
        var toolOrder: [String] = []

        for chunk in text.components(separatedBy: "\n\n") {
            var event = ""
            var dataStr = ""
            for line in chunk.split(separator: "\n") {
                if line.hasPrefix("event:") {
                    event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let v = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                    if dataStr.isEmpty { dataStr = v } else { dataStr += "\n" + v }
                }
            }
            guard !dataStr.isEmpty,
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch event {
            case "response.output_text.delta":
                if let d = obj["delta"] as? String { combined += d }
            case "response.function_call_arguments.delta":
                let id = (obj["item_id"] as? String) ?? "tool"
                if toolByItem[id] == nil {
                    toolByItem[id] = (name: id, args: "")
                    toolOrder.append(id)
                }
                if let d = obj["delta"] as? String {
                    toolByItem[id]?.args += d
                }
            case "response.output_item.added":
                // Carries the function name when a function_call
                // item starts.
                if let item = obj["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String,
                   let name = item["name"] as? String {
                    if toolByItem[id] != nil {
                        toolByItem[id]?.name = name
                    } else {
                        toolByItem[id] = (name: name, args: "")
                        toolOrder.append(id)
                    }
                }
            default:
                continue
            }
        }

        var blocks: [Conversation.Block] = []
        if !combined.isEmpty { blocks.append(.text(combined)) }
        for id in toolOrder {
            if let t = toolByItem[id] {
                blocks.append(.toolUse(name: t.name, input: t.args))
            }
        }
        return Conversation.Message(role: .assistant, content: blocks)
    }

    private static func openAIBlocks(from any: Any?) -> [Conversation.Block] {
        if let s = any as? String { return [.text(s)] }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { part in
                if (part["type"] as? String) == "text",
                   let t = part["text"] as? String { return .text(t) }
                if (part["type"] as? String) == "image_url" {
                    return .image(mediaType: "image")
                }
                return nil
            }
        }
        return []
    }

    /// SSE for /v1/chat/completions — `data: {choices: [{delta: {content: "…"}}]}`
    /// chunks accumulate into one assistant text block.
    private static func parseOpenAIChatSSE(_ text: String) -> Conversation.Message {
        var combined = ""
        for chunk in text.components(separatedBy: "\n\n") {
            let dataLines = chunk
                .split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
            for line in dataLines where line != "[DONE]" {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]] else { continue }
                for c in choices {
                    if let delta = c["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        combined += content
                    }
                }
            }
        }
        return Conversation.Message(role: .assistant,
                                    content: combined.isEmpty ? [] : [.text(combined)])
    }

    // MARK: Cohere /v1/chat

    /// Cohere's request shape: `{ "message": "current turn",
    /// "chat_history": [{"role":"USER|CHATBOT","message":"…"}],
    /// "preamble": "system prompt" }`. Response: `{ "text": "…",
    /// "meta": {"tokens":{"input_tokens":…,"output_tokens":…}} }`.
    private static func parseCohere(req: Data?, res: Data?) -> Conversation? {
        var convo = Conversation(provider: .cohere, model: nil,
                                 systemPrompt: nil, messages: [],
                                 inputTokens: nil, outputTokens: nil, raw: false)
        if let req, let json = try? JSONSerialization.jsonObject(with: req) as? [String: Any] {
            convo.model = json["model"] as? String
            if let preamble = json["preamble"] as? String { convo.systemPrompt = preamble }
            if let history = json["chat_history"] as? [[String: Any]] {
                for h in history {
                    let role = (h["role"] as? String)?.uppercased() ?? "USER"
                    let r: Conversation.Message.Role = (role == "CHATBOT" || role == "ASSISTANT") ? .assistant : .user
                    if let msg = h["message"] as? String {
                        convo.messages.append(Conversation.Message(role: r, content: [.text(msg)]))
                    }
                }
            }
            if let cur = json["message"] as? String {
                convo.messages.append(Conversation.Message(role: .user, content: [.text(cur)]))
            }
        }
        if let res, let json = try? JSONSerialization.jsonObject(with: res) as? [String: Any] {
            if let text = json["text"] as? String, !text.isEmpty {
                convo.messages.append(Conversation.Message(role: .assistant, content: [.text(text)]))
            }
            if let meta = json["meta"] as? [String: Any],
               let tokens = meta["tokens"] as? [String: Any] {
                convo.inputTokens = tokens["input_tokens"] as? Int
                convo.outputTokens = tokens["output_tokens"] as? Int
            }
        }
        return convo.messages.isEmpty ? nil : convo
    }

    // MARK: Gemini

    private static func parseGemini(req: Data?, res: Data?) -> Conversation? {
        var convo = Conversation(provider: .gemini, model: nil,
                                 systemPrompt: nil, messages: [],
                                 inputTokens: nil, outputTokens: nil, raw: false)
        if let req, let json = try? JSONSerialization.jsonObject(with: req) as? [String: Any] {
            if let sys = (json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] {
                convo.systemPrompt = sys.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            }
            if let contents = json["contents"] as? [[String: Any]] {
                for c in contents {
                    let role = (c["role"] as? String) ?? "user"
                    let r: Conversation.Message.Role = (role == "model") ? .assistant : .user
                    let parts = (c["parts"] as? [[String: Any]]) ?? []
                    let blocks: [Conversation.Block] = parts.compactMap {
                        if let t = $0["text"] as? String { return .text(t) }
                        return nil
                    }
                    convo.messages.append(Conversation.Message(role: r, content: blocks))
                }
            }
        }
        if let res, let json = try? JSONSerialization.jsonObject(with: res) as? [String: Any] {
            if let cands = json["candidates"] as? [[String: Any]] {
                for c in cands {
                    if let content = c["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        let blocks: [Conversation.Block] = parts.compactMap {
                            if let t = $0["text"] as? String { return .text(t) }
                            return nil
                        }
                        convo.messages.append(Conversation.Message(role: .assistant, content: blocks))
                    }
                }
            }
        }
        return convo.messages.isEmpty ? nil : convo
    }
}

// MARK: - View

/// Chat-style render of a parsed `Conversation`. Bubbles per message,
/// special blocks for tool_use / tool_result, monospace for code.
struct ConversationView: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 10) {
                    if let sys = conversation.systemPrompt, !sys.isEmpty {
                        SystemBubble(text: sys)
                    }
                    ForEach(conversation.messages) { msg in
                        MessageBubble(message: msg)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: providerIcon)
                .foregroundStyle(.secondary)
            Text(providerLabel)
                .font(.subheadline.weight(.semibold))
            if let model = conversation.model {
                Text(model)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12),
                                in: Capsule())
            }
            Spacer()
            if let inT = conversation.inputTokens {
                Label("\(inT) in", systemImage: "arrow.down")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if let outT = conversation.outputTokens {
                Label("\(outT) out", systemImage: "arrow.up")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var providerLabel: String {
        switch conversation.provider {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .gemini:    return "Google Gemini"
        case .cohere:    return "Cohere"
        case .unknown:   return "AI conversation"
        }
    }
    private var providerIcon: String {
        "sparkles"
    }
}

private struct SystemBubble: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("System prompt", systemImage: "gear")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                )
        }
    }
}

private struct MessageBubble: View {
    let message: Conversation.Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 60)
                bubble(alignment: .trailing)
            } else {
                bubble(alignment: .leading)
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(roleLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { (_, block) in
                    BlockView(block: block)
                }
                if message.content.isEmpty {
                    Text("(empty)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(10)
            .frame(maxWidth: 720, alignment: .leading)
            .background(bubbleBackground,
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user:       return "You"
        case .assistant:  return "Assistant"
        case .system:     return "System"
        case .tool:       return "Tool"
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:       return Color.accentColor.opacity(0.18)
        case .assistant:  return Color.secondary.opacity(0.10)
        case .system:     return Color.secondary.opacity(0.06)
        case .tool:       return Color.purple.opacity(0.10)
        }
    }
}

private struct BlockView: View {
    let block: Conversation.Block

    var body: some View {
        switch block {
        case .text(let s):
            Text(prettyText(s))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let name, let input):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(name)
                        .font(.caption.weight(.semibold).monospaced())
                }
                .foregroundStyle(.purple)
                if !input.isEmpty {
                    Text(input)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.purple.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .toolResult(_, let content, let isError):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: isError
                          ? "xmark.octagon.fill"
                          : "checkmark.seal.fill")
                    Text(isError
                         ? NSLocalizedString("Tool error", comment: "")
                         : NSLocalizedString("Tool result", comment: ""))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(isError ? .red : .green)
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        (isError ? Color.red : Color.green).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            }
        case .image(let mediaType):
            HStack(spacing: 4) {
                Image(systemName: "photo")
                Text("\(mediaType) attachment")
                    .font(.caption.italic())
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Trim trailing whitespace per-line so streaming-assembled deltas
    /// don't look ragged. Preserves markdown-y formatting otherwise —
    /// we leave actual markdown rendering for later.
    private func prettyText(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces.subtracting(.init(charactersIn: ""))) }
            .joined(separator: "\n")
    }
}
