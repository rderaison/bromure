import CryptoKit
import Foundation

/// One workspace's table of personal data ↔ stand-ins.
///
/// Stand-ins are derived from the value with a per-workspace HMAC key, so the
/// same name always gets the same stand-in — across turns (the conversation
/// the agent resends stays byte-identical, so prompt caching keeps working)
/// and across app restarts (the key persists; the table itself never touches
/// disk, it's rebuilt as values are seen again).
///
/// Stand-ins look like the real thing (a pronounceable name, an
/// `@example.com` address, a phone number in the same format, a Luhn-valid
/// card, an SSN in the never-issued 9xx range) and are checked against the
/// dictionary and every other entry, so restoring them can't touch ordinary
/// text.
final class PIIVault: @unchecked Sendable {

    // MARK: Registry

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [UUID: PIIVault] = [:]

    static func forProfile(_ id: UUID) -> PIIVault {
        registryLock.lock(); defer { registryLock.unlock() }
        if let v = registry[id] { return v }
        let v = PIIVault(secret: loadSecret(for: id))
        registry[id] = v
        return v
    }

    private static func loadSecret(for id: UUID) -> Data {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/pii", isDirectory: true)
        let file = dir.appendingPathComponent("\(id.uuidString).key")
        if let d = try? Data(contentsOf: file), d.count == 32 { return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let d = Data(bytes)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
        return d
    }

    // MARK: Entries

    enum Kind: String, Sendable {
        case name, email, phone, ssn, card, address, identifier

        init(_ label: PIILabel) {
            switch label {
            case .givenName, .surname: self = .name
            case .email: self = .email
            case .phone: self = .phone
            case .ssn: self = .ssn
            case .creditCard: self = .card
            case .streetName, .buildingNumber, .secondaryAddress: self = .address
            default: self = .identifier
            }
        }

        /// Matched regardless of case (names, emails); identifiers are exact.
        var caseInsensitive: Bool { self == .name || self == .email }
    }

    struct Entry: Sendable {
        let real: String
        let surrogate: String
        let kind: Kind
        /// Replaced wherever it appears, not only where it was detected.
        /// False for names that are also ordinary words ("Will", "Grace").
        let everywhere: Bool
    }

    private let lock = NSLock()
    private let key: SymmetricKey
    private var byReal: [String: Entry] = [:]           // normKey(kind, real)
    private var bySurrogate: [String: Entry] = [:]      // normKey(kind, surrogate)
    private var usedSurrogates: Set<String> = []        // lowercased
    private var version = 0
    private var forwardRegex: (version: Int, ci: NSRegularExpression?, cs: NSRegularExpression?)?
    private var restoreRegex: (version: Int, ci: NSRegularExpression?, cs: NSRegularExpression?)?
    private var sortedSurrogates: [String] = []         // lowercased, sorted
    private(set) var maxSurrogateLength = 0

    init(secret: Data) {
        key = SymmetricKey(data: secret)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return byReal.isEmpty
    }

    private static func normKey(_ kind: Kind, _ s: String) -> String {
        kind.caseInsensitive ? kind.rawValue + "|" + s.lowercased() : kind.rawValue + "|" + s
    }

    /// The stand-in for `real`, created on first sight.
    @discardableResult
    func learn(_ real: String, label: PIILabel) -> Entry {
        lock.lock(); defer { lock.unlock() }
        return learnLocked(real, kind: Kind(label))
    }

    private func learnLocked(_ real: String, kind: Kind) -> Entry {
        let k = Self.normKey(kind, real)
        if let e = byReal[k] { return e }
        var counter = 0
        var s: String
        repeat {
            s = PIISurrogates.make(kind: kind, real: real,
                                   rng: PIISurrogates.RNG(key: key, seed: "\(kind.rawValue)|\(real.lowercased())|\(counter)"))
            counter += 1
        } while counter < 64 && (usedSurrogates.contains(s.lowercased())
                                 || byReal[Self.normKey(kind, s)] != nil
                                 || s.lowercased() == real.lowercased())
        let everywhere: Bool
        switch kind {
        case .name:
            let lower = real.lowercased()
            everywhere = (real as NSString).length >= 4 && !PIISurrogates.isCommonWord(lower)
        case .email, .ssn, .card: everywhere = true
        case .phone, .identifier: everywhere = (real as NSString).length >= 6
        case .address: everywhere = (real as NSString).length >= 8 && real.contains(where: \.isNumber)
        }
        let e = Entry(real: real, surrogate: s, kind: kind, everywhere: everywhere)
        byReal[k] = e
        bySurrogate[Self.normKey(kind, s)] = e
        usedSurrogates.insert(s.lowercased())
        let i = sortedSurrogates.firstIndex { $0 > s.lowercased() } ?? sortedSurrogates.count
        sortedSurrogates.insert(s.lowercased(), at: i)
        maxSurrogateLength = max(maxSurrogateLength, (s as NSString).length)
        version += 1
        return e
    }

    // MARK: Outbound

    /// Replace the detected `spans` and every known value in `text` with
    /// their stand-ins. Returns the new text and how many values it replaced.
    func forward(_ text: String, spans: [PIISpan]) -> (text: String, replaced: Int) {
        lock.lock(); defer { lock.unlock() }
        let ns = text as NSString
        var hits: [(range: NSRange, entry: Entry)] = []
        for sp in spans {
            let r = NSRange(location: sp.start, length: sp.length)
            hits.append((r, learnLocked(ns.substring(with: r), kind: Kind(sp.label))))
        }
        let (ci, cs) = forwardRegexes()
        let all = NSRange(location: 0, length: ns.length)
        for (re, insensitive) in [(ci, true), (cs, false)] {
            guard let re else { continue }
            for m in re.matches(in: text, range: all) {
                let matched = ns.substring(with: m.range)
                let e = insensitive
                    ? (byReal[Self.normKey(.name, matched)] ?? byReal[Self.normKey(.email, matched)])
                    : Self.firstExact(byReal, matched)
                if let e, e.everywhere { hits.append((m.range, e)) }
            }
        }
        guard !hits.isEmpty else { return (text, 0) }
        hits.sort { $0.range.location != $1.range.location
            ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        let out = NSMutableString()
        var cursor = 0
        var n = 0
        for h in hits where h.range.location >= cursor {
            out.append(ns.substring(with: NSRange(location: cursor, length: h.range.location - cursor)))
            let matched = ns.substring(with: h.range)
            out.append(Self.applyCase(of: matched, reference: h.entry.real, to: h.entry.surrogate))
            cursor = NSMaxRange(h.range)
            n += 1
        }
        out.append(ns.substring(from: cursor))
        return (out as String, n)
    }

    private static func firstExact(_ table: [String: Entry], _ s: String) -> Entry? {
        for kind in [Kind.phone, .ssn, .card, .address, .identifier] {
            if let e = table[normKey(kind, s)] { return e }
        }
        return nil
    }

    private func forwardRegexes() -> (NSRegularExpression?, NSRegularExpression?) {
        if let r = forwardRegex, r.version == version { return (r.ci, r.cs) }
        let entries = Array(byReal.values).filter(\.everywhere)
        let ci = Self.alternation(entries.filter { $0.kind.caseInsensitive }.map(\.real), caseInsensitive: true)
        let cs = Self.alternation(entries.filter { !$0.kind.caseInsensitive }.map(\.real), caseInsensitive: false)
        forwardRegex = (version, ci, cs)
        return (ci, cs)
    }

    // MARK: Inbound

    /// Put the real values back in place of stand-ins in `text`. With
    /// `jsonFragment`, `text` is raw JSON (a streamed tool-call argument), so
    /// the real value is escaped for a JSON string.
    func restore(_ text: String, jsonFragment: Bool = false) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !bySurrogate.isEmpty else { return text }
        let (ci, cs) = restoreRegexes()
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var hits: [(NSRange, String)] = []
        for (re, insensitive) in [(ci, true), (cs, false)] {
            guard let re else { continue }
            for m in re.matches(in: text, range: all) {
                let matched = ns.substring(with: m.range)
                let e = insensitive
                    ? (bySurrogate[Self.normKey(.name, matched)] ?? bySurrogate[Self.normKey(.email, matched)])
                    : Self.firstExact(bySurrogate, matched)
                guard let e else { continue }
                var real = matched == e.surrogate ? e.real
                    : Self.applyCase(of: matched, reference: e.surrogate, to: e.real)
                if jsonFragment { real = Self.jsonEscape(real) }
                hits.append((m.range, real))
            }
        }
        guard !hits.isEmpty else { return text }
        hits.sort { $0.0.location < $1.0.location }
        let out = NSMutableString()
        var cursor = 0
        for (r, real) in hits where r.location >= cursor {
            out.append(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            out.append(real)
            cursor = NSMaxRange(r)
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }

    /// Where to cut a streamed `text` so a stand-in split across chunks is
    /// held back until it's whole: the start of a trailing partial (or
    /// complete-but-maybe-longer) stand-in, else the end. UTF-16 offset.
    func holdback(_ text: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let ns = text as NSString
        let len = ns.length
        guard !sortedSurrogates.isEmpty, len > 0 else { return len }
        let from = max(0, len - maxSurrogateLength)
        let lower = ns.lowercased as NSString
        for p in from..<len {
            if p > 0, Self.isWordUnit(ns.character(at: p - 1)) { continue }
            let suffix = lower.substring(from: p)
            // First surrogate ≥ suffix: a prefix match sorts right there.
            var lo = 0, hi = sortedSurrogates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sortedSurrogates[mid] < suffix { lo = mid + 1 } else { hi = mid }
            }
            if lo < sortedSurrogates.count, sortedSurrogates[lo].hasPrefix(suffix) { return p }
        }
        return len
    }

    private func restoreRegexes() -> (NSRegularExpression?, NSRegularExpression?) {
        if let r = restoreRegex, r.version == version { return (r.ci, r.cs) }
        let entries = Array(bySurrogate.values)
        let ci = Self.alternation(entries.filter { $0.kind.caseInsensitive }.map(\.surrogate), caseInsensitive: true)
        let cs = Self.alternation(entries.filter { !$0.kind.caseInsensitive }.map(\.surrogate), caseInsensitive: false)
        restoreRegex = (version, ci, cs)
        return (ci, cs)
    }

    // MARK: Helpers

    private static func isWordUnit(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return true }   // a surrogate half: part of a letter
        return s.properties.isAlphabetic || s.properties.numericType != nil
    }

    /// One regex matching any of `values` as a whole token (not inside a
    /// longer word or number), longest first.
    private static func alternation(_ values: [String], caseInsensitive: Bool) -> NSRegularExpression? {
        guard !values.isEmpty else { return nil }
        let body = values.sorted { ($0 as NSString).length > ($1 as NSString).length }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(body))(?![\\p{L}\\p{N}])",
                                        options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Carry `matched`'s casing (all caps, all lower, Capitalized) over to
    /// `target`; an exact `reference` (the canonical form) maps to `target`.
    static func applyCase(of matched: String, reference: String, to target: String) -> String {
        if matched == reference { return target }
        let letters = matched.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return target }
        if letters.allSatisfy({ $0.properties.isUppercase }), letters.count > 1 { return target.uppercased() }
        if letters.allSatisfy({ $0.properties.isLowercase }) { return target.lowercased() }
        if letters.first?.properties.isUppercase == true,
           letters.dropFirst().allSatisfy({ !$0.properties.isUppercase }) {
            return target.prefix(1).uppercased() + target.dropFirst().lowercased()
        }
        return target
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}

// MARK: - Stand-in generation

enum PIISurrogates {
    /// Deterministic byte stream: HMAC-SHA256(key, seed ‖ block).
    struct RNG {
        let key: SymmetricKey
        let seed: String
        private var block = 0
        private var buf: [UInt8] = []

