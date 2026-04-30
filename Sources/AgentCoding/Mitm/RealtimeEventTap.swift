import Foundation

/// Streaming event extractor for OpenAI Realtime / Codex WebSocket
/// sessions. Attached as the upstream→client `onMessage` hook on a
/// `WSTraceCollector`, it watches every assembled text frame and, on
/// `response.completed`, emits BAC `llm.request` / `tool.use` /
/// `file.*` / `command.run` events through `BACEventEmitter` —
/// matching what `LLMEventExtractor.emit` produces for HTTP exchanges,
/// but mid-session instead of at WS close.
///
/// One instance per WebSocket connection. `streamedAnyEvents` lets the
/// caller decide whether to skip the close-time
/// `LLMEventExtractor.emit` so the final assistant turn isn't
/// double-counted.
final class RealtimeEventTap: @unchecked Sendable {
    let profileID: UUID
    let host: String
    let path: String
    let statusCode: Int
    private let lock = NSLock()
    private(set) var streamedResponseCount = 0

    init(profileID: UUID, host: String, path: String, statusCode: Int) {
        self.profileID = profileID
        self.host = host
        self.path = path
        self.statusCode = statusCode
    }

    /// True once any `response.completed` has been streamed. Read by
    /// the caller to gate the close-time `LLMEventExtractor.emit`.
    var streamedAnyEvents: Bool {
        lock.lock(); defer { lock.unlock() }
        return streamedResponseCount > 0
    }

    func handle(_ message: WSMessage) {
        guard message.kind == .text,
              !message.payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: message.payload)
                            as? [String: Any],
              let type = obj["type"] as? String,
              type == "response.completed",
              let response = obj["response"] as? [String: Any]
        else { return }

        let model = response["model"] as? String
        let usage = response["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int
        let outputTokens = usage?["output_tokens"] as? Int
        let cachedTokens = (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        let respID = response["id"] as? String

        BACDebug.log("[mitm/wsStream]",
                     "response.completed host=\(host) model=\(model ?? "?") inputTokens=\(inputTokens ?? -1) outputTokens=\(outputTokens ?? -1) responseId=\(respID ?? "?")")

        var llmData: [String: AnyJSON] = [
            "provider": .string("openai"),
            "host": .string(host),
            "path": .string(path),
            "status_code": .int(statusCode),
            "transport": .string("websocket"),
        ]
        if let model { llmData["model"] = .string(model) }
        if let inputTokens { llmData["input_tokens"] = .int(inputTokens) }
        if let outputTokens { llmData["output_tokens"] = .int(outputTokens) }
        if let cachedTokens { llmData["cache_read_input_tokens"] = .int(cachedTokens) }
        if let respID { llmData["openai_response_id"] = .string(respID) }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID,
            eventType: "llm.request",
            eventData: llmData)

        // Walk `response.output[]` for function_call items. The
        // Realtime API populates the final state on `response.completed`
        // — name + arguments are fully assembled.
        let output = (response["output"] as? [[String: Any]]) ?? []
        var toolCount = 0
        for item in output {
            guard (item["type"] as? String) == "function_call" else { continue }
            let name = (item["name"] as? String) ?? "tool"
            let args = (item["arguments"] as? String) ?? ""
            toolCount += 1

            BACEventEmitter.shared.emitDetached(
                profileID: profileID,
                eventType: "tool.use",
                eventData: [
                    "tool_name": .string(name),
                    "input_summary": .string(Self.summarize(args, max: 240)),
                ])

            if LLMEventExtractor.isFileReadTool(name) {
                if let p = LLMEventExtractor.extractPath(from: args) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "file.read",
                        eventData: ["path": .string(p), "tool": .string(name)])
                } else {
                    BACDebug.log("[mitm/wsStream]",
                                 "no path extracted name=\(name) inputBytes=\(args.utf8.count)")
                }
            } else if LLMEventExtractor.isFileWriteTool(name) {
                if let p = LLMEventExtractor.extractPath(from: args) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "file.write",
                        eventData: ["path": .string(p), "tool": .string(name)])
                } else {
                    BACDebug.log("[mitm/wsStream]",
                                 "no path extracted name=\(name) inputBytes=\(args.utf8.count)")
                }
            } else if LLMEventExtractor.isCommandTool(name) {
                if let cmd = LLMEventExtractor.extractCommand(from: args) {
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID,
                        eventType: "command.run",
                        eventData: [
                            "command": .string(cmd),
                            "tool": .string(name),
                        ])
                } else {
                    BACDebug.log("[mitm/wsStream]",
                                 "no command extracted name=\(name) inputBytes=\(args.utf8.count)")
                }
            } else {
                BACDebug.log("[mitm/wsStream]",
                             "unknown tool name=\(name) inputBytes=\(args.utf8.count) — only generic tool.use emitted")
            }
        }

        BACDebug.log("[mitm/wsStream]",
                     "emit done host=\(host) tools=\(toolCount)")

        lock.lock()
        streamedResponseCount += 1
        lock.unlock()
    }

    private static func summarize(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }
}
