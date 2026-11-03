import Foundation

/// Detector for the "rules file backdoor" threat class: malicious
/// instructions hidden in the agent's *authority* context rather than in
/// untrusted tool output.
///
/// Claude Code, Codex, and Grok auto-load their instruction files
/// (`CLAUDE.md`, `AGENTS.md`, `GROK.md`, plus nested / global variants) into
/// the **system prompt**, where the
/// model treats it as trusted direction — so a poisoned one steers the
/// agent directly, never appearing as a `tool_result`. PromptGuard is the
/// wrong lens here (a rules file is *legitimately* instructions, so it
/// would either false-positive on every project or miss calmly-worded
/// abuse). Pillar Security's disclosure showed the real-world signature:
/// instructions made invisible to a human reviewer with zero-width / bidi
/// / Unicode-tag characters, readable only by the model.
///
/// This is a dependency-free **rule pass** — no model, no new runtime —
/// run on the system-prompt instruction spans the proxy already parses.
/// It is logging-only and split by confidence:
///   - `.high`   — hidden/obfuscation Unicode (near-zero false positive;
///                 legit config files don't contain zero-width joiners),
///                 or meta-instructions that subvert the user.
///   - `.medium` — capability/exfil keywords (credential paths, pipe-to-
///                 shell, exfil verbs) that *can* be legit in a build-doc,
///                 so they're flagged for review, not asserted malicious.
///
/// The harm-classifier upgrade (Granite Guardian / a rubric judge over
/// these same spans) drops in behind `scan` later; this gets real
/// coverage of the documented attack today.
final class RulesFileScanner: @unchecked Sendable {
    static let shared = RulesFileScanner()

    typealias Severity = InstructionHeuristics.Severity
    typealias Finding = InstructionHeuristics.Finding

    private let lock = NSLock()
    /// Content hashes already logged, so the per-turn re-send of the
    /// system prompt doesn't re-flag the same file every 30 seconds.
    /// A changed file hashes differently and re-logs.
    private var seen: Set<Int> = []

    private static let debug =
        ProcessInfo.processInfo.environment["BROMURE_AC_DEBUG"] == "1"

    // MARK: - Entry point

    /// Extract instruction-file spans from the system prompt, scan each,
    /// and log any findings. No-op when nothing matches. Cheap (string
    /// scans) — safe to call inline from the trace path.
    func scanAndLog(systemPrompt: String?, extraSpans: [Span] = [], host: String, profileID: UUID) {
        scanSpansAndLog(extraSpans, host: host, profileID: profileID)
        guard let systemPrompt, !systemPrompt.isEmpty else { return }

        // The whole system prompt is fair game for the hidden-Unicode
        // check: invisible instruction characters have no business
        // anywhere in it, and this avoids depending on the wrapper format.
        var globalFindings = Self.scanHiddenUnicode(systemPrompt)

        // Keyword/meta checks run ONLY on the extracted user-authored
        // instruction spans — running them on the vendor system prompt
        // (which is full of legitimate imperative instructions) would be
        // a false-positive firehose.
        let spans = Self.extractInstructionSpans(systemPrompt)

        // De-dup the global hidden-Unicode hit against the system prompt
        // body so it isn't double-counted per span.
        if !globalFindings.isEmpty, dedupe(systemPrompt) {
            emit(source: "system-prompt", host: host, findings: globalFindings,
                 snippet: systemPrompt, profileID: profileID)
        }
        globalFindings.removeAll()

        scanSpansAndLog(spans, host: host, profileID: profileID)
    }

    private func scanSpansAndLog(_ spans: [Span], host: String, profileID: UUID) {
        for span in spans {
            var findings = Self.scanHiddenUnicode(span.content)
            findings += Self.scanInstructionContent(span.content)
            guard !findings.isEmpty else { continue }
            // Dedupe per (source + content) so an unchanged CLAUDE.md is
            // logged once per session, not once per turn.
            guard dedupe(span.source + "\u{1}" + span.content) else { continue }
            emit(source: span.source, host: host, findings: findings,
                 snippet: span.content, profileID: profileID)
        }
    }

    /// Enforcement variant: returns the first high-severity flagged span
    /// (source + a preview of its content) for the ask/block path, or nil.
    /// No dedup/logging — the caller decides what to do.
    func detect(systemPrompt: String?, extraSpans: [Span] = []) -> (source: String, preview: String)? {
        for span in Self.scannable(extraSpans) {
            var findings = Self.scanHiddenUnicode(span.content)
            findings += Self.scanInstructionContent(span.content)
            if let f = findings.first(where: { $0.severity == .high }) {
                return (span.source, Self.preview(span.content, finding: f))
            }
        }
        guard let systemPrompt, !systemPrompt.isEmpty else { return nil }
        if let f = Self.scanHiddenUnicode(systemPrompt).first(where: { $0.severity == .high }) {
            return ("the system prompt", Self.preview(systemPrompt, finding: f))
        }
        for span in Self.scannable(Self.extractInstructionSpans(systemPrompt)) {
            var findings = Self.scanHiddenUnicode(span.content)
            findings += Self.scanInstructionContent(span.content)
            if let f = findings.first(where: { $0.severity == .high }) {
                return (span.source, Self.preview(span.content, finding: f))
            }
        }
        return nil
    }

