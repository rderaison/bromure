import Foundation

/// The three wire protocols the local engine speaks. Parsing (request → chat
/// messages + tools) and rendering (completion → non-streaming JSON) for each.
/// Streaming + tool-call extraction is handled downstream by
/// ``InferenceRepairProxy`` / ``ToolCallRepair``.
enum Wire {
    case messages    // Anthropic /v1/messages
    case chat        // OpenAI  /v1/chat/completions
    case responses   // OpenAI  /v1/responses (Codex)

    /// Error body in this wire's native shape, so the agent surfaces the real
    /// reason instead of a generic "issue with the selected model" (Bug#5).
    /// Anthropic (Claude) requires the `{"type":"error","error":{…}}` envelope;
    /// the OpenAI surfaces (Grok/Codex) use `{"error":{…}}`. `type` is the
    /// provider error class (e.g. invalid_request_error / api_error).
    func errorJSON(message: String, type: String) -> [String: Any] {
        switch self {
        case .messages:
            return ["type": "error", "error": ["type": type, "message": message]]
        case .chat, .responses:
            return ["error": ["message": message, "type": type, "code": NSNull()]]
        }
    }
}

/// Request content as text, for any of the wire formats (the MLX engine's
/// chat template, the external engines' translation).
enum WireText {
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
