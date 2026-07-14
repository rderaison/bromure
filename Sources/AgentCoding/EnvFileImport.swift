import Foundation

/// Parses a `.env` file (or a `.bashrc`-style shell file, restricted to literal
/// assignments) and classifies each variable against the credential types
/// Bromure Agentic Coding recognizes. Recognized names route to their typed
/// slot (an agent API key, a git token, AWS keys, …); unrecognized names are
/// surfaced so the user can scope them by host and import them as manual
/// tokens.
///
/// The parser deliberately does NOT evaluate shell: it reads plain literal
/// assignments only, so it can safely be pointed at a real `~/.bashrc` without
/// running anything. Values that need interpolation (`$VAR`) or command
/// substitution (`$(…)` / backticks) are skipped rather than imported wrong.
enum EnvFileImport {

    /// One `KEY=VALUE` assignment recovered from the file.
    struct ParsedVar: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let value: String
    }

    /// Where a recognized variable belongs.
    enum Slot: Equatable {
        case toolKey(Profile.Tool)    // ANTHROPIC/OPENAI/XAI API keys
        case gitToken(host: String)   // GH_TOKEN → github.com, GITLAB_TOKEN → gitlab.com
        case digitalOcean
        case linear
        case awsAccessKeyID
        case awsSecretAccessKey
        case awsSessionToken
    }

    /// The canonical recognizer: env-var NAME → slot. Consolidates the mappings
    /// otherwise scattered across `Profile.Tool.apiKeyEnvVar`, SessionDisk's
    /// git/DigitalOcean/Linear rules, and `SessionTokenPlan.hostScope`.
    static func slot(forName rawName: String) -> Slot? {
        switch rawName.uppercased() {
        case "ANTHROPIC_API_KEY":                          return .toolKey(.claude)
        case "OPENAI_API_KEY":                             return .toolKey(.codex)
        case "XAI_API_KEY":                                return .toolKey(.grok)
        case "GH_TOKEN", "GITHUB_TOKEN":                   return .gitToken(host: "github.com")
        case "GITLAB_TOKEN", "GLAB_TOKEN":                 return .gitToken(host: "gitlab.com")
        case "DIGITALOCEAN_ACCESS_TOKEN", "DIGITALOCEAN_TOKEN", "DO_TOKEN": return .digitalOcean
        case "LINEAR_API_KEY":                             return .linear
        case "AWS_ACCESS_KEY_ID":                          return .awsAccessKeyID
        case "AWS_SECRET_ACCESS_KEY":                      return .awsSecretAccessKey
        case "AWS_SESSION_TOKEN":                          return .awsSessionToken
        default:                                           return nil
        }
    }

    /// The destination host(s) a recognized slot authenticates to — for display,
    /// and to pre-fill scopes. (AWS is SigV4-signed, not a header swap, so its
    /// host is informational only.)
    static func hosts(for slot: Slot) -> [String] {
        switch slot {
        case .toolKey(.claude):  return ["anthropic.com"]
        case .toolKey(.codex):   return ["openai.com"]
        case .toolKey(.grok):    return ["x.ai"]
        case .gitToken(let host): return [host]
        case .digitalOcean:      return ["digitalocean.com"]
        case .linear:            return ["linear.app"]
        case .awsAccessKeyID, .awsSecretAccessKey, .awsSessionToken: return ["amazonaws.com"]
        }
    }

    /// A short human label for a slot, used in the import review UI.
    static func displayName(for slot: Slot) -> String {
        switch slot {
        case .toolKey(let t):    return "\(t.displayName) API key"
        case .gitToken(let host): return "Git token (\(host))"
        case .digitalOcean:      return "DigitalOcean token"
        case .linear:            return "Linear API key"
        case .awsAccessKeyID:    return "AWS access key ID"
        case .awsSecretAccessKey: return "AWS secret access key"
        case .awsSessionToken:   return "AWS session token"
        }
    }

    // MARK: - Parser

    /// Parse literal `KEY=VALUE` / `export KEY=VALUE` assignments from `text`.
    /// Later assignments win (shell semantics), so a re-export collapses to its
    /// last value. Non-assignment lines, comments, invalid names, and values
    /// that would need shell evaluation are skipped.
    static func parse(_ text: String) -> [ParsedVar] {
        var byName: [String: String] = [:]
        var order: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Strip a leading `export ` (and the rarer `declare -x `).
            for prefix in ["export ", "declare -x "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard EnvironmentVariable.isValidName(name) else { continue }
            guard let value = literalValue(String(line[line.index(after: eq)...])) else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name] = value
        }
        return order.map { ParsedVar(name: $0, value: byName[$0] ?? "") }
    }

    /// The literal value of an assignment's right-hand side, or nil if it can
    /// only be resolved by running a shell (interpolation / substitution).
    private static func literalValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return "" }
        if let quote = v.first, quote == "'" || quote == "\"" {
            // Quoted: take content up to the matching closing quote.
            guard let close = v.dropFirst().firstIndex(of: quote) else { return nil }
            let inner = String(v[v.index(after: v.startIndex)..<close])
            if quote == "\"" {
                // Double quotes interpolate — refuse anything that would expand.
                if inner.contains("$") || inner.contains("`") { return nil }
                return inner.replacingOccurrences(of: "\\\"", with: "\"")
                            .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return inner   // single quotes are fully literal
        }
        // Unquoted: drop a trailing ` # comment`, then refuse interpolation.
        var bare = v
        if let hash = bare.range(of: " #") {
            bare = String(bare[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if bare.contains("$") || bare.contains("`") { return nil }
        return bare
    }

    // MARK: - Classification

    /// A parsed variable split into "recognized" (routes to a typed slot) and
    /// "unrecognized" (import as a manual token with user-chosen host scopes).
    struct Classification {
        var recognized: [(slot: Slot, variable: ParsedVar)] = []
        var unrecognized: [ParsedVar] = []
    }

    static func classify(_ vars: [ParsedVar]) -> Classification {
        var out = Classification()
        for v in vars where !v.value.isEmpty {
            if let s = slot(forName: v.name) { out.recognized.append((s, v)) }
            else { out.unrecognized.append(v) }
        }
        return out
    }
}