    /// The offending section of `content` — a window around the finding's
    /// match (when located), rather than the whole file, so the ask/block
    /// message points straight at what tripped the scanner.
    private static func preview(_ content: String, finding: Finding) -> String {
        guard let range = finding.range else { return previewText(content) }
        let ctx = 300   // characters of surrounding context on each side
        let lo = content.index(range.lowerBound, offsetBy: -ctx, limitedBy: content.startIndex)
            ?? content.startIndex
        let hi = content.index(range.upperBound, offsetBy: ctx, limitedBy: content.endIndex)
            ?? content.endIndex
        var s = String(content[lo..<hi])
        if lo > content.startIndex { s = "…" + s }
        if hi < content.endIndex { s += "…" }
        return s
    }

    private static func previewText(_ s: String) -> String {
        s.count > 4000 ? String(s.prefix(4000)) + "\n…(truncated)" : s
    }

    /// The extracted instruction-file spans as `PromptInjectionClassifier`
    /// input tuples (`id` = the cited path) — lets the ModernBERT model run a
    /// semantic pass over the same CLAUDE.md / AGENTS.md / GROK.md bodies the
    /// heuristics scan.
    /// True when `content` alone trips the deterministic pass (a high
    /// finding) — which span a `detect` hit came from, for redaction.
    static func isHighRisk(_ content: String) -> Bool {
        (scanHiddenUnicode(content) + scanInstructionContent(content)).contains { $0.severity == .high }
    }

    /// Instruction spans as the scanners should read them: a body Bromure
    /// already withheld (`PromptInjectionRedactions.instructionsPlaceholder`)
    /// has nothing left to scan.
    static func scannable(_ spans: [Span]) -> [Span] {
        spans.filter { !PromptInjectionRedactions.isWithheldInstructions($0.content) }
    }

    static func classifierSpans(_ systemPrompt: String?,
                                extraSpans: [Span] = []) -> [(id: String?, content: String)] {
        let spans = scannable((systemPrompt.map(extractInstructionSpans) ?? []) + extraSpans)
        return spans.map { (id: $0.source, content: $0.content) }
    }

    // MARK: - Instruction files riding in the conversation

    /// Repo instruction files an agent pastes into the CONVERSATION rather
    /// than the system prompt — untrusted content (a cloned repo ships its
    /// own) that the model still reads as direction:
    ///   - Codex ≥ 0.15x: a user message `# AGENTS.md instructions for <dir>`
    ///     wrapping the file in `<INSTRUCTIONS>…</INSTRUCTIONS>`; older Codex:
    ///     `<user_instructions>…</user_instructions>`.
    ///   - Claude Code: a `<system-reminder>` carrying
    ///     `Contents of <path>/CLAUDE.md (project instructions…):` bodies.
    /// Only the file bodies are returned — never the text the user typed
    /// alongside them, which is the user's own direction.
    static func conversationInstructionSpans(_ conv: Conversation) -> [Span] {
        var spans: [Span] = []
        for message in conv.messages where message.role == .user || message.role == .system {
            for block in message.content {
                guard case let .text(text) = block else { continue }
                spans += instructionSpans(inMessageText: text)
            }
        }
        // History repeats every turn; one span per distinct body.
        var seen = Set<String>()
        return spans.filter { seen.insert($0.source + "\u{1}" + $0.content).inserted }
    }

    static func instructionSpans(inMessageText text: String) -> [Span] {
        var spans: [Span] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex: "# AGENTS.md instructions for /path\n\n<INSTRUCTIONS>…".
        let codexHeader = "# AGENTS.md instructions for "
        if trimmed.hasPrefix(codexHeader) {
            let firstLine = trimmed.prefix { $0 != "\n" }
            let dir = firstLine.dropFirst(codexHeader.count).trimmingCharacters(in: .whitespaces)
            let source = dir.isEmpty ? "AGENTS.md" : (dir.hasSuffix("/") ? dir : dir + "/") + "AGENTS.md"
            let body = between(trimmed, "<INSTRUCTIONS>", "</INSTRUCTIONS>")
                ?? String(trimmed.dropFirst(firstLine.count))
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { spans.append(Span(source: source, content: content)) }
        }
        if let body = between(trimmed, "<user_instructions>", "</user_instructions>") {
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { spans.append(Span(source: "AGENTS.md", content: content)) }
        }
        // Claude Code: instruction files inside <system-reminder> blocks only
        // (a user typing "Contents of …" in their own prompt isn't a file).
        var rest = Substring(text)
        while let open = rest.range(of: "<system-reminder>") {
            let after = rest[open.upperBound...]
            let close = after.range(of: "</system-reminder>")
            let inner = close.map { after[..<$0.lowerBound] } ?? after
            for span in extractInstructionSpans(String(inner)) {
                let content = trimReminderTail(span.content)
                if !content.isEmpty { spans.append(Span(source: span.source, content: content)) }
            }
            guard let close else { break }
            rest = after[close.upperBound...]
        }
        return spans
    }