        init(key: SymmetricKey, seed: String) { self.key = key; self.seed = seed }

        mutating func next(_ n: Int) -> Int {
            if buf.count < 2 {
                let mac = HMAC<SHA256>.authenticationCode(for: Data("\(seed)#\(block)".utf8), using: key)
                buf += Array(mac)
                block += 1
            }
            let v = (Int(buf[0]) << 8) | Int(buf[1])
            buf.removeFirst(2)
            return v % max(1, n)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[next(a.count)] }
        mutating func digit(nonZero: Bool = false) -> Character {
            Character(String(nonZero ? 1 + next(9) : next(10)))
        }
    }

    private static let onsets = ["b", "br", "d", "dr", "f", "g", "gr", "k", "kr", "l", "m", "n", "p",
                                 "pr", "r", "s", "st", "t", "tr", "v", "z", "th", "sh", "ch", "j", "h", "w"]
    private static let vowels = ["a", "e", "i", "o", "u", "a", "e", "o", "ai", "ea", "io", "ou"]
    private static let codas = ["n", "r", "l", "s", "th", "nd", "rn", "ll", "x", "m", "k", "v", "", ""]

    /// A pronounceable made-up word ("Brelond", "Taviox"), not a dictionary word.
    static func word(_ rng: inout RNG, capitalized: Bool = true) -> String {
        var w = ""
        for _ in 0..<10 {
            w = rng.pick(onsets) + rng.pick(vowels) + rng.pick(onsets) + rng.pick(vowels) + rng.pick(codas)
            if (5...9).contains(w.count), !isCommonWord(w) { break }
        }
        return capitalized ? w.prefix(1).uppercased() + w.dropFirst() : w
    }

