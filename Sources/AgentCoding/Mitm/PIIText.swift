import Foundation

// MARK: - PII detection: the pure text layer
//
// A Swift port of the deterministic half of National Design Studio's Rampart
// (github.com/nationaldesignstudio/rampart, CC BY 4.0): the validator-backed
// recognizers, the premask that hides their spans from the model, BERT's
// WordPiece tokenization with character offsets, and the span repair that
// turns per-token BIO labels into whole names. `PIIDetector` runs the model
// between these steps.
//
// Every offset in here is a UTF-16 offset, like the JavaScript it ports and
// like NSRegularExpression, so spans drop straight onto NSString ranges.

enum PIILabel: String, CaseIterable, Codable, Sendable {
    // Deterministic recognizers (premasked before the model runs).
    case ssn = "SSN"
    case creditCard = "CREDIT_CARD"
    case ipAddress = "IP_ADDRESS"
    case email = "EMAIL"
    case url = "URL"
    // Model labels.
    case givenName = "GIVEN_NAME"
    case surname = "SURNAME"
    case phone = "PHONE"
    case taxID = "TAX_ID"
    case bankAccount = "BANK_ACCOUNT"
    case routingNumber = "ROUTING_NUMBER"
    case governmentID = "GOVERNMENT_ID"
    case passport = "PASSPORT"
    case driversLicense = "DRIVERS_LICENSE"
    case buildingNumber = "BUILDING_NUMBER"
    case streetName = "STREET_NAME"
    case secondaryAddress = "SECONDARY_ADDRESS"
    case city = "CITY"
    case state = "STATE"
    case zipCode = "ZIP_CODE"

    var isName: Bool { self == .givenName || self == .surname }
}

struct PIISpan: Equatable, Sendable {
    var start: Int
    var end: Int
    var label: PIILabel
    var score: Double
    var heuristic: Bool

    var length: Int { end - start }
}

enum PIIText {

    // MARK: Recognizers