    /// Claude Code's reminder continues past the files with its own sections
    /// (`# currentDate` …) and a closing disclaimer — not file content.
    private static func trimReminderTail(_ body: String) -> String {
        let sectionHeads: Set<String> = ["# currentDate", "# userEmail", "# gitStatus",
                                         "# claudeMd", "# todoList", "# importantInstructionReminders"]
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if sectionHeads.contains(t)
                || t.hasPrefix("IMPORTANT: this context may or may not be relevant") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open) else { return nil }
        let tail = s[a.upperBound...]
        guard let b = tail.range(of: close) else { return String(tail) }
        return String(tail[..<b.lowerBound])
    }

    private func dedupe(_ key: String) -> Bool {
        let h = key.hashValue
        lock.lock(); defer { lock.unlock() }
        return seen.insert(h).inserted
    }

    private func emit(source: String, host: String, findings: [Finding],
                      snippet: String, profileID: UUID) {
        let hi = findings.contains { $0.severity == .high }
        let tag = hi ? "FLAG" : "review"
        let summary = findings.map { "\($0.signal)(\($0.severity.rawValue))" }
            .joined(separator: ",")
        let line = "[prompt-injection] rules \(tag) source=\(source) signals=[\(summary)]"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        SupplyChainLog.shared.record(line)   // surfaces in the Security Log window
        // Forward genuine flags (high severity) to bromure.io with the whole
        // file body. Skip the medium-only "review" entries — they're noise.
        if hi {
            PromptInjectionCloudEvent.emit(
                profileID: profileID, detector: "rules", method: "heuristic",
                action: "log", host: host, source: source, score: nil,
                signals: findings.map(\.signal), toolUseId: nil, snippet: snippet)
        }
        if Self.debug {
            for f in findings {
                FileHandle.standardError.write(Data(
                    "[mitm/rules]   \(f.severity.rawValue) \(f.signal): \(f.detail)\n".utf8))
            }
        }
    }

    // MARK: - Span extraction

    /// One instruction file lifted out of the system prompt.
    struct Span { let source: String; let content: String }

    /// Pull the bodies of auto-loaded instruction files. Claude Code wraps
    /// each as `Contents of <path> (… instructions …):` followed by the
    /// file body; a span runs until the next such marker or end of prompt.
    /// Falls back to nothing (not the whole prompt) when no marker is
    /// present, so the keyword pass never runs on the vendor preamble.
    static func extractInstructionSpans(_ systemPrompt: String) -> [Span] {
        let lines = systemPrompt.components(separatedBy: "\n")
        var spans: [Span] = []
        var current: (source: String, body: [String])? = nil

        func flush() {
            if let cur = current, !cur.body.isEmpty {
                spans.append(Span(source: cur.source,
                                  content: cur.body.joined(separator: "\n")))
            }
            current = nil
        }

        for line in lines {
            if let source = Self.instructionMarker(line) {
                flush()
                current = (source: source, body: [])
            } else if current != nil {
                current?.body.append(line)
            }
        }
        flush()
        return spans
    }

    /// Returns the cited path when `line` is an instruction-file header,
    /// else nil. Matches Claude Code's `Contents of <path> (… instructions
    /// …):` and the common rules-file names regardless of wrapper.
    private static func instructionMarker(_ line: String) -> String? {
        let l = line.lowercased()
        guard l.contains("instructions") else {
            // Still treat well-known rules-file paths as markers even if
            // the wrapper wording changes across client versions.
            for name in knownRuleFiles where l.contains(name) {
                if l.hasPrefix("contents of ") { return Self.citedPath(line) }
            }
            return nil
        }
        guard l.hasPrefix("contents of ") else { return nil }
        return Self.citedPath(line)
    }

    /// Instruction / settings files the supported agents (Claude Code,
    /// Codex, Grok) load as authority. The marker-based extraction above
    /// already catches whatever the agent wrapped as instructions; this is a
    /// fallback for path-name matching when the wrapper wording differs.
    private static let knownRuleFiles = [
        "claude.md", "agents.md", "grok.md",
    ]

    private static func citedPath(_ line: String) -> String {
        // "Contents of /path/CLAUDE.md (project instructions…):" → path.
        let afterPrefix = line.dropFirst("Contents of ".count)
        if let paren = afterPrefix.firstIndex(of: "(") {
            return afterPrefix[..<paren].trimmingCharacters(in: .whitespaces)
        }
        return afterPrefix.trimmingCharacters(
            in: CharacterSet(charactersIn: ": ").union(.whitespaces))
    }

    // The text heuristics (InstructionHeuristics.swift), by their old names.
    static func scanHiddenUnicode(_ text: String) -> [Finding] { InstructionHeuristics.scanHiddenUnicode(text) }
    static func scanInstructionContent(_ text: String) -> [Finding] { InstructionHeuristics.scanInstructionContent(text) }
}
