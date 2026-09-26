import Foundation

/// Swaps personal data in AI requests for stand-ins and puts the real values
/// back in the replies — so the model provider never sees them, while the
/// agent and its files keep working with the real thing.
///
/// Requests are rewritten in place, string by string: only the JSON strings
/// that change are re-encoded, every other byte goes out as the agent sent
/// it. Signed or opaque content (thinking blocks, signatures, encrypted
/// reasoning, base64 data) is never touched in either direction, so the
/// provider's signature checks still pass.
enum PIIRewriter {

    /// JSON keys whose string values are never scanned or rewritten.
    static let skipKeys: Set<String> = [
        "thinking", "signature", "data", "redacted_thinking", "encrypted_content",
        "id", "tool_use_id", "call_id", "item_id", "response_id", "previous_response_id",
        "type", "role", "model", "name", "media_type", "mime_type", "url", "image_url",
        "file_id", "b64_json", "user_id", "cache_control", "stop_reason", "finish_reason",
        "service_tier", "effort", "status", "object", "prompt_cache_key",
    ]

    /// Is this an AI API call whose body carries a conversation?
    static func isEligible(host: String, method: String, body: Data) -> Bool {
        guard method.uppercased() == "POST", body.count > 2, body.first == UInt8(ascii: "{") else { return false }
        let h = host.lowercased()
        guard TraceLevel.aiHosts.contains(where: { h.contains($0) }),
              !h.contains("huggingface.co"), h != InferenceService.localMitmHost else { return false }
        // A conversation: Anthropic `messages`, OpenAI `messages`/`input`,
        // Gemini `contents`. Cheap byte probe before any parsing.
        for k in ["\"messages\"", "\"input\"", "\"contents\""] where body.range(of: Data(k.utf8)) != nil {
            return true
        }
        return false
    }

    // MARK: Request

    struct Outcome {
        var body: Data
        /// Values replaced in content the provider hadn't seen before (new
        /// this turn), by kind — what the Security Timeline reports.
        var newSwaps: [PIIVault.Kind: Int] = [:]
        var total: Int { newSwaps.values.reduce(0, +) }
        /// The model budget ran out: some new text got the recognizers only.
        var partial = false
    }

    /// Characters of new text the model reads per request (~20 ms per 1K on
    /// dense prose or data). Past it, the recognizers alone — a 700 KB dump
    /// shouldn't stall a turn for fifteen seconds. BROMURE_PII_BUDGET overrides.
    static let modelBudget: Int = {
        if let s = ProcessInfo.processInfo.environment["BROMURE_PII_BUDGET"], let v = Int(s) { return v }
        return 300_000
    }()

    static func rewriteRequest(_ body: Data, policy: PIIPolicy, vault: PIIVault,
                               detector: PIIDetector = .shared) async -> Outcome {
        let bytes = [UInt8](body)
        guard let refs = JSONStrings.scan(bytes) else { return Outcome(body: body) }
        // Decode each eligible string once; detect over the distinct ones.
        var items: [(ref: JSONStrings.Ref, text: String)] = []
        for r in refs {
            if let k = r.key, skipKeys.contains(k) { continue }
            guard r.range.count >= 5 else { continue }   // "" plus 3 chars
            items.append((r, JSONStrings.decode(bytes, r.range)))
        }
        // Newest content first (the end of the conversation): if a huge
        // request runs the model budget out, it's the history — already
        // swapped on earlier turns — that gets the recognizers only.
        var plans: [String: (spans: [PIISpan], fresh: Bool)] = [:]
        var budget = modelBudget
        var outcome = Outcome(body: body)
        for (_, text) in items.reversed() where plans[text] == nil {
            let (spans, cached) = await detector.detect(text, useModel: budget > 0)
            if !cached {
                if budget <= 0 { outcome.partial = true }
                budget -= (text as NSString).length
            }
            plans[text] = (plan(spans, in: text, policy: policy), !cached)
        }
        // Learn every value before replacing any, so a name found late in the
        // body is also swapped where it appeared earlier.
        for (text, p) in plans {
            let ns = text as NSString
            for s in p.spans {
                vault.learn(ns.substring(with: NSRange(location: s.start, length: s.length)), label: s.label)
            }
        }
        guard !vault.isEmpty else { return outcome }

        var out = Data(capacity: bytes.count + 256)
        var cursor = 0
        for (ref, text) in items {
            guard let p = plans[text] else { continue }
            let (swapped, n) = vault.forward(text, spans: p.spans)
            guard n > 0, swapped != text else { continue }
            if p.fresh {
                for s in p.spans { outcome.newSwaps[PIIVault.Kind(s.label), default: 0] += 1 }
            }
            out.append(contentsOf: bytes[cursor..<ref.range.lowerBound])
            out.append(JSONStrings.encode(swapped))
            cursor = ref.range.upperBound
        }
        guard cursor > 0 else { return outcome }
        out.append(contentsOf: bytes[cursor...])
        outcome.body = out
        return outcome
    }

