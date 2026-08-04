import Foundation

/// The agent CLIs' own configuration — Claude Code, Codex, Grok, Kimi.
///
/// The credential detectors already lift each agent's *login*. What they leave
/// behind is everything that makes the agent yours: the model and effort you
/// picked, permission defaults, custom slash commands, subagents, output
/// styles, and the global CLAUDE.md / AGENTS.md you've been refining for
/// months. A fresh VM without those is a stranger's setup.
///
/// This walks the agent's config directory rather than naming files one by one.
/// Naming them means guessing, and guessing wrong fails silently — a layout
/// that shifts by a release would quietly import nothing. A denylist fails the
/// safe way instead: something new shows up and gets carried, and the things
/// that must never travel are named explicitly.
///
/// Three kinds of things are kept out:
///
///   - **Credentials.** `auth.json`, `.credentials.json`, Kimi's
///     `credentials/`. Those have a typed path that routes them through the
///     proxy, where the VM only ever sees a fake.
///   - **State and history.** Sessions, transcripts, shell snapshots, caches,
///     todos. Large, intensely personal, and meaningless in another machine's
///     home. `~/.claude/projects` alone is usually the biggest thing there.
///   - **Anything not plainly text.** Binaries and installed plugin trees are
///     re-fetchable and not configuration.
enum AgentConfigScan {

    /// One agent's config directory and what must never leave it.
    struct Source {
        let tool: Profile.Tool
        /// Home-relative directory, e.g. ".claude".
        let dir: String
        /// Names (any depth) that are never carried.
        let deny: Set<String>
    }

    static let sources: [Source] = [
        Source(tool: .claude, dir: ".claude", deny: [
            // Credentials — the typed path owns these.
            ".credentials.json", "credentials",
            // History, state, caches.
            "projects", "sessions", "session-env", "shell-snapshots", "history.jsonl",
            "file-history", "cache", "caches", "uploads", "downloads", "paste-cache",
            "backups", "tasks", "todos", "statsig", "ide", "logs", "log",
            "mcp-needs-auth-cache.json", ".last-update-result.json", ".last-cleanup",
            // Installed plugin trees: re-fetchable, and hundreds of files.
            "plugins",
        ]),
        Source(tool: .codex, dir: ".codex", deny: [
            "auth.json", "sessions", "history.jsonl", "history", "log", "logs", "cache",
        ]),
        Source(tool: .grok, dir: ".grok", deny: [
            "auth.json", "sessions", "history.jsonl", "history", "log", "logs", "cache",
        ]),
        Source(tool: .kimi, dir: ".kimi-code", deny: [
            "credentials", "sessions", "history.jsonl", "history", "log", "logs", "cache",
        ]),
    ]

    /// Extensions worth carrying. Everything an agent treats as configuration
    /// is one of these; anything else is data or a binary.
    private static let textExtensions: Set<String> = [
        "md", "json", "toml", "yaml", "yml", "txt", "jsonc",
    ]

    /// Caps, so a pathological home can't push megabytes of someone's notes
    /// into a workspace profile (which is JSON, and syncs to remote hosts).
    private static let maxFiles = 64
    private static let maxFileBytes = 64 * 1024
    private static let maxTotalBytes = 512 * 1024

    struct Result {
        var files: [ImportedConfigFile] = []
        var strippedSecrets = 0
        /// Files skipped for being too large or too numerous, so the UI can
        /// say so rather than quietly under-importing.
        var skipped = 0
    }

    /// Walk one agent's config dir. Returns nil when there's nothing to carry.
    static func scan(_ source: Source, home: URL) -> Result? {
        let root = home.appendingPathComponent(source.dir, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        var r = Result()
        var total = 0
        let rootPath = root.standardizedFileURL.path

        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var paths: [(URL, String)] = []
        for case let url as URL in walker {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let rel = String(full.dropFirst(rootPath.count + 1))
            // Denied at any depth: `projects` matches `projects/foo/bar.json`.
            let segments = rel.split(separator: "/").map(String.init)
            if segments.contains(where: { source.deny.contains($0) }) {
                if segments.count == 1 { walker.skipDescendants() }
                continue
            }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if (vals?.fileSize ?? 0) > maxFileBytes { r.skipped += 1; continue }
            paths.append((url, rel))
        }

        // Deterministic order, and a stable notion of "the first 64".
        for (url, rel) in paths.sorted(by: { $0.1 < $1.1 }) {
            if r.files.count >= maxFiles || total >= maxTotalBytes { r.skipped += 1; continue }
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8) else { continue }
            let clean = SecretRedact.redact(body, pathExtension: url.pathExtension.lowercased())
            guard !clean.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            total += clean.text.utf8.count
            r.strippedSecrets += clean.stripped
            r.files.append(ImportedConfigFile(
                path: "\(source.dir)/\(rel)", contents: clean.text,
                strippedSecrets: clean.stripped))
        }
        return r.files.isEmpty ? nil : r
    }
}

