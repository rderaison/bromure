import Foundation

// Turns a parsed `Conversation` (built by the existing `ConversationParser`
// for the trace inspector's chat view) into the structured BAC events
// the admin UI consumes — plus a small re-parse of the raw response body
// to extract all four Anthropic token counters (the existing parser only
// kept input/output, but admins want cache hit rate).
//
// Events emitted per AI exchange:
//   llm.request            — model + tokens + latency
//   tool.use               — every tool_use block (generic envelope)
//   file.read              — when the tool name is Read / View / etc.
//   file.write             — Write / Edit / MultiEdit / NotebookEdit
//   command.run            — Bash / Shell tool calls
//
// We do NOT emit raw prompts. Admin telemetry is "what did the AI do"
// (which file paths, which commands, how many tokens) — never "what
// did the user ask". The credential-use events (token_swap, ssh_sign,
// aws_sign) come from a different code path (the MITM hooks) so that
// audit trail exists even when the AI body wasn't captured.

enum LLMEventExtractor {
    /// Emit BAC events for one AI exchange. Caller already produced
    /// the parsed Conversation via ConversationParser.parse(...) and
    /// has the raw response body in hand for token-counter extraction.
    /// `latencyMs` is the wall-clock CONNECT-to-response time the
    /// proxy already measured; just forward it.
    static func emit(
        profileID: UUID,
        host: String,
        path: String,
        statusCode: Int,
        latencyMs: Double,
        responseBody: Data?,
        conversation: Conversation,
    ) {
        let tokenT0 = Date()
        BACDebug.log("[ac/llm]",
                     "tokens parse start provider=\(conversation.provider.rawValue) bodyBytes=\(responseBody?.count ?? 0)")
        let tokens = parseTokenCounters(provider: conversation.provider, responseBody: responseBody)
        BACDebug.log("[ac/llm]",
                     "tokens parse done provider=\(conversation.provider.rawValue) input=\(tokens.inputTokens ?? -1) output=\(tokens.outputTokens ?? -1) took=\(BACDebug.ms(tokenT0))")

        // llm.request — one per exchange.
        var llmData: [String: AnyJSON] = [
            "provider": .string(conversation.provider.rawValue),
            "host": .string(host),
            "path": .string(path),
            "status_code": .int(statusCode),
            "latency_ms": .double(latencyMs),
        ]
        if let m = conversation.model { llmData["model"] = .string(m) }
        if let t = tokens.inputTokens ?? conversation.inputTokens   { llmData["input_tokens"] = .int(t) }
        if let t = tokens.outputTokens ?? conversation.outputTokens { llmData["output_tokens"] = .int(t) }
        if let t = tokens.cacheCreationInputTokens                  { llmData["cache_creation_input_tokens"] = .int(t) }
        if let t = tokens.cacheReadInputTokens                      { llmData["cache_read_input_tokens"] = .int(t) }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID,
            eventType: "llm.request",
            eventData: llmData)

        // Tool calls — walk the assistant turns of the most recent
        // exchange. Older turns from the same conversation history
        // are repeated on every API call, so emitting all of them
        // would double-count. The last assistant message in the
        // parsed Conversation is the one this exchange produced.
        guard let assistant = conversation.messages.last(where: { $0.role == .assistant })
        else {
            BACDebug.log("[ac/llm]", "no assistant turn — emit done host=\(host)")
            return
        }
        let toolBlocks = assistant.content.filter {
            if case .toolUse = $0 { return true } else { return false }
        }
        BACDebug.log("[ac/llm]",
                     "tools walk start host=\(host) blocks=\(assistant.content.count) toolBlocks=\(toolBlocks.count)")
        let toolsT0 = Date()
        defer {
            BACDebug.log("[ac/llm]",
                         "tools walk done host=\(host) took=\(BACDebug.ms(toolsT0))")
        }