    /// The spans worth swapping under `policy`: coarse geography, URLs and IP
    /// addresses stay; a street line is swapped whole; fragments too short or
    /// too code-shaped to be someone's data are left alone.
    static func plan(_ spans: [PIISpan], in text: String, policy: PIIPolicy) -> [PIISpan] {
        let ns = text as NSString
        func str(_ s: PIISpan) -> String { ns.substring(with: NSRange(location: s.start, length: s.length)) }
        func gapIsJoin(_ a: PIISpan, _ b: PIISpan) -> Bool {
            guard b.start >= a.end, b.start - a.end <= 3 else { return false }
            return ns.substring(with: NSRange(location: a.end, length: b.start - a.end))
                .allSatisfy { $0 == " " || $0 == "," || $0 == "." }
        }
        // Trim what the model let a span swallow at its edges: quotes, list
        // punctuation, an unmatched bracket.
        let trimmed: [PIISpan] = spans.compactMap { sp in
            var s = sp
            func ch(_ i: Int) -> Character { Character(ns.substring(with: NSRange(location: i, length: 1))) }
            let junk: Set<Character> = [" ", "\t", "\n", "\"", "'", "`", ",", ";", ":", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
            while s.length > 0, junk.contains(ch(s.start)) || (ch(s.start) == "(" && !str(s).contains(")")) { s.start += 1 }
            while s.length > 0, junk.contains(ch(s.end - 1)) || (ch(s.end - 1) == ")" && !str(s).contains("(")) { s.end -= 1 }
            return s.length > 0 ? s : nil
        }
        // Fold building number + street + unit into one street line.
        var joined: [PIISpan] = []
        for s in trimmed {
            if let last = joined.last,
               [.buildingNumber, .streetName, .secondaryAddress].contains(last.label),
               [.buildingNumber, .streetName, .secondaryAddress].contains(s.label),
               gapIsJoin(last, s) {
                var m = last
                m.end = s.end
                m.label = .streetName
                m.score = max(last.score, s.score)
                joined[joined.count - 1] = m
            } else {
                joined.append(s)
            }
        }
        return joined.filter { s in
            let t = str(s)
            // PII doesn't straddle lines.
            if t.contains(where: \.isNewline) { return false }
            switch s.label {
            case .city, .state, .zipCode, .url, .ipAddress:
                return false
            case .givenName, .surname:
                guard policy.names, s.length >= 2 else { return false }
                return isPlausibleName(t)
            case .email, .phone:
                guard policy.contact else { return false }
                return s.label == .email ? isPlausibleEmail(t) : t.filter(\.isNumber).count >= 7
            case .creditCard, .ssn:
                // Validator-backed: always what they say they are.
                return s.label == .ssn ? policy.governmentIDs : policy.financial
            case .bankAccount, .routingNumber, .taxID:
                return policy.financial && isPlausibleIdentifier(t)
            case .governmentID, .passport, .driversLicense:
                return policy.governmentIDs && isPlausibleIdentifier(t)
            case .streetName, .secondaryAddress:
                // A street line, not a lone "Avenue": a number, or two words
                // that aren't all street-type words.
                guard policy.addresses, s.length >= 6 else { return false }
                let words = t.split(separator: " ").map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                let suffixes = ["straße", "strasse", "gasse", "weg", "laan", "straat", "vej", "gatan", "gade"]
                return t.contains(where: \.isNumber)
                    || (words.count >= 2 && words.contains { PIISurrogates.isStreetWord($0) }
                        && !words.allSatisfy { PIISurrogates.isStreetWord($0) })
                    || words.contains { w in suffixes.contains { w.hasSuffix($0) && w.count > $0.count } }
            case .buildingNumber:
                return false
            }
        }
    }

    /// Product, company and tool names the model can mistake for people.
    static let notPeople: Set<String> = [
        "claude", "anthropic", "openai", "chatgpt", "codex", "gemini", "grok", "kimi", "moonshot",
        "bromure", "copilot", "cursor", "llama", "mistral", "qwen", "deepseek", "ollama", "sonnet",
        "opus", "haiku", "github", "gitlab", "apple", "google", "microsoft", "amazon", "azure",
        "linux", "ubuntu", "debian", "docker", "kubernetes", "swift", "python", "node", "react",
        "xcode", "siri", "alexa", "jenkins", "ansible", "terraform", "postgres", "redis", "kafka",
        "django", "flask", "rails", "laravel", "maven", "gradle", "homebrew", "chromium", "chrome",
        "firefox", "safari", "slack", "jira", "notion", "figma", "stripe", "twilio", "vercel",
        "netlify", "heroku", "sentry", "datadog", "grafana", "prometheus", "jupyter", "pandas",
        "kotlin", "scala", "elixir", "erlang", "haskell", "ghostty", "tmux", "vim", "emacs",
        "darwin", "mozilla", "kernel", "unix", "posix", "windows", "android", "safari", "webkit",
    ]

    /// Not an image asset (`icon@2x.png`) or other file name.
    static func isPlausibleEmail(_ t: String) -> Bool {
        guard let at = t.lastIndex(of: "@") else { return false }
        let domain = t[t.index(after: at)...].lowercased()
        let tld = domain.split(separator: ".").last.map(String.init) ?? ""
        let fileExt: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "pdf", "js", "ts",
                                    "css", "json", "swift", "py", "rb", "go", "rs", "md", "txt", "html", "zip"]
        if fileExt.contains(tld) { return false }
        if domain.first?.isNumber == true, domain.contains("x.") { return false }
        return true
    }

