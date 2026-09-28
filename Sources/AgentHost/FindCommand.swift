import Foundation
import Darwin

/// `bromure-native __find …`: the GNU `find` subset client commands use with
/// `-printf` (BSD find has none) — the file browser's `-printf '%y%f\0'`,
/// the folder picker's `%f\n`, the task probe's `%T@\n`. One process: an
/// opendir/readdir walk, fstatat per entry, one buffered write. The `find`
/// shim hands any `-printf` call here; everything else stays BSD find's.
///
/// Understood: -L/-P/-H, start paths, -mindepth/-maxdepth, -name, -type,
/// -newermt (a date or @epoch), -true/-false, ! / -not, -a / -and,
/// -o / -or, ( ), and one -printf — %y %f %p %P %h %s %T@ %%, \0 \n \t \\.
/// Exit 1 if a path couldn't be read (as find does), 2 on a usage error.
enum FindCommand {
    static func run(_ args: [String]) -> Int32 {
        var follow = false
        var i = 0
        while i < args.count, ["-L", "-P", "-H"].contains(args[i]) {
            follow = args[i] == "-L"
            i += 1
        }
        var starts: [String] = []
        while i < args.count, !isExpressionStart(args[i]) {
            starts.append(args[i])
            i += 1
        }
        if starts.isEmpty { starts = ["."] }

        // Global options pulled out wherever they sit; the rest is the expression.
        var minDepth = 0, maxDepth = Int.max
        var format: [Piece]?
        var rest = Array(args[i...])
        var j = 0
        while j < rest.count {
            let t = rest[j]
            switch t {
            case "-mindepth", "-maxdepth", "-printf":
                guard j + 1 < rest.count else { return usage("\(t) needs an argument") }
                let v = rest[j + 1]
                if t == "-printf" { format = parseFormat(v) }
                else {
                    guard let n = Int(v), n >= 0 else { return usage("bad \(t) \(v)") }
                    if t == "-mindepth" { minDepth = n } else { maxDepth = n }
                }
                rest.removeSubrange(j...(j + 1))
                // A dangling -a/-and before the removed option leaves the
                // expression well-formed.
                if j > 0, ["-a", "-and"].contains(rest[j - 1]),
                   j == rest.count || [")", "-o", "-or"].contains(rest[j]) {
                    rest.remove(at: j - 1); j -= 1
                }
            default:
                j += 1
            }
        }
        let tokens = rest
        var parser = Parser(tokens: tokens)
        let expr: Expr
        do {
            expr = tokens.isEmpty ? .always : try parser.parse()
        } catch let e as FindError {
            return usage(e.message)
        } catch {
            return usage("\(error)")
        }
        let out = Output()
        let pieces = format ?? [.path, .literal("\n")]
        var walker = Walker(follow: follow, minDepth: minDepth, maxDepth: maxDepth,
                            expr: expr, pieces: pieces, out: out)
        for s in starts { walker.walk(start: s) }
        out.flush()
        return walker.failed ? 1 : 0
    }

    private static func isExpressionStart(_ a: String) -> Bool {
        a.hasPrefix("-") || a == "!" || a == "(" || a == ")"
    }