        for block in assistant.content {
            guard case .toolUse(let name, let input) = block else { continue }
            let toolT0 = Date()
            BACDebug.log("[ac/llm]",
                         "tool.use emit name=\(name) inputBytes=\(input.utf8.count)")
            // Generic tool.use envelope first — useful for the
            // "tools" insights view that doesn't care about
            // file-vs-command specifics.
            BACEventEmitter.shared.emitDetached(
                profileID: profileID,
                eventType: "tool.use",
                eventData: [
                    "tool_name": .string(name),
                    "input_summary": .string(summarize(input: input, max: 240)),
                ])
            defer {
                BACDebug.log("[ac/llm]",
                             "tool.use done name=\(name) took=\(BACDebug.ms(toolT0))")
            }

            // Specialised events for the categories admins care
            // about most. Tool naming follows Claude/Codex
            // conventions — see the cases below for the canonical
            // names per provider.
            if Self.isFileReadTool(name) {
                if let p = Self.extractPath(from: input) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "file.read",
                        eventData: ["path": .string(p), "tool": .string(name)])
                } else {
                    BACDebug.log("[ac/llm]",
                                 "no path extracted name=\(name) inputBytes=\(input.utf8.count)")
                }
            } else if Self.isFileWriteTool(name) {
                if let p = Self.extractPath(from: input) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "file.write",
                        eventData: ["path": .string(p), "tool": .string(name)])
                } else {
                    BACDebug.log("[ac/llm]",
                                 "no path extracted name=\(name) inputBytes=\(input.utf8.count)")
                }
            } else if Self.isCommandTool(name) {
                if let cmd = Self.extractCommand(from: input) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "command.run",
                        eventData: [
                            "command": .string(cmd),
                            "tool": .string(name),
                        ])
                } else {
                    BACDebug.log("[ac/llm]",
                                 "no command extracted name=\(name) inputBytes=\(input.utf8.count)")
                }
            } else {
                BACDebug.log("[ac/llm]",
                             "unknown tool name=\(name) inputBytes=\(input.utf8.count) — only generic tool.use emitted")
            }
        }
    }

    // MARK: - Tool-name classification

    /// Read-the-file-system tools across providers / agent SDKs.
    static func isFileReadTool(_ name: String) -> Bool {
        switch name {
        case "Read", "ReadFile", "view", "View",
             "read_file", "list_dir", "ls", "LS",
             "Glob", "glob", "Grep", "grep",
             "str_replace_editor": return true
        default: return false
        }
    }

    /// Mutate-the-file-system tools.
    static func isFileWriteTool(_ name: String) -> Bool {
        switch name {
        case "Write", "WriteFile", "Edit", "MultiEdit", "NotebookEdit",
             "create", "Create", "str_replace",
             "write_file", "apply_patch", "edit_file": return true
        default: return false
        }
    }

    /// Run-a-shell-command tools.
    static func isCommandTool(_ name: String) -> Bool {
        switch name {
        case "Bash", "Shell", "shell", "Run", "RunCommand",
             "exec", "execute", "exec_command", "run_command",
             "container.exec": return true
        default: return false
        }
    }

    // MARK: - Input dissection
    //
    // `input` from ConversationParser is the rendered string the
    // chat-view shows (often pretty-printed JSON). We re-parse it
    // as JSON when possible, fall back to regex on the rendered
    // text for malformed shapes.

    static func extractPath(from input: String) -> String? {
        if let dict = parseInputJSON(input) {
            // Common shapes across providers:
            //   Anthropic Read / Edit / Write: file_path
            //   Codex view / read_file / write_file / apply_patch: path
            //   str_replace_editor: path or file_path
            for key in ["file_path", "path", "filename", "target_file"] {
                if let v = dict[key] as? String, !v.isEmpty { return v }
            }
        }
        return nil
    }

    static func extractCommand(from input: String) -> String? {
        guard let dict = parseInputJSON(input) else { return nil }
        for key in ["command", "cmd", "script"] {
            if let s = dict[key] as? String, !s.isEmpty {
                return summarize(input: s, max: 500)
            }
            // Codex `shell` passes command as ["bash","-lc","<cmd>"].
            // Pull the actual shell payload when we recognise that
            // shape; otherwise fall back to space-joining the array
            // so the admin still sees a meaningful preview.
            if let arr = dict[key] as? [Any] {
                let strs = arr.compactMap { $0 as? String }
                if strs.count >= 3,
                   ["bash", "/bin/bash", "sh", "/bin/sh", "zsh"].contains(strs[0]),
                   strs[1].hasPrefix("-") {
                    return summarize(input: strs[2], max: 500)
                }
                let joined = strs.joined(separator: " ")
                if !joined.isEmpty { return summarize(input: joined, max: 500) }
            }
        }
        return nil
    }

    private static func parseInputJSON(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Bound the size of free-text fields we forward. Commands and
    /// inputs can be huge (a 10kb script pasted into Bash). Cap so
    /// one runaway tool call doesn't blow the per-event size.
    private static func summarize(input: String, max: Int) -> String {
        if input.count <= max { return input }
        let prefix = input.prefix(max)
        return String(prefix) + "…"
    }

    // MARK: - Token counters
    //
    // Anthropic's Messages API exposes all four; OpenAI's Responses
    // API exposes prompt + completion + (sometimes) cached_tokens.
    // ConversationParser only kept the basic two — we re-parse the
    // response body ourselves to pick up the cache counters.

    struct TokenCounters {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?
    }

    private static func parseTokenCounters(provider: Conversation.Provider,
                                           responseBody: Data?) -> TokenCounters {
        guard let body = responseBody else { return TokenCounters() }
        switch provider {
        case .anthropic: return parseAnthropicTokens(body)
        case .openai:    return parseOpenAITokens(body)
        default:         return TokenCounters()
        }
    }

    private static func parseAnthropicTokens(_ body: Data) -> TokenCounters {
        var t = TokenCounters()
        if let usage = topLevelUsage(in: body) {
            t.inputTokens               = usage["input_tokens"] as? Int
            t.outputTokens              = usage["output_tokens"] as? Int
            t.cacheCreationInputTokens  = usage["cache_creation_input_tokens"] as? Int
            t.cacheReadInputTokens      = usage["cache_read_input_tokens"] as? Int
            return t
        }
        // SSE — Anthropic emits a `message_start` event whose payload
        // carries the input tokens (with cache breakdown), and a
        // `message_delta` whose payload carries the running output
        // count. Walk the lines and pick the highest output count we
        // see (the final delta wins).
        guard let text = String(data: body, encoding: .utf8) else { return t }
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // message_start: {"type":"message_start","message":{"usage":{...}}}
            if let msg = obj["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any] {
                t.inputTokens              = (u["input_tokens"] as? Int) ?? t.inputTokens
                t.cacheCreationInputTokens = (u["cache_creation_input_tokens"] as? Int) ?? t.cacheCreationInputTokens
                t.cacheReadInputTokens     = (u["cache_read_input_tokens"] as? Int) ?? t.cacheReadInputTokens
                if let o = u["output_tokens"] as? Int { t.outputTokens = o }
            }
            // message_delta: {"type":"message_delta","usage":{"output_tokens":N}}
            if let u = obj["usage"] as? [String: Any],
               let o = u["output_tokens"] as? Int {
                t.outputTokens = o
            }
        }
        return t
    }

    private static func parseOpenAITokens(_ body: Data) -> TokenCounters {
        var t = TokenCounters()
        if let usage = topLevelUsage(in: body) {
            t.inputTokens   = usage["prompt_tokens"] as? Int
            t.outputTokens  = usage["completion_tokens"] as? Int
            // Responses API + chat/completions both expose cached
            // tokens under prompt_tokens_details.cached_tokens when
            // automatic prompt caching kicks in.
            if let details = usage["prompt_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                t.cacheReadInputTokens = cached
            }
        }
        return t
    }

    /// Pull `usage` out of a non-streaming JSON response body.
    private static func topLevelUsage(in body: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return obj["usage"] as? [String: Any]
    }
}