    static let nameParticles: Set<String> = [
        "van", "von", "der", "den", "de", "la", "le", "du", "des", "da", "das", "dos", "di", "del",
        "della", "bin", "ibn", "al", "el", "ter", "ten",
    ]

    /// A person's name, not an identifier: starts with a capital, no code
    /// punctuation, and no camelCase hump except the Mc/Mac/De/O' kind.
    static func isPlausibleName(_ t: String) -> Bool {
        // Lower-case particles may lead ("van der Berg", "de la Cruz").
        let words = t.split(separator: " ")
        guard let lead = words.first(where: { !nameParticles.contains($0.lowercased()) }),
              lead.first?.isUppercase == true else { return false }
        if t.contains(where: { "_/\\(){}[]<>=:;@#$%^&*|`\"0123456789".contains($0) }) { return false }
        for word in t.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            let w = String(word)
            if notPeople.contains(w.lowercased()) { return false }
            let chars = Array(w)
            // "OAuth", "NIOSSHHandler": capitals inside a mixed-case word.
            let caps = chars.filter(\.isUppercase).count
            if caps >= 2, chars.contains(where: \.isLowercase),
               !(chars.count > 2 && (w.hasPrefix("Mc") || w.hasPrefix("Mac") || w.hasPrefix("O'")
                                     || w.hasPrefix("D'") || w.hasPrefix("De") || w.hasPrefix("La"))) {
                return false
            }
            for i in 1..<max(1, chars.count) where chars[i].isUppercase && chars[i - 1].isLowercase {
                let head = String(chars[..<i]).lowercased()
                if !["mc", "mac", "de", "di", "da", "la", "le", "van", "von", "o'", "d'"].contains(head) { return false }
            }
        }
        return true
    }

    /// An ID number rather than a code constant or a hash: has digits, isn't
    /// a bare run of 10+ digits or 16+ hex characters.
    static func isPlausibleIdentifier(_ t: String) -> Bool {
        if t.contains(where: { "/:\\=@".contains($0) }) { return false }
        let digits = t.filter(\.isNumber).count
        guard digits >= 4, (t as NSString).length >= 5 else { return false }
        let alnum = t.filter { $0.isLetter || $0.isNumber }
        if alnum.count >= 16, alnum.allSatisfy(\.isHexDigit) { return false }
        if digits == t.count, digits >= 10 { return false }
        return true
    }
}

