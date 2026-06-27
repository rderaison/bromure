import Foundation
import MLXLMCommon

/// The three wire protocols the local engine speaks. Parsing (request → chat
/// messages + tools) and rendering (completion → non-streaming JSON) for each.
/// Streaming + tool-call extraction is handled downstream by
/// ``InferenceRepairProxy`` / ``ToolCallRepair``.
enum Wire {
    case messages    // Anthropic /v1/messages
    case chat        // OpenAI  /v1/chat/completions
    case responses   // OpenAI  /v1/responses (Codex)

    // MARK: - Response rendering (non-streaming protocol JSON)

    func nonStreamingJSON(model: String, completion c: MLXEngine.Completion) -> [String: Any] {
        let id = "bromure-\(UUID().uuidString.prefix(12))"
        switch self {
        case .messages:
            return [
                "id": "msg_\(id)",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [["type": "text", "text": c.text]],
                "stop_reason": c.finishReason == "length" ? "max_tokens" : "end_turn",
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": c.promptTokens, "output_tokens": c.completionTokens],
            ]
        case .chat:
            return [
                "id": "chatcmpl-\(id)",
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": model,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": c.text],
                    "finish_reason": c.finishReason == "length" ? "length" : "stop",
                ]],
                "usage": [
                    "prompt_tokens": c.promptTokens,
                    "completion_tokens": c.completionTokens,
                    "total_tokens": c.promptTokens + c.completionTokens,
                ],
            ]
        case .responses:
            return [
                "id": "resp_\(id)",
                "object": "response",
                "status": "completed",
                "model": model,
                "output": [[
                    "type": "message",
                    "id": "msg_\(id)",
                    "role": "assistant",
                    "status": "completed",
                    "content": [["type": "output_text", "text": c.text, "annotations": []]],
                ]],
                "usage": ["input_tokens": c.promptTokens, "output_tokens": c.completionTokens],
            ]
        }
    }
}

/// A request parsed out of any of the three wire formats into the engine's
/// common shape.
struct WireRequest {
    var model: String
    var messages: [Chat.Message]
    var tools: [ToolDef]?
    var maxTokens: Int?
    var temperature: Float?
    var topP: Float?

    static func parse(_ p: [String: Any], wire: Wire) -> WireRequest {
        let model = (p["model"] as? String) ?? ""
        let temperature = (p["temperature"] as? NSNumber)?.floatValue
        let topP = (p["top_p"] as? NSNumber)?.floatValue
        let maxTokens = (p["max_tokens"] as? Int)
            ?? (p["max_completion_tokens"] as? Int)
            ?? (p["max_output_tokens"] as? Int)

        var messages: [Chat.Message] = []
        var tools: [ToolDef]?

        switch wire {
        case .messages:
            let sys = flattenContent(p["system"])
            if !sys.isEmpty { messages.append(.system(sys)) }
            for m in (p["messages"] as? [[String: Any]] ?? []) {
                messages.append(contentsOf: anthropicMessage(m))
            }
            tools = (p["tools"] as? [[String: Any]])?.compactMap { t in
                guard let name = t["name"] as? String else { return nil }
                return ToolDef(name: name,
                               description: t["description"] as? String ?? "",
                               parametersJSONString: jsonString(t["input_schema"]))
            }

        case .chat:
            for m in (p["messages"] as? [[String: Any]] ?? []) {
                let role = (m["role"] as? String) ?? "user"
                let content = flattenContent(m["content"])
                messages.append(message(role: role, content: content))
            }
            tools = openAITools(p["tools"])

        case .responses:
            // Codex's Responses API: `input` is either a string or an array of
            // typed items (message / function_call / function_call_output).
            if let s = p["input"] as? String {
                messages.append(.user(s))
            } else if let items = p["input"] as? [[String: Any]] {
                for item in items { messages.append(contentsOf: responsesItem(item)) }
            }
            if let instr = p["instructions"] as? String, !instr.isEmpty {
                messages.insert(.system(instr), at: 0)
            }
            tools = openAITools(p["tools"])
        }

        return WireRequest(model: model, messages: messages, tools: tools,
                           maxTokens: maxTokens, temperature: temperature, topP: topP)
    }

    // MARK: - Per-protocol message mapping

    private static func anthropicMessage(_ m: [String: Any]) -> [Chat.Message] {
        let role = (m["role"] as? String) ?? "user"
        guard let blocks = m["content"] as? [[String: Any]] else {
            return [message(role: role, content: flattenContent(m["content"]))]
        }
        var out: [Chat.Message] = []
        var text = ""
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                text += (b["text"] as? String ?? "")
            case "tool_use":
                let name = b["name"] as? String ?? ""
                text += "\n<tool_call>\(jsonString(["name": name, "arguments": b["input"] ?? [:]]))</tool_call>"
            case "tool_result":
                if !text.isEmpty { out.append(message(role: role, content: text)); text = "" }
                out.append(.tool(flattenContent(b["content"])))
            default:
                break
            }
        }
        if !text.isEmpty || out.isEmpty { out.append(message(role: role, content: text)) }
        return out
    }

    private static func responsesItem(_ item: [String: Any]) -> [Chat.Message] {
        switch item["type"] as? String {
        case "message", nil:
            let role = (item["role"] as? String) ?? "user"
            return [message(role: role, content: flattenContent(item["content"]))]
        case "function_call":
            let name = item["name"] as? String ?? ""
            let args = item["arguments"] as? String ?? "{}"
            return [.assistant("\n<tool_call>{\"name\":\"\(name)\",\"arguments\":\(args)}</tool_call>")]
        case "function_call_output":
            return [.tool(flattenContent(item["output"]))]
        default:
            return []
        }
    }

    private static func openAITools(_ raw: Any?) -> [ToolDef]? {
        (raw as? [[String: Any]])?.compactMap { t in
            guard let fn = t["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return nil }
            return ToolDef(name: name,
                           description: fn["description"] as? String ?? "",
                           parametersJSONString: jsonString(fn["parameters"]))
        }
    }

    private static func message(role: String, content: String) -> Chat.Message {
        switch role {
        case "system", "developer": return .system(content)
        case "assistant": return .assistant(content)
        case "tool": return .tool(content)
        default: return .user(content)
        }
    }

    // MARK: - Content flattening

    /// Anthropic/OpenAI content can be a plain string or an array of typed
    /// blocks; flatten to a single string for the chat template.
    static func flattenContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { b -> String? in
                if let t = b["text"] as? String { return t }
                if let t = b["content"] as? String { return t }
                return nil
            }.joined()
        }
        if let blocks = raw as? [Any] {
            return blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        }
        return ""
    }

    static func jsonString(_ obj: Any?) -> String {
        guard let obj, JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
