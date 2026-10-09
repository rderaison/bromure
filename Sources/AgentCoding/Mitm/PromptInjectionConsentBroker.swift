import AppKit
import CryptoKit
import Foundation

/// "Ask me what to do" handler for prompt-injection detections. Shows the
/// flagged text in a scrollable textarea and lets the user allow or block the
/// outbound request. Mirrors `SupplyChainConsentBroker`, simpler: a per
/// (profile, source, content) decision memory so the same flagged input isn't
/// re-prompted on every turn (the system prompt / tool_result repeats).
public actor PromptInjectionConsentBroker {
    public init() {}

    private var decisions: [String: Bool] = [:]   // key → allowed
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var profileNames: [UUID: String] = [:]

    public func setProfileName(_ name: String, for id: UUID) { profileNames[id] = name }

    /// True → allow the request through, false → block it.
    public func consent(profileID: UUID, detectorName: String,
                        source: String, flaggedText: String) async -> Bool {
        let key = "\(profileID.uuidString)|\(source)|\(flaggedText.hashValue)"
        if let prior = decisions[key] { return prior }
        if pending[key] != nil {
            return await withCheckedContinuation { c in pending[key, default: []].append(c) }
        }
        pending[key] = []
        let name = profileNames[profileID]
            ?? NSLocalizedString("this workspace", comment: "Prompt-injection consent: unnamed workspace")
        // Non-modal, deadline → block; fat client / terminal when attached.
        // Block (index 0) is the safe default; only an explicit "Allow"
        // lets it through.
        let title = String(format: NSLocalizedString("Possible %@ in “%@”",
            comment: "Prompt-injection consent title"), detectorName, name)
        let message = String(format: NSLocalizedString(
            "Bromure flagged content the agent is about to send to the model (from %@). Review it below — allow it through, or block this request?",
            comment: "Prompt-injection consent body"), source)
        let choices = [NSLocalizedString("Block this request", comment: ""),
                       NSLocalizedString("Allow this request", comment: "")]
        let idx = await ConsentPrompt.choose(profileID: profileID, title: title, message: message,
                                             choices: choices, denyIndex: 0, style: .critical,
                                             detailText: flaggedText)
        let allow = (idx == 1)
        decisions[key] = allow
        let waiters = pending.removeValue(forKey: key) ?? []
        for w in waiters { w.resume(returning: allow) }
        return allow
    }

    public func reset(profileID: UUID) {
        let prefix = profileID.uuidString + "|"
        for k in decisions.keys where k.hasPrefix(prefix) { decisions.removeValue(forKey: k) }
        PromptInjectionRedactions.shared.reset(profileID: profileID)
    }
}

/// Tool output the user blocked as a prompt injection, so the session can go
/// on. An agent resends its whole conversation every turn: once a poisoned
/// tool result was blocked, every later request still carried it, and each
/// one was refused again (451) — the session was dead until the user
/// rewound or started over. Now a request that carries a span already
/// blocked goes out with that span replaced by a neutral placeholder: the
/// model never reads it, the agent gets its reply. Only spans the user (or
/// block mode) refused are touched; new tool output is still scanned.
/// Memory only — a restart forgets, and the next scan asks again.
final class PromptInjectionRedactions: @unchecked Sendable {
    static let shared = PromptInjectionRedactions()

    /// What the model reads where the blocked tool output was. It must not
    /// read as an injection itself: the redacted request is scanned again,
    /// and the old wording ("[content removed by Bromure: possible prompt
    /// injection]") scored 0.75 on the source model — every later turn of
    /// the session was refused (451) for the placeholder alone. Verified
    /// against the installed model: this wording scores ~0.001.
    static let placeholder = "[tool output withheld by Bromure]"