    /// Luhn checksum over a digit string.
    static func isLuhnValid(_ digits: [UInt8]) -> Bool {
        var sum = 0
        var double = false
        for d in digits.reversed() {
            var v = Int(d)
            if double { v *= 2; if v > 9 { v -= 9 } }
            sum += v
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// US SSN structure: area not 000/666/9xx, group not 00, serial not 0000.
    static func isValidSSN(_ d: [UInt8]) -> Bool {
        guard d.count == 9 else { return false }
        let area = Int(d[0]) * 100 + Int(d[1]) * 10 + Int(d[2])
        if area == 0 || area == 666 || area >= 900 { return false }
        if d[3] == 0 && d[4] == 0 { return false }
        if d[5...].allSatisfy({ $0 == 0 }) { return false }
        return true
    }

    private static func regex(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are literals; a bad one is a programming error.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let digitRun = regex(#"[0-9](?:[ .\-]?[0-9])*"#)
    private static let ssnShape = regex(#"^[0-9]{3}([ \-])[0-9]{2}\1[0-9]{4}$"#)
    private static let ssnWords = regex(#"(?i)\b(?:ssn|social security|social sec|ss#|tin|itin)\b"#)

    /// "SSN", "social security"… within the 40 characters before `at`.
    private static func ssnContext(_ ns: NSString, _ at: Int) -> Bool {
        let from = max(0, at - 40)
        let before = ns.substring(with: NSRange(location: from, length: at - from))
        return matches(ssnWords, before)
    }
    private static let textRules: [(PIILabel, NSRegularExpression)] = [
        (.email, regex(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)),
        (.url, regex(#"\bhttps?://[^\s<>"'\])}]+"#)),
        (.url, regex(#"\bwww\.[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?:/[^\s<>"'\])}]*)?"#)),
        (.ipAddress, regex(#"\b(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\b"#)),
        (.ipAddress, regex(#"(?<![:.\w])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4})(?![:.\w])"#)),
        (.ipAddress, regex(#"\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#)),
    ]

    /// The validator-backed recognizers: cards (Luhn) and SSNs over digit
    /// runs, then emails, URLs and IP/MAC addresses by pattern.
    static func heuristics(_ text: String) -> [PIISpan] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var spans: [PIISpan] = []
        for m in digitRun.matches(in: text, range: all) {
            var digits: [UInt8] = []
            var first = -1, last = -1
            for i in m.range.location..<NSMaxRange(m.range) {
                let c = ns.character(at: i)
                if c >= 0x30 && c <= 0x39 {
                    digits.append(UInt8(c - 0x30))
                    if first < 0 { first = i }
                    last = i
                }
            }
            // Separators must be consistent dashes or spaces (not the dots of
            // an IP address or a version), and a bare 9-digit run is only an
            // SSN when the text says so — code is full of 9-digit constants.
            let run = ns.substring(with: NSRange(location: first, length: last + 1 - first))
            let seps = Set(run.filter { !$0.isNumber })
            let label: PIILabel?
            switch digits.count {
            case 14, 15, 16:
                label = isLuhnValid(digits) && !seps.contains(".") && seps.count <= 1 ? .creditCard : nil
            case 9:
                let formatted = matches(ssnShape, run)
                label = isValidSSN(digits) && (formatted || (seps.isEmpty && ssnContext(ns, first))) ? .ssn : nil
            default:
                label = nil
            }
            if let label {
                spans.append(PIISpan(start: first, end: last + 1, label: label, score: 1, heuristic: true))
            }
        }
        for (label, re) in textRules {
            for m in re.matches(in: text, range: all) {
                spans.append(PIISpan(start: m.range.location, end: NSMaxRange(m.range),
                                     label: label, score: 1, heuristic: true))
            }
        }
        return spans
    }

    // MARK: Code gate

    private static let codeLine = regex(#"^\s*(?:\d+\x{2192})?\s*(?:(?:func|let|var|if|else|for|while|return|import|def|class|struct|enum|case|switch|guard|const|public|private|internal|static|fn|pub|use|package|try|throw|async|await|export|from|elif|except|with|lambda|do|end|begin|local|function|val|override|extension|protocol|typealias|defer|break|continue|default|echo|fi|then|done|esac|set|unset|sudo|cd|mkdir|rm|cp|mv)\b|//|/\*|\*/|#(?:include|import|define|if|endif|!)|@\w|[}\])]\s*[,;)]*\s*$)"#)
    private static let codeLineEnd = regex(#"(?:[{;]|\)\s*\{?|=>|->.*\{)\s*$"#)

    /// The parts of `text` worth showing the model: chunks of ~2000
    /// characters (whole lines) that don't read as source code. Agents read
    /// far more code than anything else; names in it are identifiers, and
    /// skipping it is most of the model's cost. The recognizers still run
    /// everywhere. JSON, CSV, logs and prose all pass.
    static func proseRanges(_ text: String, chunk: Int = 2000, threshold: Double = 0.4) -> [Range<Int>] {
        let ns = text as NSString
        var out: [Range<Int>] = []
        var start = 0
        while start < ns.length {
            var end = min(ns.length, start + chunk)
            if end < ns.length {
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: end, length: min(400, ns.length - end)))
                end = nl.location != NSNotFound ? nl.location + 1 : end
            }
            let piece = ns.substring(with: NSRange(location: start, length: end - start))
            var lines = 0, code = 0
            piece.enumerateLines { line, _ in
                // Blank and bracket-only lines ("{", "},") say nothing: JSON
                // is full of them, and so is code.
                guard line.contains(where: { !$0.isWhitespace && !"{}[](),;".contains($0) }) else { return }
                lines += 1
                if matches(codeLine, line) || matches(codeLineEnd, line) { code += 1 }
            }
            if lines == 0 || Double(code) / Double(lines) < threshold {
                if let last = out.last, last.upperBound == start { out[out.count - 1] = last.lowerBound..<end }
                else { out.append(start..<end) }
            }
            start = end
        }
        return out
    }

    // MARK: Merge

    /// Reduce overlapping spans to a disjoint set: higher score wins, then the
    /// longer span, then the recognizer. A partial overlap takes the byte
    /// union under the winner's label so nothing detected is dropped.
    static func merge(_ spans: [PIISpan]) -> [PIISpan] {
        let sorted = spans.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var out: [PIISpan] = []
        for span in sorted {
            guard let prev = out.last, span.start < prev.end else { out.append(span); continue }
            let winner = preferred(prev, span)
            let contains = (prev.start <= span.start && prev.end >= span.end)
                || (span.start <= prev.start && span.end >= prev.end)
            if contains {
                out[out.count - 1] = winner
            } else {
                var u = winner
                u.start = min(prev.start, span.start)
                u.end = max(prev.end, span.end)
                out[out.count - 1] = u
            }
        }
        return out
    }

    private static func preferred(_ a: PIISpan, _ b: PIISpan) -> PIISpan {
        if a.score != b.score { return a.score > b.score ? a : b }
        if a.length != b.length { return a.length > b.length ? a : b }
        return a.heuristic ? a : b
    }

    // MARK: Premask

    struct Masked {
        /// The text with every recognizer span replaced by `[LABEL]`.
        let text: String
        /// Per UTF-16 unit of `text`: the raw range it came from.
        let rawStart: [Int]
        let rawEnd: [Int]

        /// A span over `text` projected back onto the raw input.
        func project(_ s: PIISpan) -> PIISpan? {
            guard s.end > s.start, s.start < rawStart.count, s.end - 1 < rawEnd.count else { return nil }
            var p = s
            p.start = rawStart[s.start]
            p.end = rawEnd[s.end - 1]
            return p.end > p.start ? p : nil
        }
    }

    /// Hide the recognizer spans from the model behind `[LABEL]` sentinels —
    /// the model was trained on text masked the same way.
    static func premask(_ raw: String, _ spans: [PIISpan]) -> Masked {
        let units = Array(raw.utf16)
        var out: [UInt16] = []
        var rs: [Int] = [], re: [Int] = []
        out.reserveCapacity(units.count)
        rs.reserveCapacity(units.count)
        re.reserveCapacity(units.count)
        var cursor = 0
        for s in merge(spans) where s.start >= cursor {
            for i in cursor..<s.start { out.append(units[i]); rs.append(i); re.append(i + 1) }
            for u in "[\(s.label.rawValue)]".utf16 { out.append(u); rs.append(s.start); re.append(s.end) }
            cursor = s.end
        }
        for i in cursor..<units.count { out.append(units[i]); rs.append(i); re.append(i + 1) }
        return Masked(text: String(utf16CodeUnits: out, count: out.count), rawStart: rs, rawEnd: re)
    }

    // MARK: WordPiece

    struct Token {
        let id: Int32
        /// UTF-16 range in the tokenized text.
        let start: Int
        let end: Int
        /// A `##` continuation of the previous token's word.
        let isSubword: Bool
    }

    /// BERT uncased tokenization (BertNormalizer + BertPreTokenizer +
    /// WordPiece) that keeps each token's source range.
    struct WordPiece {
        let vocab: [String: Int32]
        let unk: Int32
        let cls: Int32
        let sep: Int32
        static let maxCharsPerWord = 100

        init(vocab: [String: Int32]) {
            self.vocab = vocab
            unk = vocab["[UNK]"] ?? 100
            cls = vocab["[CLS]"] ?? 101
            sep = vocab["[SEP]"] ?? 102
        }

        init(vocabFile: URL) throws {
            let text = try String(contentsOf: vocabFile, encoding: .utf8)
            var v: [String: Int32] = [:]
            var i: Int32 = 0
            text.enumerateLines { line, _ in
                v[line] = i
                i += 1
            }
            self.init(vocab: v)
        }

        func tokenize(_ text: String) -> [Token] {
            // Fold (lowercase + NFD + strip marks, as BertNormalizer does)
            // scalar by scalar, keeping each folded scalar's source range.
            var folded: [Unicode.Scalar] = []
            var fStart: [Int] = [], fEnd: [Int] = []
            folded.reserveCapacity(text.utf16.count)
            var off = 0
            for sc in text.unicodeScalars {
                let w = sc.utf16.count
                let v = sc.value
                if v < 0x80 {
                    // ASCII fast path.
                    let lower = (v >= 0x41 && v <= 0x5A) ? Unicode.Scalar(v + 32)! : sc
                    folded.append(lower); fStart.append(off); fEnd.append(off + w)
                } else {
                    for f in String(sc).lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
                    where !Self.isMark(f) {
                        folded.append(f); fStart.append(off); fEnd.append(off + w)
                    }
                }
                off += w
            }

            var tokens: [Token] = []
            var word: [Unicode.Scalar] = []
            var wordFrom = 0     // index into `folded` of the word's first scalar
            func flushWord() {
                guard !word.isEmpty else { return }
                pieces(of: word, at: wordFrom, fStart: fStart, fEnd: fEnd, into: &tokens)
                word.removeAll(keepingCapacity: true)
            }
            for (i, sc) in folded.enumerated() {
                if Self.isControl(sc) { flushWord(); continue }
                if Self.isWhitespace(sc) { flushWord(); continue }
                if Self.isPunctuation(sc) || Self.isCJK(sc) {
                    flushWord()
                    word = [sc]; wordFrom = i
                    flushWord()
                    continue
                }
                if word.isEmpty { wordFrom = i }
                word.append(sc)
            }
            flushWord()
            return tokens
        }

        /// Greedy longest-match-first WordPiece over one word.
        private func pieces(of word: [Unicode.Scalar], at from: Int,
                            fStart: [Int], fEnd: [Int], into out: inout [Token]) {
            let rangeStart = fStart[from], rangeEnd = fEnd[from + word.count - 1]
            if word.count > Self.maxCharsPerWord {
                out.append(Token(id: unk, start: rangeStart, end: rangeEnd, isSubword: false))
                return
            }
            var found: [Token] = []
            var start = 0
            while start < word.count {
                var end = word.count
                var hit: Int32? = nil
                while start < end {
                    var s = start > 0 ? "##" : ""
                    s.unicodeScalars.append(contentsOf: word[start..<end])
                    if let id = vocab[s] { hit = id; break }
                    end -= 1
                }
                guard let id = hit else {
                    out.append(Token(id: unk, start: rangeStart, end: rangeEnd, isSubword: false))
                    return
                }
                found.append(Token(id: id, start: fStart[from + start], end: fEnd[from + end - 1],
                                   isSubword: start > 0))
                start = end
            }
            out.append(contentsOf: found)
        }

        static func isMark(_ s: Unicode.Scalar) -> Bool {
            switch s.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
        static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
            if s == " " || s == "\t" || s == "\n" || s == "\r" { return true }
            return s.properties.generalCategory == .spaceSeparator
        }
        static func isControl(_ s: Unicode.Scalar) -> Bool {
            if s == "\t" || s == "\n" || s == "\r" { return false }
            if s.value == 0 || s.value == 0xFFFD { return true }
            switch s.properties.generalCategory {
            case .control, .format: return true
            default: return false
            }
        }
        static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
                return true
            }
            switch s.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation:
                return true
            default: return false
            }
        }
        static func isCJK(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
                || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
        }
    }

    // MARK: Windows

    /// Split `tokens` into model windows of at most `budget` tokens that
    /// overlap by `overlap`, never cutting a word, so an entity on a seam sits
    /// whole inside one of them.
    static func windows(_ tokens: [Token], budget: Int = 500, overlap: Int = 64) -> [Range<Int>] {
        guard !tokens.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var i = 0
        while i < tokens.count {
            var j = min(i + budget, tokens.count)
            if j < tokens.count {
                var k = j
                while k > i + 1 && tokens[k].isSubword { k -= 1 }
                if k > i + 1 { j = k }
            }
            out.append(i..<j)
            if j == tokens.count { break }
            var next = max(j - overlap, i + 1)
            while next > i + 1 && tokens[next].isSubword { next -= 1 }
            i = next
        }
        return out
    }

    // MARK: BIO → spans

    /// One labeled token out of the model.
    struct Tagged {
        let index: Int          // position in the token array
        let label: PIILabel
        let begins: Bool        // B- (vs I-)
        let score: Double
        let start: Int
        let end: Int
        let isSubword: Bool
    }

    /// Merge consecutive tokens into entities: a B- starts one, a matching
    /// I- (or a `##` piece, whatever its prefix) extends it. Scores average.
    static func mergeBIO(_ tagged: [Tagged]) -> [PIISpan] {
        var out: [PIISpan] = []
        var cur: (label: PIILabel, start: Int, end: Int, sum: Double, n: Int, last: Int)? = nil
        func flush() {
            if let c = cur {
                out.append(PIISpan(start: c.start, end: c.end, label: c.label,
                                   score: c.sum / Double(c.n), heuristic: false))
            }
            cur = nil
        }
        for t in tagged {
            if var c = cur, c.label == t.label, c.last == t.index - 1, (!t.begins || t.isSubword) {
                c.end = t.end; c.sum += t.score; c.n += 1; c.last = t.index
                cur = c
            } else {
                flush()
                cur = (t.label, t.start, t.end, t.score, 1, t.index)
            }
        }
        flush()
        return out
    }

    // MARK: Repair

    static let extendScore = 0.15
    private static let connector = regex(#"^[\s'\x{2019}.\-]*$"#)
    private static let leftParticle = regex(#"([\p{Lu}][\p{L}\p{M}\x{2019}']{0,3})([\s'\x{2019}.\-]{1,3})$"#)
    private static let rightParticle = regex(#"^([\s'\x{2019}.\-]{1,3})([\p{Lu}][\p{L}\p{M}\x{2019}']{0,3})"#)

    /// Keep spans at or above `anchor`, pull in weaker same-label fragments
    /// joined to them by name connectors, merge such neighbours, and let names
    /// swallow capitalized particles ("de", "Mc", an initial).
    static func repair(_ text: String, _ spans: [PIISpan], anchor: Double) -> [PIISpan] {
        let ns = text as NSString
        var kept = spans.filter { $0.score >= anchor }
        var candidates = spans.filter { $0.score >= extendScore && $0.score < anchor }
        var changed = true
        var iters = 0
        while changed && iters < 32 {
            changed = false
            iters += 1
            for i in stride(from: candidates.count - 1, through: 0, by: -1) {
                let c = candidates[i]
                if kept.contains(where: { canBridge(ns, c, $0) }) {
                    kept.append(c)
                    candidates.remove(at: i)
                    changed = true
                }
            }
            let merged = mergeConnected(ns, kept)
            if merged.count != kept.count
                || zip(merged, kept.sorted { ($0.start, $0.end) < ($1.start, $1.end) })
                    .contains(where: { $0.start != $1.start || $0.end != $1.end }) {
                changed = true
            }
            kept = merged
            for i in kept.indices {
                let r = rescueParticles(ns, kept[i], kept, i)
                if r.start != kept[i].start || r.end != kept[i].end { kept[i] = r; changed = true }
            }
        }
        return kept.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func isInitial(_ ns: NSString, _ idx: Int) -> Bool {
        guard idx >= 0, idx < ns.length else { return false }
        let c = ns.substring(with: NSRange(location: idx, length: 1))
        guard c.unicodeScalars.first?.properties.isUppercase == true else { return false }
        guard idx > 0 else { return true }
        let p = ns.substring(with: NSRange(location: idx - 1, length: 1))
        return p.unicodeScalars.first?.properties.isAlphabetic != true
    }

    private static func canBridge(_ ns: NSString, _ a: PIISpan, _ b: PIISpan) -> Bool {
        guard a.label == b.label else { return false }
        let (l, r) = a.start <= b.start ? (a, b) : (b, a)
        guard r.start >= l.end else { return false }
        guard r.start - l.end <= 8 else { return false }
        let gap = ns.substring(with: NSRange(location: l.end, length: r.start - l.end))
        guard matches(connector, gap) else { return false }
        if gap.contains("."), !isInitial(ns, l.end - 1) { return false }
        return true
    }

    private static func mergeConnected(_ ns: NSString, _ spans: [PIISpan]) -> [PIISpan] {
        var out: [PIISpan] = []
        for s in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let p = out.last, canBridge(ns, p, s) {
                var m = p
                m.end = max(p.end, s.end)
                m.score = max(p.score, s.score)
                out[out.count - 1] = m
            } else {
                out.append(s)
            }
        }
        return out
    }

    private static func rescueParticles(_ ns: NSString, _ span: PIISpan, _ all: [PIISpan], _ me: Int) -> PIISpan {
        guard span.label.isName else { return span }
        var leftBound = 0, rightBound = ns.length
        for (i, o) in all.enumerated() where i != me {
            if o.end <= span.start && o.end > leftBound { leftBound = o.end }
            if o.start >= span.end && o.start < rightBound { rightBound = o.start }
        }
        var s = span
        // Look only at the few characters a particle can occupy.
        let lFrom = max(0, span.start - 12)
        let left = ns.substring(with: NSRange(location: lFrom, length: span.start - lFrom))
        if let m = leftParticle.firstMatch(in: left, range: NSRange(location: 0, length: (left as NSString).length)) {
            let word = (left as NSString).substring(with: m.range(at: 1))
            let sep = (left as NSString).substring(with: m.range(at: 2))
            if matches(connector, sep), !sep.contains(".") || (word as NSString).length == 1,
               span.start - m.range.length >= leftBound {
                s.start = span.start - m.range.length
            }
        }
        let rTo = min(ns.length, span.end + 12)
        let right = ns.substring(with: NSRange(location: span.end, length: rTo - span.end))
        if let m = rightParticle.firstMatch(in: right, range: NSRange(location: 0, length: (right as NSString).length)) {
            let sep = (right as NSString).substring(with: m.range(at: 1))
            if !sep.contains("."), span.end + m.range.length <= rightBound {
                s.end = span.end + m.range.length
            }
        }
        return s
    }
}
