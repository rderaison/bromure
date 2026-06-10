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

    enum Severity: String, Sendable { case high, medium }

    struct Finding: Sendable {
        let severity: Severity
        let signal: String
        let detail: String
    }

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
    func scanAndLog(systemPrompt: String?, host: String) {
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
            emit(source: "system-prompt", host: host, findings: globalFindings)
        }
        globalFindings.removeAll()

        for span in spans {
            var findings = Self.scanHiddenUnicode(span.content)
            findings += Self.scanInstructionContent(span.content)
            guard !findings.isEmpty else { continue }
            // Dedupe per (source + content) so an unchanged CLAUDE.md is
            // logged once per session, not once per turn.
            guard dedupe(span.source + "\u{1}" + span.content) else { continue }
            emit(source: span.source, host: host, findings: findings)
        }
    }

    /// Enforcement variant: returns the first high-severity flagged span
    /// (source + a preview of its content) for the ask/block path, or nil.
    /// No dedup/logging — the caller decides what to do.
    func detect(systemPrompt: String?) -> (source: String, preview: String)? {
        guard let systemPrompt, !systemPrompt.isEmpty else { return nil }
        if !Self.scanHiddenUnicode(systemPrompt).isEmpty {
            return ("the system prompt", Self.previewText(systemPrompt))
        }
        for span in Self.extractInstructionSpans(systemPrompt) {
            var findings = Self.scanHiddenUnicode(span.content)
            findings += Self.scanInstructionContent(span.content)
            if findings.contains(where: { $0.severity == .high }) {
                return (span.source, Self.previewText(span.content))
            }
        }
        return nil
    }

    private static func previewText(_ s: String) -> String {
        s.count > 4000 ? String(s.prefix(4000)) + "\n…(truncated)" : s
    }

    /// The extracted instruction-file spans as `PromptInjectionClassifier`
    /// input tuples (`id` = the cited path) — lets the ModernBERT model run a
    /// semantic pass over the same CLAUDE.md / AGENTS.md / GROK.md bodies the
    /// heuristics scan.
    static func classifierSpans(_ systemPrompt: String?) -> [(id: String?, content: String)] {
        guard let systemPrompt else { return [] }
        return extractInstructionSpans(systemPrompt).map { (id: $0.source, content: $0.content) }
    }

    private func dedupe(_ key: String) -> Bool {
        let h = key.hashValue
        lock.lock(); defer { lock.unlock() }
        return seen.insert(h).inserted
    }

    private func emit(source: String, host: String, findings: [Finding]) {
        let hi = findings.contains { $0.severity == .high }
        let tag = hi ? "FLAG" : "review"
        let summary = findings.map { "\($0.signal)(\($0.severity.rawValue))" }
            .joined(separator: ",")
        let line = "[prompt-injection] rules \(tag) source=\(source) signals=[\(summary)]"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        SupplyChainLog.shared.record(line)   // surfaces in the Security Log window
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

    // MARK: - Hidden / obfuscation Unicode

    /// The Rules File Backdoor's core trick: instructions a human can't see
    /// but the model reads. Near-zero false positive — legit config files
    /// don't carry zero-width joiners, bidi overrides, or Unicode tags.
    static func scanHiddenUnicode(_ text: String) -> [Finding] {
        var zeroWidth = 0, bidi = 0, tags = 0, otherFmt = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD:
                zeroWidth += 1
            case 0x202A...0x202E, 0x2066...0x2069:
                bidi += 1
            case 0xE0000...0xE007F:
                tags += 1
            default:
                // Other Unicode "format" (Cf) characters, excluding the
                // ones already counted. These are the invisible-payload
                // carriers; ordinary text has none.
                if scalar.properties.generalCategory == .format {
                    otherFmt += 1
                }
            }
        }
        var out: [Finding] = []
        if tags > 0 {
            out.append(Finding(severity: .high, signal: "unicode_tag_chars",
                               detail: "\(tags) U+E00xx tag char(s) — invisible instruction payload"))
        }
        if bidi > 0 {
            out.append(Finding(severity: .high, signal: "bidi_override",
                               detail: "\(bidi) bidirectional control char(s) — text-direction obfuscation"))
        }
        if zeroWidth > 0 {
            out.append(Finding(severity: .high, signal: "zero_width",
                               detail: "\(zeroWidth) zero-width / soft-hyphen char(s) — hidden text"))
        }
        if otherFmt > 0 {
            out.append(Finding(severity: .medium, signal: "format_chars",
                               detail: "\(otherFmt) other invisible format char(s)"))
        }
        return out
    }

    // MARK: - Meta-instruction + capability heuristics

    static func scanInstructionContent(_ text: String) -> [Finding] {
        let lower = text.lowercased()
        var out: [Finding] = []

        // Instructions that subvert the user relationship — a project
        // config has no legitimate reason to tell the agent to override
        // or hide things from the user. High confidence in a rules file.
        for (pat, label) in metaPatterns where lower.range(of: pat, options: .regularExpression) != nil {
            out.append(Finding(severity: .high, signal: "meta_instruction",
                               detail: label))
            break   // one is enough; don't spam the same class
        }

        // Capability / exfiltration shapes. These CAN be legitimate in a
        // build-doc (".env", "git push"), so medium — flag for review.
        for (pat, label) in capabilityPatterns where lower.range(of: pat, options: .regularExpression) != nil {
            out.append(Finding(severity: .medium, signal: "capability",
                               detail: label))
        }
        return out
    }

    /// `(regex, human label)`. Lowercased input; keep patterns lowercase.
    private static let metaPatterns: [(String, String)] = [
        ("ignore (all |any )?(previous|prior|above|earlier) [a-z ]*instruction", "‘ignore previous instructions’"),
        ("disregard (the |all )?(previous|above|prior|earlier|system)", "‘disregard …’"),
        ("do not (tell|inform|mention|reveal|disclose|notify)[a-z ]*(the user|to the user)", "‘do not tell the user’"),
        ("without (telling|informing|notifying|alerting)[a-z ]*the user", "‘without telling the user’"),
        ("(don'?t|do not) let the user (know|see|notice)", "‘don’t let the user know’"),
        ("regardless of (what|the user|any instruction)", "‘regardless of the user’"),
        ("override (the )?(system|safety|security|previous|default)", "‘override the system/safety’"),
        ("you are now ", "persona-override (‘you are now …’)"),
        ("new instructions:", "embedded ‘new instructions:’"),
    ]

    private static let capabilityPatterns: [(String, String)] = [
        ("~/.ssh|id_rsa|id_ed25519|\\.aws/credentials|\\.git-credentials|\\.npmrc", "references credential file paths"),
        ("\\.env\\b", "references .env"),
        ("(curl|wget|fetch|invoke-webrequest|nc)\\b[^\\n]*https?://", "outbound fetch to a URL"),
        ("base64[^\\n]*(\\||curl|wget|nc|sh|bash)", "base64 + pipe/network (exfil/obfuscation)"),
        ("(curl|wget)[^\\n]*\\|\\s*(sh|bash|python)", "pipe remote content to a shell"),
        ("eval\\(|decode and (run|execute)|exec\\(", "decode-and-execute"),
        ("git push[^\\n]*(--force|-f)\\b|force[- ]push", "force push"),
        ("rm -rf|delete (all|everything|the repo)", "destructive file op"),
        ("(send|upload|post|exfiltrate)[^\\n]*(to )?https?://", "send data to a URL"),
    ]
}
