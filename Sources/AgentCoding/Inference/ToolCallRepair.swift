import Foundation

/// Rescues tool calls that a local model emitted as TEXT in a format
/// vllm-mlx's parser failed to recognize — turning them into proper
/// Anthropic `tool_use` blocks.
///
/// Why this exists: quantized MLX coding models frequently emit a tool call
/// in an ad-hoc shape (```xml`<function name="X" arguments='{…}'>`,
/// `[{"name":"X","parameters":{…}}](…)`, a bare `<tool_call>{…}</tool_call>`)
/// rather than the exact format the configured `--tool-call-parser` expects.
/// When that happens vllm-mlx returns the call as plain text with
/// `stop_reason: end_turn`, so the agent (Claude Code/Codex/Grok — which
/// *provide* the tools) never sees a tool call: "tools don't work," and the
/// raw call text shows up as a stray "reasoning step." We re-parse those
/// shapes here and synthesize the tool_use the agent expects. Verified live:
/// makes Qwen2.5/Qwen3-Coder reliable even at greedy decoding.
enum ToolCallRepair {

    /// Pull leaked tool calls out of one text blob. Returns the text with the
    /// call markup removed, plus the recovered tool_use blocks (as JSON dicts).
    static func rescue(text: String, toolNames: Set<String> = []) -> (cleaned: String, blocks: [[String: Any]]) {
        var blocks: [[String: Any]] = []
        var cleaned = text

        for spec in patterns {
            let re = spec.regex
            let ns = cleaned as NSString
            // Iterate matches on a stable snapshot; remove spans afterwards.
            let matches = re.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                guard let parsed = spec.extract(m, ns) else { continue }
                blocks.insert(["type": "tool_use",
                               "id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                               "name": parsed.name,
                               "input": parsed.input], at: 0)
                cleaned = ns.replacingCharacters(in: m.range, with: "")
            }
        }
        // Bare JSON-object tool calls the regex specs don't cover.
        let bare = rescueBareJSON(cleaned)
        blocks += bare.blocks
        cleaned = bare.cleaned
        // XML-element tool calls (<ToolName attr="…" …/>) — only for tools the
        // request actually declared, so stray XML in prose isn't misread.
        if !toolNames.isEmpty {
            let xml = rescueXMLElement(cleaned, toolNames: toolNames)
            blocks += xml.blocks
            cleaned = xml.cleaned
        }
        // Qwen3-Coder native format: <function=Name><parameter=k>v</parameter>…</function>
        let qfn = rescueQwenFunctionCalls(cleaned, toolNames: toolNames)
        blocks += qfn.blocks
        cleaned = qfn.cleaned
        // Drop now-empty code fences + tool-call wrappers left behind by the
        // markup removal (e.g. Qwen wraps <function=…> in <tool_call>…</tool_call>).
        cleaned = cleaned.replacingOccurrences(of: "```xml", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "<tool_call>", with: "")
            .replacingOccurrences(of: "</tool_call>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, blocks)
    }

    /// Repair a non-streaming Anthropic message dict. No-op when the engine
    /// already produced a tool_use (the parser worked) — we only rescue when
    /// the call leaked into text.
    static func repair(message: [String: Any], toolNames: Set<String> = []) -> [String: Any] {
        var msg = message
        let content = msg["content"] as? [[String: Any]] ?? []
        if content.contains(where: { ($0["type"] as? String) == "tool_use" }) { return msg }

        var newContent: [[String: Any]] = []
        var rescued: [[String: Any]] = []
        for b in content {
            if (b["type"] as? String) == "text", let t = b["text"] as? String {
                let (clean, tus) = rescue(text: t, toolNames: toolNames)
                rescued += tus
                if !clean.isEmpty { newContent.append(["type": "text", "text": clean]) }
            } else {
                newContent.append(b)
            }
        }
        guard !rescued.isEmpty else { return msg }
        msg["content"] = newContent + rescued
        msg["stop_reason"] = "tool_use"
        return msg
    }

