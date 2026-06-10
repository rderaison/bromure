import Foundation

/// Per-profile prompt-injection / rogue-instruction detection policy,
/// enforced host-side in the MITM proxy. Two independent detectors plus a
/// shared action to take when either fires.
///
///   1. **Source-code injection** — scores the untrusted `tool_result`
///      spans the agent ingests (file reads, web fetches, issue/PR bodies)
///      with the local PromptGuard ONNX model. Catches "ignore previous
///      instructions / exfiltrate secrets" hidden in content the agent reads.
///   2. **Rogue CLAUDE.md / rules files** — scores the agent's *authority*
///      context (auto-loaded CLAUDE.md, AGENTS.md, GROK.md, …) with the local
///      ModernBERT classifier, backstopped by the deterministic
///      `RulesFileScanner` (invisible-Unicode + capability heuristics).
///
/// Both run on-device; nothing leaves the Mac. Each requires its model to
/// be installed (downloaded from dl.bromure.io on first enable).
public struct PromptInjectionPolicy: Codable, Equatable, Sendable {

    /// What to do when a detector flags content.
    public enum Action: String, Codable, CaseIterable, Sendable {
        /// Record to the Prompt Injection log + keep going (default).
        case log
        /// Pause the request and ask the user (consent dialog).
        case ask
        /// Block the request outright (the agent sees a hard failure).
        case block

        public var displayName: String {
            switch self {
            case .log:   return NSLocalizedString("Log but continue", comment: "")
            case .ask:   return NSLocalizedString("Ask me what to do", comment: "")
            case .block: return NSLocalizedString("Block unilaterally", comment: "")
            }
        }
    }

    /// Detect prompt injection in source code / tool_result content (PromptGuard).
    public var detectSourceInjection: Bool
    /// Detect rogue instructions in CLAUDE.md and similar (ModernBERT + scanner).
    public var detectRulesInjection: Bool
    /// Shared response when either detector fires.
    public var onDetection: Action

    public init(detectSourceInjection: Bool = false,
                detectRulesInjection: Bool = false,
                onDetection: Action = .log) {
        self.detectSourceInjection = detectSourceInjection
        self.detectRulesInjection = detectRulesInjection
        self.onDetection = onDetection
    }

    /// True if either detector is on — proxy short-circuits when nothing's enabled.
    public var isActive: Bool { detectSourceInjection || detectRulesInjection }

    // MARK: - Codable (tolerant; encode only non-defaults to keep JSON small)

    enum CodingKeys: String, CodingKey {
        case detectSourceInjection, detectRulesInjection, onDetection
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectSourceInjection = try c.decodeIfPresent(Bool.self, forKey: .detectSourceInjection) ?? false
        detectRulesInjection  = try c.decodeIfPresent(Bool.self, forKey: .detectRulesInjection) ?? false
        onDetection = try c.decodeIfPresent(Action.self, forKey: .onDetection) ?? .log
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if detectSourceInjection { try c.encode(detectSourceInjection, forKey: .detectSourceInjection) }
        if detectRulesInjection  { try c.encode(detectRulesInjection, forKey: .detectRulesInjection) }
        if onDetection != .log   { try c.encode(onDetection, forKey: .onDetection) }
    }
}
