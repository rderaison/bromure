import Foundation

/// Bridges local inference to a USER-SUPPLIED OpenAI-compatible server
/// (vLLM, Ollama, LM Studio, llama-server, …) instead of the built-in
/// in-process MLX engine — the "point Local Models at the engine of my
/// choice" path. External servers speak only the OpenAI chat API, while the
/// guest agents speak three wires (Anthropic messages / OpenAI chat / OpenAI
/// responses), so this type owns the two translations:
///
///   request:  wire payload   → /v1/chat/completions body
///   response: chat completion → wire-native message (NATIVE tool blocks)
///
/// The repair proxy calls both around its upstream send; everything
/// downstream (tool-call rescue, stuck-preamble continuation, SSE
/// re-emission, tracing) is engine-agnostic and shared with the built-in
/// path. Native `tool_calls` are mapped to native wire blocks — the repair
/// helpers are no-ops when a structured call is already present.
enum ExternalEngine {

    /// One workspace's external engine endpoint. `apiKey` is the server's own
    /// bearer (vLLM `--api-key`); nil/empty for open servers like Ollama.
    struct Config: Equatable, Sendable {
        var base: URL
        var apiKey: String?
    }

    // MARK: - Request translation (wire → OpenAI chat)

    /// Translate an inference payload in `wire` format into the
    /// `/v1/chat/completions` body the external server understands.
    /// `.chat` is already the right shape and passes through (stream forced
    /// off — the repair proxy buffers whole messages).
    static func chatRequest(from payload: [String: Any], wire: Wire) -> [String: Any] {
        if case .chat = wire {
            var out = payload
            out["stream"] = false
            return out
        }
        var out: [String: Any] = ["model": payload["model"] ?? "", "stream": false]
        var msgs: [[String: Any]] = []

        switch wire {
        case .chat:
            break   // handled above
        case .messages:
            let sys = WireRequest.flattenContent(payload["system"])
            if !sys.isEmpty { msgs.append(["role": "system", "content": sys]) }
            for m in payload["messages"] as? [[String: Any]] ?? [] {
                msgs += fromAnthropicMessage(m)
            }
            out["tools"] = anthropicTools(payload["tools"])
            if let v = payload["max_tokens"] { out["max_tokens"] = v }
            if let v = payload["stop_sequences"] { out["stop"] = v }
            // The agent's own thinking config controls upstream reasoning:
            // Ollama's OpenAI-compat endpoint honors `reasoning_effort`
            // ("none" disables it entirely — verified live; `think` is
            // ignored there), and servers without support ignore the field.
            if let think = payload["thinking"] as? [String: Any] {
                if (think["type"] as? String) == "disabled" {
                    out["reasoning_effort"] = "none"
                } else if let budget = think["budget_tokens"] as? Int {
                    out["reasoning_effort"] = budget < 4096 ? "low"
                        : (budget < 16384 ? "medium" : "high")
                }
            }
        case .responses:
            if let instr = payload["instructions"] as? String, !instr.isEmpty {
                msgs.append(["role": "system", "content": instr])
            }
            // Responses reasoning config → the same OpenAI-compat knob.
            if let effort = (payload["reasoning"] as? [String: Any])?["effort"] as? String {
                out["reasoning_effort"] = effort == "minimal" ? "low" : effort
            }
            if let s = payload["input"] as? String {
                msgs.append(["role": "user", "content": s])
            } else if let items = payload["input"] as? [[String: Any]] {
                for item in items { msgs += fromResponsesItem(item) }
            }
            out["tools"] = responsesTools(payload["tools"])
            if let v = payload["max_output_tokens"] { out["max_tokens"] = v }
        }

        out["messages"] = msgs
        if let v = payload["temperature"] { out["temperature"] = v }
        if let v = payload["top_p"] { out["top_p"] = v }
        if let tc = toolChoice(payload["tool_choice"]) { out["tool_choice"] = tc }
        if out["tools"] == nil { out.removeValue(forKey: "tools") }
        return out
    }