    private static func usage(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("find: \(why)\n".utf8))
        return 2
    }

    // MARK: Expression

    struct FindError: Error { let message: String }

    indirect enum Expr {
        case always, never
        case name(String)
        case type(Set<Character>)
        case newer(Double)
        case not(Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
    }

    /// GNU precedence: ( ) > ! > implicit/explicit and > or.
    struct Parser {
        let tokens: [String]
        var pos = 0

        mutating func parse() throws -> Expr {
            let e = try parseOr()
            guard pos == tokens.count else { throw FindError(message: "unexpected \(tokens[pos])") }
            return e
        }

        private mutating func parseOr() throws -> Expr {
            var lhs = try parseAnd()
            while pos < tokens.count, ["-o", "-or"].contains(tokens[pos]) {
                pos += 1
                lhs = .or(lhs, try parseAnd())
            }
            return lhs
        }

        private mutating func parseAnd() throws -> Expr {
            var lhs = try parseNot()
            while pos < tokens.count, !["-o", "-or", ")"].contains(tokens[pos]) {
                if ["-a", "-and"].contains(tokens[pos]) { pos += 1 }
                lhs = .and(lhs, try parseNot())
            }
            return lhs
        }

        private mutating func parseNot() throws -> Expr {
            guard pos < tokens.count else { throw FindError(message: "expression ends early") }
            if ["!", "-not"].contains(tokens[pos]) {
                pos += 1
                return .not(try parseNot())
            }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Expr {
            let t = tokens[pos]
            pos += 1
            func arg() throws -> String {
                guard pos < tokens.count else { throw FindError(message: "\(t) needs an argument") }
                defer { pos += 1 }
                return tokens[pos]
            }
            switch t {
            case "(":
                let e = try parseOr()
                guard pos < tokens.count, tokens[pos] == ")" else { throw FindError(message: "missing )") }
                pos += 1
                return e
            case "-true": return .always
            case "-false": return .never
            case "-name": return .name(try arg())
            case "-type":
                let v = try arg()
                let kinds = Set(v.split(separator: ",").compactMap(\.first))
                guard !kinds.isEmpty, kinds.isSubset(of: Set("fdlpsbc")) else {
                    throw FindError(message: "bad -type \(v)")
                }
                return .type(kinds)
            case "-newermt":
                let v = try arg()
                guard let when = FindCommand.parseDate(v) else { throw FindError(message: "can't parse date \(v)") }
                return .newer(when)
            default:
                throw FindError(message: "unsupported \(t)")
            }
        }
    }

    /// "@<epoch>", or a local "YYYY-MM-DD[ HH:MM[:SS]]".
    static func parseDate(_ s: String) -> Double? {
        if s.hasPrefix("@") { return Double(s.dropFirst()) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    // MARK: Format

    enum Piece: Equatable {
        case literal(String)
        case type, name, path, relative, parent, size, mtime
    }

    static func parseFormat(_ f: String) -> [Piece] {
        var out: [Piece] = []
        var lit = ""
        func flush() { if !lit.isEmpty { out.append(.literal(lit)); lit = "" } }
        let it = Array(f)
        var k = 0
        while k < it.count {
            let c = it[k]
            if c == "\\", k + 1 < it.count {
                switch it[k + 1] {
                case "0": lit.append("\0")
                case "n": lit.append("\n")
                case "t": lit.append("\t")
                case "\\": lit.append("\\")
                default: lit.append(it[k + 1])
                }
                k += 2
            } else if c == "%", k + 1 < it.count {
                let d = it[k + 1]
                k += 2
                let piece: Piece?
                switch d {
                case "y": piece = .type
                case "f": piece = .name
                case "p": piece = .path
                case "P": piece = .relative
                case "h": piece = .parent
                case "s": piece = .size
                case "T" where k < it.count && it[k] == "@": piece = .mtime; k += 1
                case "%": lit.append("%"); piece = nil
                default: lit.append("%"); lit.append(d); piece = nil
                }
                if let piece { flush(); out.append(piece) }
            } else {
                lit.append(c)
                k += 1
            }
        }
        flush()
        return out
    }

    // MARK: Walk

    /// Buffered stdout, raw bytes (names may not be UTF-8).
    final class Output {
        private var buf = [UInt8]()
        init() { buf.reserveCapacity(1 << 16) }
        func write(_ bytes: [UInt8]) {
            buf += bytes
            if buf.count >= 1 << 16 { flush() }
        }
        func write(_ s: String) { write(Array(s.utf8)) }
        func flush() {
            var off = 0
            while off < buf.count {
                let n = buf.withUnsafeBytes { Darwin.write(1, $0.baseAddress! + off, buf.count - off) }
                if n <= 0 { break }
                off += n
            }
            buf.removeAll(keepingCapacity: true)
        }
    }

    struct Walker {
        let follow: Bool
        let minDepth: Int
        let maxDepth: Int
        let expr: Expr
        let pieces: [Piece]
        let out: Output
        var failed = false
        /// Directories on the current path (dev, ino): -L must not loop.
        private var ancestors: Set<[UInt64]> = []

        init(follow: Bool, minDepth: Int, maxDepth: Int, expr: Expr, pieces: [Piece], out: Output) {
            self.follow = follow; self.minDepth = minDepth; self.maxDepth = maxDepth
            self.expr = expr; self.pieces = pieces; self.out = out
        }

        mutating func walk(start: String) {
            var st = stat()
            let ok = follow ? (stat(start, &st) == 0 || lstat(start, &st) == 0) : lstat(start, &st) == 0
            guard ok else { failed = true; return }
            // Printed as given ("a/" stays "a/"); children join without "//".
            var trimmed = start
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            visit(path: Array(start.utf8), start: Array(start.utf8), name: Array(baseName(trimmed).utf8),
                  st: st, depth: 0, join: Array(trimmed.utf8))
        }

        private func baseName(_ p: String) -> String {
            if p == "/" { return "/" }
            return (p as NSString).lastPathComponent
        }

        /// `join`: what children hang off (the path, less a trailing slash).
        private mutating func visit(path: [UInt8], start: [UInt8], name: [UInt8], st: stat, depth: Int,
                                    join: [UInt8]? = nil) {
            if depth >= minDepth, matches(expr, name: name, st: st) {
                emit(path: path, start: start, name: name, st: st)
            }
            guard depth < maxDepth, (st.st_mode & S_IFMT) == S_IFDIR else { return }
            let key = [UInt64(bitPattern: Int64(st.st_dev)), st.st_ino]
            guard !ancestors.contains(key) else { return }
            ancestors.insert(key)
            defer { ancestors.remove(key) }
            let dirPath = path + [0]
            guard let dir = dirPath.withUnsafeBufferPointer({ opendir(UnsafeRawPointer($0.baseAddress!)
                .assumingMemoryBound(to: CChar.self)) }) else { failed = true; return }
            defer { closedir(dir) }
            let fd = dirfd(dir)
            while let ent = readdir(dir) {
                let entName: [UInt8] = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                    Array(raw.prefix(Int(ent.pointee.d_namlen)))
                }
                if entName == [46] || entName == [46, 46] { continue }   // . and ..
                var cst = stat()
                let flags: Int32 = follow ? 0 : AT_SYMLINK_NOFOLLOW
                var rc = (entName + [0]).withUnsafeBufferPointer {
                    fstatat(fd, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), &cst, flags)
                }
                if rc != 0, follow {   // a broken link: the link itself, as GNU -L
                    rc = (entName + [0]).withUnsafeBufferPointer {
                        fstatat(fd, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self),
                                &cst, AT_SYMLINK_NOFOLLOW)
                    }
                }
                guard rc == 0 else { failed = true; continue }
                let base = join ?? path
                let child = base == [47] ? base + entName : base + [47] + entName
                visit(path: child, start: start, name: entName, st: cst, depth: depth + 1)
            }
        }

        private func typeChar(_ st: stat) -> Character {
            switch st.st_mode & S_IFMT {
            case S_IFDIR: return "d"
            case S_IFLNK: return "l"
            case S_IFIFO: return "p"
            case S_IFSOCK: return "s"
            case S_IFBLK: return "b"
            case S_IFCHR: return "c"
            default: return "f"
            }
        }

        private func matches(_ e: Expr, name: [UInt8], st: stat) -> Bool {
            switch e {
            case .always: return true
            case .never: return false
            case .name(let pat):
                return (name + [0]).withUnsafeBufferPointer { n in
                    fnmatch(pat, UnsafeRawPointer(n.baseAddress!).assumingMemoryBound(to: CChar.self), 0) == 0
                }
            case .type(let kinds): return kinds.contains(typeChar(st))
            case .newer(let t):
                return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 > t
            case .not(let x): return !matches(x, name: name, st: st)
            case .and(let a, let b): return matches(a, name: name, st: st) && matches(b, name: name, st: st)
            case .or(let a, let b): return matches(a, name: name, st: st) || matches(b, name: name, st: st)
            }
        }

        private func emit(path: [UInt8], start: [UInt8], name: [UInt8], st: stat) {
            var line = [UInt8]()
            for p in pieces {
                switch p {
                case .literal(let s): line += Array(s.utf8)
                case .type: line.append(UInt8(ascii: typeChar(st).unicodeScalars.first!))
                case .name: line += name
                case .path: line += path
                case .relative:
                    // Past the start and its slash.
                    if path.count > start.count { line += path[start.count...].drop(while: { $0 == 47 }) }
                case .parent:
                    if let slash = path.lastIndex(of: 47) { line += slash == 0 ? [47] : Array(path[..<slash]) }
                    else { line.append(46) }
                case .size: line += Array(String(st.st_size).utf8)
                case .mtime:
                    let ns = String(format: "%09ld", st.st_mtimespec.tv_nsec)
                    line += Array("\(st.st_mtimespec.tv_sec).\(ns)0".utf8)
                }
            }
            out.write(line)
        }
    }
}