// MARK: - JSON string walker

/// Finds every string value in a JSON document with its byte range and the
/// object key it belongs to (array elements inherit the array's key). Used to
/// rewrite single strings without re-serializing — and so reordering or
/// reformatting — the rest of the body.
enum JSONStrings {
    struct Ref {
        /// Byte range including the quotes.
        let range: Range<Int>
        let key: String?
    }

    static func scan(_ b: [UInt8]) -> [Ref]? {
        enum Frame { case object(expectKey: Bool, key: String?), array(key: String?) }
        var stack: [Frame] = []
        var refs: [Ref] = []
        var i = 0
        let n = b.count
        func contextKey() -> String? {
            switch stack.last {
            case .object(_, let k)?: return k
            case .array(let k)?: return k
            case nil: return nil
            }
        }
        while i < n {
            let c = b[i]
            switch c {
            case UInt8(ascii: "{"):
                stack.append(.object(expectKey: true, key: nil)); i += 1
            case UInt8(ascii: "["):
                stack.append(.array(key: contextKey())); i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard !stack.isEmpty else { return nil }
                stack.removeLast(); i += 1
            case UInt8(ascii: ","):
                if case .object(_, let k)? = stack.last { stack[stack.count - 1] = .object(expectKey: true, key: k) }
                i += 1
            case UInt8(ascii: "\""):
                let start = i
                i += 1
                while i < n && b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                guard i < n else { return nil }
                i += 1
                if case .object(true, _)? = stack.last {
                    stack[stack.count - 1] = .object(expectKey: false, key: decode(b, start..<i))
                } else {
                    refs.append(Ref(range: start..<i, key: contextKey()))
                }
            default:
                i += 1
            }
        }
        return stack.isEmpty ? refs : nil
    }

    /// The string a quoted JSON literal stands for.
    static func decode(_ b: [UInt8], _ r: Range<Int>) -> String {
        let inner = b[(r.lowerBound + 1)..<(r.upperBound - 1)]
        guard inner.contains(UInt8(ascii: "\\")) else { return String(decoding: inner, as: UTF8.self) }
        // Let Foundation handle escapes (incl. surrogate pairs) for this one.
        let lit = Data(b[r])
        if let s = try? JSONSerialization.jsonObject(with: lit, options: .fragmentsAllowed) as? String { return s }
        return String(decoding: inner, as: UTF8.self)
    }

    static func encode(_ s: String) -> Data {
        Data(("\"" + PIIVault.jsonEscape(s) + "\"").utf8)
    }
}

// MARK: - Response