    /// Render an Anthropic message dict as the SSE byte stream Claude Code
    /// consumes (message_start → per-block start/delta/stop → message_delta →
    /// message_stop). Used after rescuing so the agent sees a clean stream.
    static func sse(message: [String: Any]) -> Data {
        var out = ""
        func ev(_ type: String, _ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            out += "event: \(type)\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        }
        let mid = message["id"] as? String ?? "msg_" + UUID().uuidString.prefix(24)
        let usage = message["usage"] as? [String: Any] ?? ["input_tokens": 0, "output_tokens": 0]
        ev("message_start", ["type": "message_start", "message": [
            "type": "message", "id": mid, "role": "assistant",
            "model": message["model"] as? String ?? "",
            "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": usage]])
        let content = message["content"] as? [[String: Any]] ?? []
        for (i, b) in content.enumerated() {
            let type = b["type"] as? String
            if type == "text" {
                ev("content_block_start", ["type": "content_block_start", "index": i,
                    "content_block": ["type": "text", "text": ""]])
                ev("content_block_delta", ["type": "content_block_delta", "index": i,
                    "delta": ["type": "text_delta", "text": b["text"] as? String ?? ""]])
            } else if type == "tool_use" {
                ev("content_block_start", ["type": "content_block_start", "index": i,
                    "content_block": ["type": "tool_use", "id": b["id"] as? String ?? "",
                                      "name": b["name"] as? String ?? "", "input": [:]]])
                let input = b["input"] ?? [:]
                let pj = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                ev("content_block_delta", ["type": "content_block_delta", "index": i,
                    "delta": ["type": "input_json_delta", "partial_json": pj]])
            }
            ev("content_block_stop", ["type": "content_block_stop", "index": i])
        }
        ev("message_delta", ["type": "message_delta",
            "delta": ["stop_reason": message["stop_reason"] as? String ?? "end_turn", "stop_sequence": NSNull()],
            "usage": usage])
        ev("message_stop", ["type": "message_stop"])
        return Data(out.utf8)
    }

    // MARK: - OpenAI chat/completions (Grok)

    /// Promote a tool call leaked into `choices[0].message.content` to
    /// `message.tool_calls` (OpenAI shape). No-op when tool_calls is present.
    static func repairChat(_ resp: [String: Any], toolNames: Set<String> = []) -> [String: Any] {
        var r = resp
        guard var choices = r["choices"] as? [[String: Any]], !choices.isEmpty else { return r }
        var choice = choices[0]
        var message = choice["message"] as? [String: Any] ?? [:]
        if message["tool_calls"] != nil { return r }
        guard let content = message["content"] as? String else { return r }
        let (clean, blocks) = rescue(text: content, toolNames: toolNames)
        guard !blocks.isEmpty else { return r }
        message["tool_calls"] = blocks.map { b in
            ["id": b["id"] ?? "call_x", "type": "function",
             "function": ["name": b["name"] ?? "", "arguments": argsString(b["input"])]]
        }
        message["content"] = clean.isEmpty ? NSNull() : clean
        choice["message"] = message
        choice["finish_reason"] = "tool_calls"
        choices[0] = choice
        r["choices"] = choices
        return r
    }

    /// Render an OpenAI chat.completion as the SSE chunk stream the client
    /// (Grok / OpenAI-compatible) expects, terminated with `[DONE]`.
    static func chatSSE(_ resp: [String: Any]) -> Data {
        var out = ""
        let id = resp["id"] as? String ?? "chatcmpl-" + UUID().uuidString.prefix(8)
        let model = resp["model"] as? String ?? ""
        let created = resp["created"] as? Int ?? 0
        func chunk(_ delta: [String: Any], _ finish: Any) {
            let obj: [String: Any] = ["id": id, "object": "chat.completion.chunk",
                "created": created, "model": model,
                "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
            let d = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            out += "data: \(d)\n\n"
        }
        let choice = (resp["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        chunk(["role": "assistant"], NSNull())
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for (i, tc) in toolCalls.enumerated() {
                let fn = tc["function"] as? [String: Any] ?? [:]
                chunk(["tool_calls": [["index": i, "id": tc["id"] ?? "", "type": "function",
                    "function": ["name": fn["name"] ?? "", "arguments": ""]]]], NSNull())
                chunk(["tool_calls": [["index": i, "function": ["arguments": fn["arguments"] ?? "{}"]]]], NSNull())
            }
            chunk([:], "tool_calls")
        } else {
            if let text = message["content"] as? String { chunk(["content": text], NSNull()) }
            chunk([:], choice["finish_reason"] as? String ?? "stop")
        }
        out += "data: [DONE]\n\n"
        return Data(out.utf8)
    }

    // MARK: - OpenAI Responses API (Codex)

    /// Promote a tool call leaked into a `message`/`output_text` output item to
    /// a `function_call` output item. No-op when a function_call is present.
    static func repairResponses(_ resp: [String: Any], toolNames: Set<String> = []) -> [String: Any] {
        var r = resp
        guard let output = r["output"] as? [[String: Any]] else { return r }
        if output.contains(where: { ($0["type"] as? String) == "function_call" }) { return r }
        var texts: [[String: Any]] = []
        var calls: [[String: Any]] = []
        var rescued = false
        for item in output {
            guard (item["type"] as? String) == "message",
                  let content = item["content"] as? [[String: Any]] else { texts.append(item); continue }
            var keptParts: [[String: Any]] = []
            for c in content {
                guard (c["type"] as? String) == "output_text" else { keptParts.append(c); continue }
                let (clean, blocks) = rescue(text: c["text"] as? String ?? "", toolNames: toolNames)
                for b in blocks {
                    rescued = true
                    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                    calls.append(["type": "function_call", "id": "fc_\(suffix)", "call_id": "call_\(suffix)",
                                  "name": b["name"] ?? "", "arguments": argsString(b["input"]), "status": "completed"])
                }
                if !clean.isEmpty { keptParts.append(["type": "output_text", "text": clean, "annotations": []]) }
            }
            if !keptParts.isEmpty { var m = item; m["content"] = keptParts; texts.append(m) }
        }
        guard rescued else { return r }
        r["output"] = texts + calls   // any surviving text first, then the calls
        return r
    }

    /// Render a Responses object as the typed SSE event stream Codex expects:
    /// output_item.added → (function_call_arguments.delta/done | output_text)
    /// → output_item.done, bracketed by response.created / response.completed.
    static func responsesSSE(_ resp: [String: Any]) -> Data {
        var out = ""
        var seq = 0
        func ev(_ type: String, _ payload: [String: Any]) {
            var p = payload; p["type"] = type; p["sequence_number"] = seq; seq += 1
            let d = (try? JSONSerialization.data(withJSONObject: p)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            out += "event: \(type)\ndata: \(d)\n\n"
        }
        // A minimal in-progress response envelope (no output yet).
        var envelope = resp
        envelope["output"] = []
        envelope["status"] = "in_progress"
        ev("response.created", ["response": envelope])
        ev("response.in_progress", ["response": envelope])
        let output = resp["output"] as? [[String: Any]] ?? []
        for (i, item) in output.enumerated() {
            ev("response.output_item.added", ["output_index": i, "item": item])
            let itemID = item["id"] as? String ?? "item_\(i)"
            if (item["type"] as? String) == "function_call" {
                let args = item["arguments"] as? String ?? "{}"
                ev("response.function_call_arguments.delta", ["item_id": itemID, "output_index": i, "delta": args])
                ev("response.function_call_arguments.done", ["item_id": itemID, "output_index": i, "arguments": args])
            } else if (item["type"] as? String) == "message" {
                let parts = item["content"] as? [[String: Any]] ?? []
                for (pi, part) in parts.enumerated() where (part["type"] as? String) == "output_text" {
                    let text = part["text"] as? String ?? ""
                    ev("response.content_part.added", ["item_id": itemID, "output_index": i, "content_index": pi,
                        "part": ["type": "output_text", "text": "", "annotations": []]])
                    ev("response.output_text.delta", ["item_id": itemID, "output_index": i, "content_index": pi, "delta": text])
                    ev("response.output_text.done", ["item_id": itemID, "output_index": i, "content_index": pi, "text": text])
                    ev("response.content_part.done", ["item_id": itemID, "output_index": i, "content_index": pi,
                        "part": ["type": "output_text", "text": text, "annotations": []]])
                }
            }
            ev("response.output_item.done", ["output_index": i, "item": item])
        }
        var done = resp; done["status"] = "completed"
        // Codex requires `total_tokens` in the completed usage or it fails to
        // parse ResponseCompleted and disconnects the stream.
        var u = (done["usage"] as? [String: Any]) ?? ["input_tokens": 0, "output_tokens": 0]
        if u["total_tokens"] == nil {
            u["total_tokens"] = ((u["input_tokens"] as? Int) ?? 0) + ((u["output_tokens"] as? Int) ?? 0)
        }
        done["usage"] = u
        ev("response.completed", ["response": done])
        return Data(out.utf8)
    }

    /// Serialize a tool-call input value to the JSON *string* OpenAI/Responses
    /// tool calls carry in their `arguments` field.
    private static func argsString(_ input: Any?) -> String {
        let obj = input ?? [:]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - Leaked-call patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let extract: (NSTextCheckingResult, NSString) -> (name: String, input: Any)?
    }

    private static func parseJSONObject(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d), obj is [String: Any] else { return nil }
        return obj
    }

    /// Rescue bare `{"name":…,"arguments"/"parameters":…}` JSON-object tool calls
    /// (often wrapped in a ```json fence) — the form many quantized models emit
    /// that the regex specs miss. Regex can't match nested-brace JSON, so scan
    /// for balanced top-level `{…}` spans (string-aware), parse each, and keep
    /// the ones shaped like a tool call. Returns the text with those spans
    /// removed plus the recovered `tool_use` blocks.
    static func rescueBareJSON(_ text: String) -> (cleaned: String, blocks: [[String: Any]]) {
        var blocks: [[String: Any]] = []
        let chars = Array(text)
        var spans: [(Int, Int)] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, j = i, inStr = false, esc = false
            while j < chars.count {
                let c = chars[j]
                if inStr {
                    if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                } else if c == "\"" { inStr = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard depth == 0, j < chars.count else { i += 1; continue }
            let sub = String(chars[i...j])
            if let obj = parseJSONObject(sub) as? [String: Any],
               let name = obj["name"] as? String, !name.isEmpty,
               let rawArgs = obj["arguments"] ?? obj["parameters"] {
                var input: Any = rawArgs
                if let s = input as? String, let parsed = parseJSONObject(s) { input = parsed }
                blocks.append([
                    "type": "tool_use",
                    "id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                    "name": name, "input": input])
                spans.append((i, j))
            }
            i = j + 1
        }
        var out = chars
        for (s, e) in spans.reversed() { out.removeSubrange(s...e) }
        return (String(out), blocks)
    }

    /// Rescue `<ToolName attr="val" …/>` element tool calls — the element name is
    /// the tool and the attributes are the parameters (values often HTML-entity
    /// encoded). Only elements named like a declared tool are converted, so
    /// ordinary XML/HTML in prose isn't misread as a call.
    static func rescueXMLElement(_ text: String, toolNames: Set<String>) -> (cleaned: String, blocks: [[String: Any]]) {
        guard let re = try? NSRegularExpression(
            pattern: #"<([A-Za-z][\w-]*)\b([^>]*?)/?>"#, options: [.dotMatchesLineSeparators]) else {
            return (text, [])
        }
        let attrRe = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*"([^"]*)""#,
                                              options: [.dotMatchesLineSeparators])
        var blocks: [[String: Any]] = []
        var cleaned = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: cleaned.length)).reversed() {
            guard m.numberOfRanges >= 3 else { continue }
            let name = cleaned.substring(with: m.range(at: 1))
            guard toolNames.contains(name) else { continue }
            let attrsStr = cleaned.substring(with: m.range(at: 2))
            let ans = attrsStr as NSString
            var input: [String: Any] = [:]
            attrRe?.matches(in: attrsStr, range: NSRange(location: 0, length: ans.length)).forEach { a in
                guard a.numberOfRanges >= 3 else { return }
                input[ans.substring(with: a.range(at: 1))] = htmlDecode(ans.substring(with: a.range(at: 2)))
            }
            guard !input.isEmpty else { continue }
            blocks.insert(["type": "tool_use",
                "id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                "name": name, "input": input], at: 0)
            cleaned = cleaned.replacingCharacters(in: m.range, with: "") as NSString
        }
        return (cleaned as String, blocks)
    }

    /// Rescue Qwen3-Coder native function calls:
    /// `<function=Name>\n<parameter=key>value</parameter>…\n</function>`. Values
    /// are raw (newlines/quotes/`<`) and delimited by the closing tags. Gated on
    /// the request's declared tools when known.
    static func rescueQwenFunctionCalls(_ text: String, toolNames: Set<String>) -> (cleaned: String, blocks: [[String: Any]]) {
        guard let fnRe = try? NSRegularExpression(
            pattern: #"<function=([^>\s]+)>(.*?)</function>"#, options: [.dotMatchesLineSeparators]) else {
            return (text, [])
        }
        let paramRe = try? NSRegularExpression(
            pattern: #"<parameter=([^>\s]+)>(.*?)</parameter>"#, options: [.dotMatchesLineSeparators])
        var blocks: [[String: Any]] = []
        var cleaned = text as NSString
        for m in fnRe.matches(in: cleaned as String, range: NSRange(location: 0, length: cleaned.length)).reversed() {
            guard m.numberOfRanges >= 3 else { continue }
            let name = cleaned.substring(with: m.range(at: 1))
            if !toolNames.isEmpty && !toolNames.contains(name) { continue }
            let body = cleaned.substring(with: m.range(at: 2))
            let bns = body as NSString
            var input: [String: Any] = [:]
            paramRe?.matches(in: body, range: NSRange(location: 0, length: bns.length)).forEach { p in
                guard p.numberOfRanges >= 3 else { return }
                let key = bns.substring(with: p.range(at: 1))
                var val = bns.substring(with: p.range(at: 2))
                // Strip one leading/trailing newline the format adds around values.
                if val.hasPrefix("\n") { val.removeFirst() }
                if val.hasSuffix("\n") { val.removeLast() }
                input[key] = val
            }
            guard !input.isEmpty else { continue }
            blocks.insert(["type": "tool_use",
                "id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                "name": name, "input": input], at: 0)
            cleaned = cleaned.replacingCharacters(in: m.range, with: "") as NSString
        }
        return (cleaned as String, blocks)
    }

    private static func htmlDecode(_ s: String) -> String {
        var r = s
        // &amp; last so we don't double-decode (e.g. &amp;lt; -> &lt; -> <).
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                       ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }

    private static let patterns: [Pattern] = {
        let opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        var pats: [Pattern] = []
        // <function name="X" arguments='{json}'>  (also fenced in ```xml)
        if let re = try? NSRegularExpression(
            pattern: #"<function\s+name=["']([^"']+)["']\s+arguments=['"](\{.*?\})['"]\s*/?>"#, options: opts) {
            pats.append(Pattern(regex: re) { m, ns in
                guard m.numberOfRanges >= 3,
                      let input = parseJSONObject(ns.substring(with: m.range(at: 2))) else { return nil }
                return (ns.substring(with: m.range(at: 1)), input)
            })
        }
        // [{"name":"X","parameters":{json}}](...)
        if let re = try? NSRegularExpression(
            pattern: #"\[\s*\{\s*["']name["']\s*:\s*["']([^"']+)["']\s*,\s*["']parameters["']\s*:\s*(\{.*?\})\s*\}\s*\]"#, options: opts) {
            pats.append(Pattern(regex: re) { m, ns in
                guard m.numberOfRanges >= 3,
                      let input = parseJSONObject(ns.substring(with: m.range(at: 2))) else { return nil }
                return (ns.substring(with: m.range(at: 1)), input)
            })
        }
        // <tool_call>{"name":"X","arguments":{json}}</tool_call>
        if let re = try? NSRegularExpression(
            pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#, options: opts) {
            pats.append(Pattern(regex: re) { m, ns in
                guard m.numberOfRanges >= 2,
                      let obj = parseJSONObject(ns.substring(with: m.range(at: 1))) as? [String: Any],
                      let name = obj["name"] as? String else { return nil }
                var input: Any = obj["arguments"] ?? obj["parameters"] ?? [:]
                if let s = input as? String, let parsed = parseJSONObject(s) { input = parsed }
                return (name, input)
            })
        }
        return pats
    }()
}