    static func make(kind: PIIVault.Kind, real: String, rng: RNG) -> String {
        var rng = rng
        switch kind {
        case .name:
            return PIIVault.applyCase(of: real, reference: "", to: word(&rng))
        case .email:
            return "\(word(&rng, capitalized: false)).\(word(&rng, capitalized: false))@example.com"
        case .ssn:
            // Area 9xx is never issued: a stand-in can't be someone's SSN.
            var first = true
            return String(real.map { c -> Character in
                guard c.isASCII, c.isNumber else { return c }
                defer { first = false }
                return first ? "9" : rng.digit()
            })
        case .card:
            return card(real, &rng)
        case .phone:
            // Keep a leading "+CC" country code and the format; new digits.
            var out = ""
            var inCountryCode = real.hasPrefix("+")
            var firstLocal = true
            for c in real {
                if c.isASCII, c.isNumber {
                    if inCountryCode { out.append(c); continue }
                    out.append(rng.digit(nonZero: firstLocal))
                    firstLocal = false
                } else {
                    if inCountryCode, c != "+" { inCountryCode = false }
                    out.append(c)
                }
            }
            return out
        case .address:
            return real.split(separator: " ", omittingEmptySubsequences: false).map { part -> String in
                let p = String(part)
                if streetWords.contains(p.lowercased().trimmingCharacters(in: .punctuationCharacters)) { return p }
                if p.contains(where: \.isNumber) { return shape(p, &rng) }
                if p.contains(where: \.isLetter) {
                    return PIIVault.applyCase(of: p, reference: "", to: word(&rng))
                }
                return p
            }.joined(separator: " ")
        case .identifier:
            return shape(real, &rng)
        }
    }