/// Streams an AI response back to the guest with stand-ins replaced by the
/// real values. Server-sent events are parsed per event: streamed text is
/// restored with a short hold-back so a stand-in split across two events is
/// still recognized, and the held tail is released at the end of its block.
/// Plain JSON bodies are restored whole. Thinking and signatures pass through
/// byte-for-byte.
final class PIIResponseRestorer {
    private let vault: PIIVault
    private enum Mode { case sse, json, passthrough }
    private var mode: Mode
    private var buffer = Data()

    /// A stream slot (one content block / output item / choice) with text
    /// held back, and the last event that carried it — the template for the
    /// event that releases the tail.
    private struct Slot {
        var pending: String
        var template: NSMutableDictionary
        var path: [Any]
        var json: Bool
        var eventLine: String?
    }
    private var slots: [String: Slot] = [:]
    private var slotOrder: [String] = []

    init(vault: PIIVault, contentType: String) {
        self.vault = vault
        let ct = contentType.lowercased()
        mode = ct.contains("text/event-stream") ? .sse : ct.contains("json") ? .json : .passthrough
    }

    func feed(_ chunk: Data) -> Data {
        switch mode {
        case .passthrough: return chunk
        case .json: buffer.append(chunk); return Data()
        case .sse:
            buffer.append(chunk)
            var out = Data()
            while let r = Self.eventBoundary(in: buffer) {
                let event = buffer.subdata(in: 0..<r.lowerBound)
                let sep = buffer.subdata(in: r)
                buffer.removeSubrange(0..<r.upperBound)
                out.append(processEvent(event, separator: sep))
            }
            return out
        }
    }

    func finish() -> Data {
        switch mode {
        case .passthrough: return Data()
        case .json:
            let b = [UInt8](buffer)
            guard let refs = JSONStrings.scan(b) else { return buffer }
            var out = Data(capacity: b.count)
            var cursor = 0
            for r in refs {
                if let k = r.key, PIIRewriter.skipKeys.contains(k) { continue }
                let s = JSONStrings.decode(b, r.range)
                let restored = vault.restore(s)
                guard restored != s else { continue }
                out.append(contentsOf: b[cursor..<r.range.lowerBound])
                out.append(JSONStrings.encode(restored))
                cursor = r.range.upperBound
            }
            out.append(contentsOf: b[cursor...])
            return out
        case .sse:
            var out = flushAll()
            if !buffer.isEmpty { out.append(buffer); buffer.removeAll() }
            return out
        }
    }

    private static func eventBoundary(in d: Data) -> Range<Int>? {
        let lf = d.range(of: Data("\n\n".utf8))
        let crlf = d.range(of: Data("\r\n\r\n".utf8))
        switch (lf, crlf) {
        case let (a?, b?): return a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    private func processEvent(_ raw: Data, separator: Data) -> Data {
        let text = String(decoding: raw, as: UTF8.self)
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let di = lines.firstIndex(where: { $0.hasPrefix("data:") }) else {
            return raw + separator
        }
        let payload = String(lines[di].dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let eventLine = lines.first { $0.hasPrefix("event:") }
        if payload == "[DONE]" { return flushAll() + raw + separator }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: .mutableContainers))
                as? NSMutableDictionary else { return raw + separator }

        var out = Data()
        let type = obj["type"] as? String ?? ""
        let deltas = Self.deltaFields(obj, type: type)
        if deltas.isEmpty {
            if type == "ping" { return raw + separator }
            // Any other event closes what's streaming: release held text first.
            let closing = Self.closingSlots(obj, type: type, open: slotOrder)
            out.append(closing == nil ? flushAll() : flush(closing!))
            guard Self.restoreAll(obj, vault: vault) else { return out + raw + separator }
        } else {
            for d in deltas {
                guard let piece = Self.get(obj, d.path) as? String else { continue }
                var slot = slots[d.slot] ?? Slot(pending: "", template: obj, path: d.path, json: d.json, eventLine: eventLine)
                let text = slot.pending + piece
                let cut = vault.holdback(text)
                let head = (text as NSString).substring(to: cut)
                slot.pending = (text as NSString).substring(from: cut)
                if let copy = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: .mutableContainers)
                    as? NSMutableDictionary { slot.template = copy }
                slot.eventLine = eventLine
                if slots[d.slot] == nil { slotOrder.append(d.slot) }
                slots[d.slot] = slot
                Self.set(obj, d.path, vault.restore(head, jsonFragment: d.json))
            }
            // Finishing a chat choice also closes its slots (after this delta).
            if let closing = Self.closingSlots(obj, type: type, open: slotOrder), !closing.isEmpty {
                out.append(Self.serialize(obj, lines: &lines, at: di, separator: separator))
                out.append(flush(closing))
                return out
            }
        }
        out.append(Self.serialize(obj, lines: &lines, at: di, separator: separator))
        return out
    }

