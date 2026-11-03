import Foundation

/// The string heuristics behind RulesFileScanner, on their own so code that
/// builds without the scanner's conversation types (the automations' event
/// screen, on every platform) can run them.
enum InstructionHeuristics {
    enum Severity: String, Sendable { case high, medium }

    struct Finding: Sendable {
        let severity: Severity
        let signal: String
        let detail: String
        /// Where in the scanned text the signal was found, when known — used to
        /// show just the offending section (with a little context) instead of
        /// the whole file. Valid only against the exact string it was scanned
        /// from; nil for aggregate signals.
        var range: Range<String.Index>? = nil
    }

    // MARK: - Hidden / obfuscation Unicode

    /// The Rules File Backdoor's core trick: instructions a human can't see
    /// but the model reads. Near-zero false positive — legit config files
    /// don't carry zero-width joiners, bidi overrides, or Unicode tags.
    static func scanHiddenUnicode(_ text: String) -> [Finding] {
        var zeroWidth = 0, bidi = 0, tags = 0, otherFmt = 0
        // Anchor the preview at the FIRST hidden char so the snippet shows the
        // surrounding (visible) text where the payload is buried.
        var firstHidden: String.Index?
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            var hidden = true
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
                if scalar.properties.generalCategory == .format { otherFmt += 1 }
                else { hidden = false }
            }
            if hidden, firstHidden == nil { firstHidden = i }
            i = scalars.index(after: i)
        }
        let at: Range<String.Index>? = firstHidden.map {
            $0 ..< (text.index($0, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex)
        }
        var out: [Finding] = []
        if tags > 0 {
            out.append(Finding(severity: .high, signal: "unicode_tag_chars",
                               detail: "\(tags) U+E00xx tag char(s) — invisible instruction payload",
                               range: at))
        }
        if bidi > 0 {
            out.append(Finding(severity: .high, signal: "bidi_override",
                               detail: "\(bidi) bidirectional control char(s) — text-direction obfuscation",
                               range: at))
        }
        if zeroWidth > 0 {
            out.append(Finding(severity: .high, signal: "zero_width",
                               detail: "\(zeroWidth) zero-width / soft-hyphen char(s) — hidden text",
                               range: at))
        }
        if otherFmt > 0 {
            out.append(Finding(severity: .medium, signal: "format_chars",
                               detail: "\(otherFmt) other invisible format char(s)", range: at))
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
            // Detection stays on `lower` (unchanged); locate the same match in
            // the ORIGINAL text so the preview can point at it.
            let r = text.range(of: pat, options: [.regularExpression, .caseInsensitive])
            out.append(Finding(severity: .high, signal: "meta_instruction",
                               detail: label, range: r))
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