    /// `text` with every placeholder taken out — what the scanner reads (a
    /// span that's only placeholders comes back empty: nothing to scan).
    static func strippingPlaceholders(_ text: String) -> String {
        guard text.contains(placeholder) else { return text }
        return text.replacingOccurrences(of: placeholder, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool-output spans as the scanner should read them: placeholders out,
    /// empty spans dropped.
    static func scannable(_ spans: [(id: String?, content: String)]) -> [(id: String?, content: String)] {
        spans.compactMap { s in
            let c = strippingPlaceholders(s.content)
            return c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (id: s.id, content: c)
        }
    }

    /// What the model reads where a blocked instruction file's body was
    /// (rogue-instructions blocks). The file rides in the conversation —
    /// Claude's `<system-reminder>` "Contents of …/CLAUDE.md", Codex's
    /// AGENTS.md message — and is resent every turn even after the user
    /// deletes the file, so without this the session stayed blocked for good.
    static let instructionsPlaceholder = "[instructions withheld by Bromure]"

    /// A span that's only the withheld-instructions placeholder.
    static func isWithheldInstructions(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == instructionsPlaceholder
    }

    private let lock = NSLock()
    private var blocked: [UUID: Set<String>] = [:]
    /// Blocked instruction-file bodies, matched as substrings (they sit
    /// inside a larger message / system-prompt string).
    private var blockedInstructions: [UUID: Set<String>] = [:]

    /// Remember what a blocked detection refused: its tool output, or the
    /// instruction-file bodies of a rogue-instructions block.
    func block(_ f: PromptInjectionFlag, profileID: UUID) {
        block(f.spans, profileID: profileID)
        blockInstructions(f.ruleSpans, profileID: profileID)
    }

    /// Remember instruction-file bodies a rogue-instructions block refused:
    /// later requests carry `instructionsPlaceholder` in their place.
    func blockInstructions(_ contents: [String], profileID: UUID) {
        let bodies = contents.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 16 && !Self.isWithheldInstructions($0) }
        guard !bodies.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        blockedInstructions[profileID, default: []].formUnion(bodies)
    }

    static func fingerprint(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Remember `contents` (the tool output of a blocked request).
    func block(_ contents: [String], profileID: UUID) {
        let fps = contents.filter { !Self.strippingPlaceholders($0)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(Self.fingerprint)
        guard !fps.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        blocked[profileID, default: []].formUnion(fps)
    }

    func hasAny(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(blocked[profileID]?.isEmpty ?? true) || !(blockedInstructions[profileID]?.isEmpty ?? true)
    }

    func reset(profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        blocked[profileID] = nil
        blockedInstructions[profileID] = nil
    }

    /// `body` (a model request's JSON) with every blocked span replaced by
    /// the placeholder, and how many were; nil when nothing was blocked in it.
    /// A span is a JSON string, or a list of text blocks whose texts joined
    /// by newlines are the span (how the conversation parser read it).
    func redact(_ body: Data, profileID: UUID) -> (body: Data, count: Int)? {
        let (set, bodies): (Set<String>, [String]) = {
            lock.lock(); defer { lock.unlock() }
            // Longest first: a body that contains another is replaced whole.
            return (blocked[profileID] ?? [],
                    (blockedInstructions[profileID] ?? []).sorted { $0.count > $1.count })
        }()
        guard !set.isEmpty || !bodies.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
        var count = 0
        func walk(_ v: Any) -> Any {
            if var s = v as? String {
                if !set.isEmpty, set.contains(Self.fingerprint(s)) { count += 1; return Self.placeholder }
                for b in bodies where s.contains(b) {
                    s = s.replacingOccurrences(of: b, with: Self.instructionsPlaceholder)
                    count += 1
                }
                return s
            }
            if let a = v as? [Any] {
                let blocks = a.compactMap { $0 as? [String: Any] }
                let texts = blocks.compactMap { $0["text"] as? String }
                if a.count > 1, blocks.count == a.count, texts.count == a.count,
                   set.contains(Self.fingerprint(texts.joined(separator: "\n"))) {
                    var first = blocks[0]
                    first["text"] = Self.placeholder
                    count += 1
                    return [first]
                }
                return a.map(walk)
            }
            if let d = v as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, x) in d { out[k] = walk(x) }
                return out
            }
            return v
        }
        let rewritten = walk(root)
        guard count > 0,
              let data = try? JSONSerialization.data(withJSONObject: rewritten,
                                                     options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return nil }
        return (data, count)
    }
}
