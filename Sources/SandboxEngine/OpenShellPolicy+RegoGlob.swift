import Foundation

// MARK: - Rego `glob.match` (regorus → globset)
//
// OpenShell evaluates its policy with regorus, whose `glob.match(pattern,
// delimiters, value)` rewrites every delimiter `d` as `/d/` (`:` becomes an
// opaque byte, a literal `/` too unless it is itself a delimiter; `[]` means
// `["."]`) and then matches with the `globset` crate (literal_separator on,
// backslash escapes, `{a,b}` alternates, byte-oriented). This is a port of that
// pipeline, so `/usr/lib/**/node` matches `/usr/lib/node` exactly when
// OpenShell says it does.

enum RegoGlob {
    private static let placeholder: UInt8 = 0

    /// `glob.match(pattern, delimiters, value)`. An invalid glob, or input
    /// carrying the internal placeholder, is a Rego error: no match.
    static func match(_ pattern: String, delimiters: [Character], _ value: String) -> Bool {
        let ds = delimiters.isEmpty ? ["."] : delimiters
        guard let p = unixStyle(pattern, ds), let v = unixStyle(value, ds),
              let tokens = parse(p) else { return false }
        let bytes = Array(v.utf8)
        if tokens.count == 1, case .recursivePrefix = tokens[0] { return !bytes.contains(0x0A) }
        return matches(tokens[...], bytes, 0) { $0 == bytes.count }
    }

    private static func unixStyle(_ s: String, _ ds: [Character]) -> String? {
        guard !s.utf8.contains(placeholder) else { return nil }
        var out = ds.contains("/") ? s : s.replacingOccurrences(of: "/", with: "\0")
        for d in ds where d != "/" {
            out = d == ":" ? out.replacingOccurrences(of: ":", with: "\0")
                           : out.replacingOccurrences(of: String(d), with: "/\(d)/")
        }
        return out
    }

    indirect enum Token {
        case literal([UInt8])
        case any                          // [^/]
        case zeroOrMore                   // [^/]*
        case recursivePrefix              // (?:/?|.*/)
        case recursiveSuffix              // /.*
        case recursiveZeroOrMore          // (?:/|/.*/)
        case byteClass(Set<UInt8>, ranges: [ClosedRange<UInt8>], negated: Bool)
        case alternates([[Token]])
    }

    // MARK: parser (globset's `Parser`)

    static func parse(_ glob: String) -> [Token]? {
        var chars = Array(glob)
        var i = 0
        var prev: Character?, cur: Character?
        var branches: [[Token]] = [[]]
        var altStack: [Int] = []
        func bump() -> Character? {
            prev = cur
            cur = i < chars.count ? chars[i] : nil
            if i < chars.count { i += 1 }
            return cur
        }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func push(_ t: Token) { branches[branches.count - 1].append(t) }
        func pushLiteral(_ c: Character) { push(.literal(Array(String(c).utf8))) }

        while let c = bump() {
            switch c {
            case "?": push(.any)
            case "*":
                let before = prev
                guard peek() == "*" else { push(.zeroOrMore); continue }
                _ = bump()
                if branches[branches.count - 1].isEmpty {
                    if let n = peek(), n != "/" {
                        push(.zeroOrMore); push(.zeroOrMore)
                    } else {
                        push(.recursivePrefix); _ = bump()
                    }
                    continue
                }
                if before != "/" {
                    if branches.count <= 1 || (before != "," && before != "{") {
                        push(.zeroOrMore); push(.zeroOrMore); continue
                    }
                }
                let isSuffix: Bool
                switch peek() {
                case nil: _ = bump(); isSuffix = true
                case let n? where (n == "," || n == "}") && branches.count >= 2: isSuffix = true
                case "/"?: _ = bump(); isSuffix = false
                default: push(.zeroOrMore); push(.zeroOrMore); continue
                }
                let last = branches[branches.count - 1].removeLast()
                switch last {
                case .recursivePrefix: push(.recursivePrefix)
                case .recursiveSuffix: push(.recursiveSuffix)
                default: push(isSuffix ? .recursiveSuffix : .recursiveZeroOrMore)
                }
            case "[":
                guard let t = parseClass(&chars, &i, &prev, &cur) else { return nil }
                push(t)
            case "{":
                altStack.append(branches.count)
                branches.append([])
            case "}":
                guard let start = altStack.popLast() else { return nil }
                let alts = Array(branches[start...])
                branches.removeSubrange(start...)
                guard !branches.isEmpty else { return nil }
                push(.alternates(alts))
            case ",":
                if altStack.isEmpty { pushLiteral(",") } else { branches.append([]) }
            case "\\":
                guard let n = bump() else { return nil }
                pushLiteral(n)
            default:
                pushLiteral(c)
            }
        }
        // Unclosed `{`: globset reports it at build time.
        guard altStack.isEmpty, branches.count == 1 else { return nil }
        return branches[0]
    }

