import Foundation

// MARK: - Static model suggestions (offline seed / fallback)

enum ProviderModels {
    /// Bedrock has no model listing on the bedrock-runtime endpoint, so the
    /// picker offers the ids the Claude Code and Bedrock docs use as examples
    /// (cross-region `us.` inference profiles; OpenAI-compatible GPT OSS) and
    /// the user types their own via "Custom id…" when theirs differ.
    static let bedrockPlaceholder = "us.anthropic.claude-sonnet-4-6"

    /// The full curated lineup for a provider (every tier), merged with the live
    /// list by the picker so a curated model is always selectable.
    static func allSuggestions(for provider: ModelProvider) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for tier in [ModelTier.large, .medium, .small] {
            for id in suggestions(for: provider, tier: tier) where !seen.contains(id) {
                seen.insert(id); out.append(id)
            }
        }
        return out
    }

    static func suggestions(for provider: ModelProvider, tier: ModelTier) -> [String] {
        switch provider {
        case .anthropic:
            switch tier {
            case .large:  return ["claude-opus-5", "claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-5"]
            case .medium: return ["claude-sonnet-5", "claude-sonnet-4-6", "claude-opus-5"]
            case .small:  return ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
            }
        case .openai:   return ["gpt-5.5", "gpt-5.2", "gpt-5", "gpt-4o"]
        case .xai:      return ["grok-4", "grok-4-fast", "grok-3"]
        case .zai:      return ["glm-5.3", "glm-5.3-flash", "glm-4.6"]
        case .moonshot: return ["kimi-k2.5", "kimi-k2", "kimi-k2-turbo-preview"]
        // OpenRouter's catalog is fetched live (its /models endpoint); these
        // are the ids its API docs use as examples, so the picker is never empty.
        case .openrouter: return ["anthropic/claude-sonnet-4.6", "openai/gpt-5.2"]
        case .bedrock:
            switch tier {
            case .large:  return ["us.anthropic.claude-opus-4-8", bedrockPlaceholder]
            case .medium: return [bedrockPlaceholder, "openai.gpt-oss-120b-1:0"]
            case .small:  return ["us.anthropic.claude-haiku-4-5-20251001-v1:0", "openai.gpt-oss-20b-1:0"]
            }
        case .custom:   return []
        }
    }

    static func ordered(_ live: [String], for provider: ModelProvider, tier: ModelTier) -> [String] {
        guard provider == .anthropic || provider == .bedrock else { return live }
        let hints: [String]
        switch tier {
        case .large:  hints = ["opus", "fable"]
        case .medium: hints = ["sonnet"]
        case .small:  hints = ["haiku"]
        }
        let (preferred, rest) = live.stablePartition { id in
            hints.contains { id.lowercased().contains($0) }
        }
        return preferred + rest
    }

    static func capabilities(for modelID: String) -> ModelCapabilities? {
        let id = modelID.lowercased()
        if id.hasPrefix("claude") || id.contains("anthropic/claude") || id.contains(".anthropic.claude") {
            return ModelCapabilities(contextWindow: 200_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("gpt-5") || id.hasPrefix("gpt-4") || id.hasPrefix("o4") || id.hasPrefix("o3") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("grok") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("glm") {
            return ModelCapabilities(contextWindow: 128_000, reasoning: true, inputs: [.text])
        }
        if id.hasPrefix("kimi") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: false, inputs: [.text])
        }
        return nil
    }
}

private extension Array {
    func stablePartition(_ belongsFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var a: [Element] = [], b: [Element] = []
        for e in self { if belongsFirst(e) { a.append(e) } else { b.append(e) } }
        return (a, b)
    }
}
