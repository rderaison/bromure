import Foundation

/// Forwards a prompt-injection detection to bromure.io as a
/// `prompt_injection.detection` cloud event. Enrollment-gated by
/// `BACEventEmitter` (a no-op when the Mac isn't managed or the profile is in
/// private mode), so callers can fire it unconditionally.
///
/// Unlike the local Security Log line — which carries only a short preview —
/// the cloud event includes the **whole flagged snippet**, so an admin can
/// see exactly what the agent was about to read.
enum PromptInjectionCloudEvent {
    static let type = "prompt_injection.detection"

    /// Cap the snippet so a pathological multi-MB CLAUDE.md can't blow past
    /// the ingest's 1 MiB batch ceiling. 20 KB covers any realistic rules
    /// file or tool result; `snippet_truncated` flags the rare overflow.
    static let maxSnippet = 20_000

    /// - detector: "source" (PromptGuard, tool output) or "rules" (CLAUDE.md…)
    /// - method:   "model" (ONNX classifier) or "heuristic" (RulesFileScanner)
    /// - action:   "log" | "ask" | "block" — what the profile policy did
    /// - source:   cited file path, or "tool output" / "system prompt"
    static func emit(profileID: UUID,
                     detector: String,
                     method: String,
                     action: String,
                     host: String,
                     source: String?,
                     score: Double?,
                     signals: [String],
                     toolUseId: String?,
                     snippet: String) {
        var data: [String: AnyJSON] = [
            "detector": .string(detector),
            "method": .string(method),
            "action": .string(action),
            "host": .string(host),
            "snippet": .string(String(snippet.prefix(maxSnippet))),
            "snippet_truncated": .bool(snippet.count > maxSnippet),
        ]
        data["source"] = .of(source)
        data["tool_use_id"] = .of(toolUseId)
        if let score { data["score"] = .double(score) }
        if !signals.isEmpty { data["signals"] = .array(signals.map { .string($0) }) }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: type, eventData: data)
    }
}