/// Removes secrets from files carried over whole.
///
/// Structured files (JSON/TOML/YAML) are filtered by KEY — an `env` block with
/// `ANTHROPIC_API_KEY` in it is the common case, and the key name is a reliable
/// signal. Prose (Markdown, text) is filtered by VALUE instead, matching only
/// high-confidence token shapes: dropping every line of someone's CLAUDE.md
/// that happens to contain the word "token" would mangle the document to guard
/// against something that mostly doesn't happen.
enum SecretRedact {

    struct Result {
        var text: String
        var stripped: Int
    }

    /// Key names that hold secrets. Matched case-insensitively as substrings,
    /// so `ANTHROPIC_API_KEY`, `apiKey` and `github_token` all hit.
    private static let secretKeyMarkers = [
        "token", "secret", "password", "passwd", "apikey", "api_key", "api-key",
        "credential", "authorization", "private_key", "privatekey", "access_key",
    ]

    /// Token shapes distinctive enough to match inside prose without false hits.
    private static let tokenPatterns = [
        "sk-ant-", "sk-proj-", "sk-or-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "github_pat_", "glpat-", "xai-", "AKIA", "ASIA", "npm_", "dop_v1_",
        "pypi-AgEIcHlwaS5vcmc", "AIza",
    ]

    static func redact(_ body: String, pathExtension ext: String) -> Result {
        switch ext {
        case "json", "jsonc":  return redactJSON(body) ?? redactByKey(body)
        case "toml", "yaml", "yml": return redactByKey(body)
        default:               return redactProse(body)
        }
    }

    /// Structured JSON: drop secret-valued keys anywhere in the tree, keeping
    /// the shape intact so the file still parses on the other side.
    private static func redactJSON(_ body: String) -> Result? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data,
                                                          options: [.fragmentsAllowed])
        else { return nil }
        var count = 0
        let cleaned = walk(obj, &count)
        guard let out = try? JSONSerialization.data(
            withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: out, encoding: .utf8) else { return nil }
        return Result(text: text + "\n", stripped: count)
    }

    private static func walk(_ value: Any, _ count: inout Int) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if isSecretKey(k), !(v is [String: Any]), !(v is [Any]) {
                    count += 1
                    continue
                }
                out[k] = walk(v, &count)
            }
            return out
        }
        if let arr = value as? [Any] { return arr.map { walk($0, &count) } }
        if let s = value as? String, looksLikeToken(s) {
            count += 1
            return ""
        }
        return value
    }

    /// Line-oriented `key = value` / `key: value` filtering for TOML and YAML.
    private static func redactByKey(_ body: String) -> Result {
        var out: [String] = []
        var count = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { out.append(line); continue }
            let sepIndex = trimmed.firstIndex(of: "=") ?? trimmed.firstIndex(of: ":")
            if let i = sepIndex {
                let key = String(trimmed[..<i])
                let value = String(trimmed[trimmed.index(after: i)...])
                if isSecretKey(key) || looksLikeToken(value) { count += 1; continue }
            } else if looksLikeToken(trimmed) {
                count += 1; continue
            }
            out.append(line)
        }
        return Result(text: out.joined(separator: "\n"), stripped: count)
    }

    /// Prose: only lines carrying a recognizable token shape come out.
    private static func redactProse(_ body: String) -> Result {
        var out: [String] = []
        var count = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if looksLikeToken(line) { count += 1; continue }
            out.append(line)
        }
        return Result(text: out.joined(separator: "\n"), stripped: count)
    }

    static func isSecretKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            .lowercased()
        return secretKeyMarkers.contains { k.contains($0) }
    }

    static func looksLikeToken(_ s: String) -> Bool {
        tokenPatterns.contains { s.contains($0) }
    }
}