    private static func serialize(_ obj: NSMutableDictionary, lines: inout [String], at i: Int, separator: Data) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        lines[i] = "data: " + String(decoding: json, as: UTF8.self)
        return Data(lines.joined(separator: "\n").utf8) + separator
    }

    /// Release the held tail of `keys` as one extra delta event each.
    private func flush(_ keys: [String]) -> Data {
        var out = Data()
        for k in keys {
            guard let slot = slots.removeValue(forKey: k) else { continue }
            slotOrder.removeAll { $0 == k }
            guard !slot.pending.isEmpty else { continue }
            let ev = slot.template
            // Only the held tail: blank every other streamed field it carried.
            for d in Self.deltaFields(ev, type: ev["type"] as? String ?? "") { Self.set(ev, d.path, "") }
            Self.set(ev, slot.path, vault.restore(slot.pending, jsonFragment: slot.json))
            if let choices = ev["choices"] as? NSMutableArray {
                for case let c as NSMutableDictionary in choices { c["finish_reason"] = NSNull() }
            }
            var lines = [slot.eventLine, "data: "].compactMap { $0 }
            out.append(Self.serialize(ev, lines: &lines, at: lines.count - 1, separator: Data("\n\n".utf8)))
        }
        return out
    }

    private func flushAll() -> Data { flush(slotOrder) }

    // MARK: Event shapes

    private struct Delta { let slot: String; let path: [Any]; let json: Bool }

    /// The streamed-text fields of one event, per wire format.
    private static func deltaFields(_ o: NSDictionary, type: String) -> [Delta] {
        // Anthropic Messages.
        if type == "content_block_delta", let d = o["delta"] as? NSDictionary, let idx = o["index"] {
            switch d["type"] as? String {
            case "text_delta": return [Delta(slot: "a\(idx)", path: ["delta", "text"], json: false)]
            case "input_json_delta": return [Delta(slot: "a\(idx)", path: ["delta", "partial_json"], json: true)]
            default: return []    // thinking / signature / citations: untouched
            }
        }
        // OpenAI Responses.
        if type.hasPrefix("response."), type.hasSuffix(".delta"), o["delta"] is String {
            let item = (o["item_id"] as? String) ?? "\(o["output_index"] ?? 0)"
            if type == "response.output_text.delta" {
                return [Delta(slot: "r\(item):\(o["content_index"] ?? 0)", path: ["delta"], json: false)]
            }
            if type == "response.function_call_arguments.delta" {
                return [Delta(slot: "r\(item)", path: ["delta"], json: true)]
            }
            if type.contains("reasoning_summary_text") {
                return [Delta(slot: "r\(item):s\(o["summary_index"] ?? 0)", path: ["delta"], json: false)]
            }
            return []
        }
        // OpenAI Chat Completions.
        if let choices = o["choices"] as? NSArray {
            var out: [Delta] = []
            for (ci, c) in choices.enumerated() {
                guard let c = c as? NSDictionary, let d = c["delta"] as? NSDictionary else { continue }
                let slot = "c\(c["index"] ?? ci)"
                if d["content"] is String { out.append(Delta(slot: slot, path: ["choices", ci, "delta", "content"], json: false)) }
                if let calls = d["tool_calls"] as? NSArray {
                    for (ti, t) in calls.enumerated() {
                        guard let t = t as? NSDictionary, let f = t["function"] as? NSDictionary,
                              f["arguments"] is String else { continue }
                        out.append(Delta(slot: "\(slot)t\(t["index"] ?? ti)",
                                         path: ["choices", ci, "delta", "tool_calls", ti, "function", "arguments"], json: true))
                    }
                }
            }
            return out
        }
        // Gemini.
        if let cands = o["candidates"] as? NSArray {
            var out: [Delta] = []
            for (ci, c) in cands.enumerated() {
                guard let c = c as? NSDictionary, let content = c["content"] as? NSDictionary,
                      let parts = content["parts"] as? NSArray else { continue }
                for (pi, p) in parts.enumerated() where (p as? NSDictionary)?["text"] is String {
                    out.append(Delta(slot: "g\(c["index"] ?? ci)", path: ["candidates", ci, "content", "parts", pi, "text"], json: false))
                }
            }
            return out
        }
        return []
    }

    /// Slots this event closes, or nil for "all of them".
    private static func closingSlots(_ o: NSDictionary, type: String, open: [String]) -> [String]? {
        if type == "content_block_stop", let idx = o["index"] { return ["a\(idx)"] }
        if let choices = o["choices"] as? NSArray {
            var keys: [String] = []
            for (ci, c) in choices.enumerated() {
                guard let c = c as? NSDictionary, let fr = c["finish_reason"], !(fr is NSNull) else { continue }
                let slot = "c\(c["index"] ?? ci)"
                keys += open.filter { $0 == slot || $0.hasPrefix(slot + "t") }
            }
            return keys
        }
        if let cands = o["candidates"] as? NSArray {
            var keys: [String] = []
            for (ci, c) in cands.enumerated() {
                guard let c = c as? NSDictionary, c["finishReason"] != nil else { continue }
                keys.append("g\(c["index"] ?? ci)")
            }
            return keys
        }
        return nil
    }

    /// Restore every string in a whole event (skipping signed/opaque keys).
    /// Returns whether anything changed.
    private static func restoreAll(_ o: Any, vault: PIIVault, key: String? = nil) -> Bool {
        var changed = false
        if let d = o as? NSMutableDictionary {
            for k in d.allKeys {
                guard let ks = k as? String, !PIIRewriter.skipKeys.contains(ks) else { continue }
                if let s = d[ks] as? String {
                    let r = vault.restore(s)
                    if r != s { d[ks] = r; changed = true }
                } else if let v = d[ks], restoreAll(v, vault: vault, key: ks) {
                    changed = true
                }
            }
        } else if let a = o as? NSMutableArray {
            for i in 0..<a.count {
                if let s = a[i] as? String {
                    let r = vault.restore(s)
                    if r != s { a[i] = r; changed = true }
                } else if restoreAll(a[i], vault: vault, key: key) {
                    changed = true
                }
            }
        }
        return changed
    }

    private static func get(_ o: Any, _ path: [Any]) -> Any? {
        var cur: Any? = o
        for p in path {
            if let k = p as? String { cur = (cur as? NSDictionary)?[k] }
            else if let i = p as? Int, let a = cur as? NSArray, i < a.count { cur = a[i] }
            else { return nil }
        }
        return cur
    }

    private static func set(_ o: Any, _ path: [Any], _ value: String) {
        guard let last = path.last, let parent = get(o, Array(path.dropLast())) else { return }
        if let k = last as? String, let d = parent as? NSMutableDictionary { d[k] = value }
        else if let i = last as? Int, let a = parent as? NSMutableArray, i < a.count { a[i] = value }
    }
}