    private static func parseClass(_ chars: inout [Character], _ i: inout Int,
                                   _ prev: inout Character?, _ cur: inout Character?) -> Token? {
        func bump() -> Character? {
            prev = cur
            cur = i < chars.count ? chars[i] : nil
            if i < chars.count { i += 1 }
            return cur
        }
        var ranges: [(Character, Character)] = []
        var negated = false
        if i < chars.count, chars[i] == "!" || chars[i] == "^" { negated = true; _ = bump() }
        var first = true, inRange = false
        while true {
            guard let c = bump() else { return nil }       // unclosed class
            switch c {
            case "]":
                if first { ranges.append(("]", "]")) } else {
                    if inRange { ranges.append(("-", "-")) }
                    return classToken(ranges, negated)
                }
            case "-":
                if first { ranges.append(("-", "-")) }
                else if inRange {
                    guard ranges[ranges.count - 1].0 <= "-" else { return nil }
                    ranges[ranges.count - 1].1 = "-"; inRange = false
                } else { inRange = true }
            default:
                if inRange {
                    guard ranges[ranges.count - 1].0 <= c else { return nil }
                    ranges[ranges.count - 1].1 = c
                } else { ranges.append((c, c)) }
                inRange = false
            }
            first = false
        }
    }

    /// The regex is byte-oriented: an ASCII range is a byte range; a
    /// non-ASCII member contributes its UTF-8 bytes.
    private static func classToken(_ rs: [(Character, Character)], _ negated: Bool) -> Token {
        var set = Set<UInt8>()
        var ranges: [ClosedRange<UInt8>] = []
        for (a, b) in rs {
            let ab = Array(String(a).utf8), bb = Array(String(b).utf8)
            if ab.count == 1, bb.count == 1 { ranges.append(ab[0]...max(ab[0], bb[0])) }
            else { set.formUnion(ab); set.formUnion(bb) }
        }
        return .byteClass(set, ranges: ranges, negated: negated)
    }

    // MARK: matcher (backtracking with continuation)

    private static func matches(_ ts: ArraySlice<[Token].Element>, _ v: [UInt8], _ pos: Int,
                                _ k: (Int) -> Bool) -> Bool {
        guard let t = ts.first else { return k(pos) }
        let rest = ts.dropFirst()
        let slash: UInt8 = 0x2F, nl: UInt8 = 0x0A
        switch t {
        case .literal(let bs):
            guard pos + bs.count <= v.count, Array(v[pos..<(pos + bs.count)]) == bs else { return false }
            return matches(rest, v, pos + bs.count, k)
        case .any:
            guard pos < v.count, v[pos] != slash else { return false }
            return matches(rest, v, pos + 1, k)
        case .zeroOrMore:
            var e = pos
            while true {
                if matches(rest, v, e, k) { return true }
                guard e < v.count, v[e] != slash else { return false }
                e += 1
            }
        case .byteClass(let set, let ranges, let negated):
            guard pos < v.count else { return false }
            let b = v[pos]
            let hit = set.contains(b) || ranges.contains { $0.contains(b) }
            // `/` is matchable here: only `?` / `*` honor literal_separator.
            guard hit != negated else { return false }
            return matches(rest, v, pos + 1, k)
        case .recursivePrefix:
            // "" | "/" | .*/
            if matches(rest, v, pos, k) { return true }
            if pos < v.count, v[pos] == slash, matches(rest, v, pos + 1, k) { return true }
            return anyThenSlash(v, pos) { matches(rest, v, $0, k) }
        case .recursiveSuffix:
            guard pos < v.count, v[pos] == slash else { return false }
            var e = pos + 1
            while true {
                if matches(rest, v, e, k) { return true }
                guard e < v.count, v[e] != nl else { return false }
                e += 1
            }
        case .recursiveZeroOrMore:
            guard pos < v.count, v[pos] == slash else { return false }
            if matches(rest, v, pos + 1, k) { return true }
            return anyThenSlash(v, pos + 1) { matches(rest, v, $0, k) }
        case .alternates(let alts):
            let nonEmpty = alts.filter { !$0.isEmpty }
            if nonEmpty.isEmpty { return matches(rest, v, pos, k) }
            return nonEmpty.contains { alt in matches(alt[...], v, pos) { matches(rest, v, $0, k) } }
        }
    }

    /// `.*/` from `pos`: try every following `/` (no newline crossed).
    private static func anyThenSlash(_ v: [UInt8], _ pos: Int, _ k: (Int) -> Bool) -> Bool {
        var e = pos
        while e < v.count, v[e] != 0x0A {
            if v[e] == 0x2F, k(e + 1) { return true }
            e += 1
        }
        return false
    }
}