    /// Anthropic message → OpenAI chat messages. `tool_use` blocks become a
    /// native `tool_calls` assistant message; `tool_result` blocks become
    /// `role:"tool"` messages (emitted in block order, any text after — the
    /// results answer the PREVIOUS assistant turn's calls, so they precede
    /// this turn's prose).
    private static func fromAnthropicMessage(_ m: [String: Any]) -> [[String: Any]] {
        let role = (m["role"] as? String) ?? "user"
        guard let blocks = m["content"] as? [[String: Any]] else {
            let text = WireRequest.flattenContent(m["content"])
            return text.isEmpty ? [] : [["role": role, "content": text]]
        }
        if role == "assistant" {
            var text = ""
            var calls: [[String: Any]] = []
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    text += (b["text"] as? String ?? "")
                case "tool_use":
                    calls.append(["id": b["id"] as? String ?? "call_x", "type": "function",
                                  "function": ["name": b["name"] as? String ?? "",
                                               "arguments": WireRequest.jsonString(b["input"])]])
                default:
                    break   // thinking / redacted blocks never round-trip
                }
            }
            var msg: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty { msg["tool_calls"] = calls }
            return (text.isEmpty && calls.isEmpty) ? [] : [msg]
        }
        var out: [[String: Any]] = []
        var parts: [[String: Any]] = []   // text + image_url, in block order
        var hasImage = false
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                parts.append(["type": "text", "text": b["text"] as? String ?? ""])
            case "image":
                // Anthropic image block → OpenAI image_url part (data: URI
                // for base64 sources). Dropping these was why vision-capable
                // local models never saw the agent's screenshots.
                if let url = chatImageURL(anthropicSource: b["source"]) {
                    parts.append(["type": "image_url", "image_url": ["url": url]])
                    hasImage = true
                }
            case "tool_result":
                out.append(["role": "tool",
                            "tool_call_id": b["tool_use_id"] as? String ?? "call_x",
                            "content": WireRequest.flattenContent(b["content"])])
                // OpenAI tool messages are text-only; a screenshot inside a
                // tool_result (e.g. a browser capture) is lifted into the
                // following user turn so the model still sees it.
                for c in b["content"] as? [[String: Any]] ?? []
                where (c["type"] as? String) == "image" {
                    if let url = chatImageURL(anthropicSource: c["source"]) {
                        parts.append(["type": "image_url", "image_url": ["url": url]])
                        hasImage = true
                    }
                }
            default:
                break
            }
        }
        if hasImage {
            out.append(["role": role, "content": parts])
        } else {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { out.append(["role": role, "content": text]) }
        }
        return out
    }

    /// Anthropic image `source` → an OpenAI-compatible image URL (data: URI
    /// for base64 payloads, passthrough for URL sources).
    private static func chatImageURL(anthropicSource raw: Any?) -> String? {
        guard let src = raw as? [String: Any] else { return nil }
        switch src["type"] as? String {
        case "base64":
            guard let data = src["data"] as? String, !data.isEmpty else { return nil }
            return "data:\(src["media_type"] as? String ?? "image/png");base64,\(data)"
        case "url":
            return src["url"] as? String
        default:
            return nil
        }
    }

    /// Responses input item → OpenAI chat messages (native tool_calls / tool
    /// role, unlike WireRequest's flatten-to-text mapping for the MLX
    /// chat template).
    private static func fromResponsesItem(_ item: [String: Any]) -> [[String: Any]] {
        switch item["type"] as? String {
        case "message", nil:
            let role = (item["role"] as? String) ?? "user"
            let mapped = role == "developer" ? "system" : role
            var parts: [[String: Any]] = []
            var hasImage = false
            for c in item["content"] as? [[String: Any]] ?? [] {
                if (c["type"] as? String) == "input_image" {
                    // Responses input_image → image_url part; the url rides
                    // either a bare string or an {url:} object.
                    let url = (c["image_url"] as? String)
                        ?? ((c["image_url"] as? [String: Any])?["url"] as? String)
                    if let url {
                        parts.append(["type": "image_url", "image_url": ["url": url]])
                        hasImage = true
                    }
                } else if let t = c["text"] as? String {
                    parts.append(["type": "text", "text": t])
                }
            }
            if hasImage { return [["role": mapped, "content": parts]] }
            let text = WireRequest.flattenContent(item["content"])
            return text.isEmpty ? [] : [["role": mapped, "content": text]]
        case "function_call":
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_x"
            return [["role": "assistant", "content": "",
                     "tool_calls": [["id": callID, "type": "function",
                                     "function": ["name": item["name"] as? String ?? "",
                                                  "arguments": item["arguments"] as? String ?? "{}"]]]]]
        case "function_call_output":
            return [["role": "tool",
                     "tool_call_id": item["call_id"] as? String ?? "call_x",
                     "content": WireRequest.flattenContent(item["output"])]]
        default:
            return []
        }
    }

    /// Anthropic `tools` (name/description/input_schema) → OpenAI nested form.
    private static func anthropicTools(_ raw: Any?) -> [[String: Any]]? {
        let tools = (raw as? [[String: Any]] ?? []).compactMap { t -> [String: Any]? in
            guard let name = t["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name,
                                     "parameters": t["input_schema"] ?? ["type": "object"]]
            if let d = t["description"] { fn["description"] = d }
            return ["type": "function", "function": fn]
        }
        return tools.isEmpty ? nil : tools
    }

    /// Responses `tools` (flat name/description/parameters) → OpenAI nested
    /// form. Accepts already-nested entries too.
    private static func responsesTools(_ raw: Any?) -> [[String: Any]]? {
        let tools = (raw as? [[String: Any]] ?? []).compactMap { t -> [String: Any]? in
            let fn = (t["function"] as? [String: Any]) ?? t
            guard let name = fn["name"] as? String else { return nil }
            var f: [String: Any] = ["name": name,
                                    "parameters": fn["parameters"] ?? ["type": "object"]]
            if let d = fn["description"] { f["description"] = d }
            return ["type": "function", "function": f]
        }
        return tools.isEmpty ? nil : tools
    }

    /// Map a wire `tool_choice` to the OpenAI form. Strings ("auto" /
    /// "required" / "none") pass through — the continuation nudge sets
    /// `tool_choice: "required"` on every wire.
    private static func toolChoice(_ raw: Any?) -> Any? {
        if let s = raw as? String { return s }
        guard let d = raw as? [String: Any] else { return nil }
        switch d["type"] as? String {
        case "any": return "required"
        case "none": return "none"
        case "tool", "function":
            let name = (d["name"] as? String)
                ?? ((d["function"] as? [String: Any])?["name"] as? String)
            return name.map { ["type": "function", "function": ["name": $0]] }
        default: return "auto"
        }
    }

    // MARK: - Response translation (OpenAI chat → wire)

    /// Translate the external server's chat completion into `wire`'s native
    /// non-streaming message — the same shape `Wire.nonStreamingJSON` renders
    /// for the built-in engine, but with NATIVE tool blocks (the server's own
    /// parser produced them; no text round-trip).
    static func wireResponse(from chat: [String: Any], wire: Wire) -> [String: Any] {
        if case .chat = wire { return chat }
        let choice = (chat["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        let text = WireRequest.flattenContent(message["content"])
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        let finish = choice["finish_reason"] as? String ?? "stop"
        let usage = chat["usage"] as? [String: Any] ?? [:]
        let inTok = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let outTok = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
        let model = chat["model"] as? String ?? ""
        let id = "bromure-\(UUID().uuidString.prefix(12))"

        switch wire {
        case .chat:
            return chat   // handled above
        case .messages:
            var content: [[String: Any]] = []
            // Upstream reasoning (Ollama/vLLM separate it into `reasoning` /
            // `reasoning_content`) becomes a native thinking block — the
            // agent renders it collapsed and the user toggles it on demand;
            // agents never send thinking back, so transcripts don't bloat.
            if let reasoning = (message["reasoning"] as? String)
                ?? (message["reasoning_content"] as? String), !reasoning.isEmpty {
                content.append(["type": "thinking", "thinking": reasoning, "signature": ""])
            }
            if !text.isEmpty || toolCalls.isEmpty {
                content.append(["type": "text", "text": text])
            }
            for tc in toolCalls {
                let fn = tc["function"] as? [String: Any] ?? [:]
                content.append(["type": "tool_use",
                                "id": tc["id"] as? String ?? "call_x",
                                "name": fn["name"] as? String ?? "",
                                "input": parsedArguments(fn["arguments"])])
            }
            let stop = !toolCalls.isEmpty ? "tool_use"
                : (finish == "length" ? "max_tokens" : "end_turn")
            return ["id": "msg_\(id)", "type": "message", "role": "assistant",
                    "model": model, "content": content,
                    "stop_reason": stop, "stop_sequence": NSNull(),
                    "usage": ["input_tokens": inTok, "output_tokens": outTok]]
        case .responses:
            var output: [[String: Any]] = []
            if !text.isEmpty || toolCalls.isEmpty {
                output.append(["type": "message", "id": "msg_\(id)", "role": "assistant",
                               "status": "completed",
                               "content": [["type": "output_text", "text": text, "annotations": []]]])
            }
            for tc in toolCalls {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let callID = tc["id"] as? String ?? "call_x"
                output.append(["type": "function_call", "id": "fc_\(callID)", "call_id": callID,
                               "name": fn["name"] as? String ?? "",
                               "arguments": (fn["arguments"] as? String) ?? "{}",
                               "status": "completed"])
            }
            return ["id": "resp_\(id)", "object": "response",
                    "status": finish == "length" ? "incomplete" : "completed",
                    "model": model, "output": output,
                    "usage": ["input_tokens": inTok, "output_tokens": outTok,
                              "total_tokens": inTok + outTok]]
        }
    }

    /// OpenAI carries tool-call arguments as a JSON *string*; the Anthropic
    /// wire wants the object. A malformed string (quantized models…) falls
    /// back to `{}` — the repair pipeline's rescue already covers the
    /// text-leak variants.
    private static func parsedArguments(_ raw: Any?) -> [String: Any] {
        if let d = raw as? [String: Any] { return d }
        guard let s = raw as? String, let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// The server's error body, whichever shape it uses — OpenAI/vLLM
    /// `{"error":{"message":…}}`, Ollama `{"error":"…"}` — or the raw text.
    static func errorReason(from data: Data) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
            if let m = obj["message"] as? String { return m }
        }
        let s = String(data: data.prefix(300), encoding: .utf8) ?? ""
        return s.isEmpty ? "no response body" : s
    }

    // MARK: - Model list / reachability

    enum ProbeError: LocalizedError {
        case badStatus(Int, String)
        case badBody
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let reason):
                return code == 401 ? "The engine rejected the API key (401)."
                                   : "The engine answered \(code): \(reason)"
            case .badBody:
                return "The engine's /v1/models reply wasn't an OpenAI model list."
            }
        }
    }

    /// `GET {base}/v1/models` → sorted model ids. Doubles as the launch-time
    /// reachability probe and the settings pane's model list.
    static func listModels(base: URL, apiKey: String?,
                           timeout: TimeInterval = 10) async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                       errorReason(from: data))
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw ProbeError.badBody
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: - Model metadata (context window + capabilities)

    /// Server-reported metadata for one model. `nil` fields mean the server
    /// didn't say (vLLM exposes only `max_model_len`), never "no".
    struct ModelMeta: Codable, Equatable, Sendable {
        var context: Int?
        var vision: Bool?
        var thinking: Bool?
    }

    /// Probe `base` for `model`'s metadata. Ollama's `/api/show` is the rich
    /// source — context (`num_ctx` parameter wins over the architecture's
    /// `context_length`) plus the capability list (vision/thinking), which
    /// omp's models.yml gates image input on: without it a vision-capable
    /// model gets a client-side "not a vision model" refusal. vLLM lacks
    /// `/api/show`; its `/v1/models` `max_model_len` fills the context in.
    static func modelMeta(base: URL, apiKey: String?, model: String,
                          timeout: TimeInterval = 10) async -> ModelMeta? {
        var meta = ModelMeta()

        var show = URLRequest(url: base.appendingPathComponent("api/show"))
        show.timeoutInterval = timeout
        show.httpMethod = "POST"
        show.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            show.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        show.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        if let (data, resp) = try? await URLSession.shared.data(for: show),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let caps = obj["capabilities"] as? [String] {
                meta.vision = caps.contains("vision")
                meta.thinking = caps.contains("thinking")
            }
            if let params = obj["parameters"] as? String {
                for line in params.split(separator: "\n") {
                    let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    if toks.count >= 2, toks[0] == "num_ctx", let n = Int(toks[1]), n > 0 {
                        meta.context = n
                    }
                }
            }
            if meta.context == nil, let info = obj["model_info"] as? [String: Any] {
                for (k, v) in info where k.hasSuffix(".context_length") {
                    if let n = v as? Int, n > 0 { meta.context = n }
                }
            }
        }

        if meta.context == nil {
            var req = URLRequest(url: base.appendingPathComponent("v1/models"))
            req.timeoutInterval = timeout
            if let apiKey, !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let entry = (obj["data"] as? [[String: Any]])?.first(where: { $0["id"] as? String == model }),
               let len = entry["max_model_len"] as? Int, len > 0 {
                meta.context = len
            }
        }

        return meta == ModelMeta() ? nil : meta
    }
}