    /// Same shape, new characters: digit → digit, letter → letter (same case).
    static func shape(_ s: String, _ rng: inout RNG) -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz")
        return String(s.map { c -> Character in
            if c.isASCII, c.isNumber { return rng.digit() }
            if c.isASCII, c.isLetter {
                let l = letters[rng.next(letters.count)]
                return c.isUppercase ? Character(l.uppercased()) : l
            }
            return c
        })
    }

    /// A Luhn-valid number with the card's length and separators, in the 4000
    /// test range.
    private static func card(_ real: String, _ rng: inout RNG) -> String {
        let count = real.filter { $0.isASCII && $0.isNumber }.count
        guard count >= 2 else { return shape(real, &rng) }
        var digits: [UInt8] = [4, 0, 0, 0]
        while digits.count < count - 1 { digits.append(UInt8(rng.next(10))) }
        digits = Array(digits.prefix(count - 1))
        for check in 0...9 where PIIText.isLuhnValid(digits + [UInt8(check)]) {
            digits.append(UInt8(check)); break
        }
        var i = 0
        return String(real.map { c -> Character in
            guard c.isASCII, c.isNumber, i < digits.count else { return c }
            defer { i += 1 }
            return Character(String(digits[i]))
        })
    }

    static func isStreetWord(_ w: String) -> Bool { streetWords.contains(w) }

    private static let streetWords: Set<String> = [
        "st", "street", "ave", "avenue", "rd", "road", "blvd", "boulevard", "ln", "lane", "dr", "drive",
        "way", "ct", "court", "pl", "place", "sq", "square", "hwy", "highway", "pkwy", "parkway", "ter",
        "terrace", "cir", "circle", "apt", "suite", "ste", "unit", "floor", "fl", "rue", "avenida", "calle",
        "via", "strasse", "straße", "weg", "platz", "laan", "straat", "rua", "chemin", "allée", "impasse",
        "n", "s", "e", "w", "ne", "nw", "se", "sw", "north", "south", "east", "west", "no", "#",
    ]

    /// Lower-case dictionary words ("will", "mark", "grace"): a name that is
    /// also one is only replaced where the model saw a name.
    nonisolated(unsafe) private static var dictionary: Set<String>? = nil
    private static let dictLock = NSLock()

    static func isCommonWord(_ lower: String) -> Bool {
        dictLock.lock(); defer { dictLock.unlock() }
        if dictionary == nil {
            var set = Set<String>()
            if let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
                text.enumerateLines { line, _ in
                    // Capitalized entries are proper nouns (names): not "common".
                    if let f = line.first, f.isLowercase { set.insert(line) }
                }
            }
            dictionary = set
        }
        return dictionary!.contains(lower)
    }
}
