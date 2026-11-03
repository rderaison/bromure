import Foundation

/// Secrets in a command line, taken out before it's recorded (the Security
/// Timeline) or uploaded (the org event stream): `net.flow`'s argv and tool
/// command, `tool.use`'s input summary, `command.run`'s command. A key with a
/// known scheme prefix becomes its fingerprint label (`[GitHub token
/// #3f9a1c2e]`, as everywhere else); a password, header value or `--token`
/// argument becomes `***`.
enum CommandLineRedactor {
    static let mask = "***"

    /// Event fields that carry command lines (at any depth: a flow's
    /// `processes[].argv`, its `agent.command`).
    static let commandFields: Set<String> = ["argv", "command", "input_summary", "cmd"]

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let knownTokens = re(
        #"\b(?:sk-ant-[A-Za-z0-9_-]{10,}|sk-(?:proj-|svcacct-|or-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}"#
        + #"|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|xox[abp]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}"#
        + #"|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}"#
        + #"|pypi-[A-Za-z0-9_-]{20,}|dop_v1_[a-f0-9]{20,}|xai-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}"#
        + #"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,})"#)
    /// `scheme://user:password@host`
    private static let urlUserinfo = re(#"([a-z][a-z0-9+.-]*://[^/\s:@'"]+):[^@\s/'"]+@"#)

    // Each pattern below matches up to where its value starts, with the
    // value's opening quote (if any) in group 2; `value(…)` then takes the
    // value itself: a quoted one through its matching quote, spaces and all,
    // an unquoted one up to a space or quote (Finding CWE-532: "Cookie flags
    // and secrets past the first space are still stored and uploaded" — a
    // value stopped at the first space, so `-u "alice:my hunter2"` kept
    // "hunter2" and a Cookie header kept every pair after the first).

    /// `curl -u user:password`, `-uuser:password`, `--user`, `--proxy-user`,
    /// and `-u` / `-U` closing a cluster of short flags (`-su user:pw`,
    /// `-fsSLu user:pw`, `-sLuuser:pw`: Finding CWE-532, "A curl -u password
    /// clustered with other short flags is stored and uploaded"). Case-
    /// insensitive, so `[a-z0-9#]*u` is -u and -U alike; curl's -0 -4 -6 -#
    /// cluster too (`-4u user:pw`).
    /// (`mysql -pSECRET` is left alone: `-p` is a port or `mkdir -p` elsewhere).
    /// Short `-u` / `-U` mean user:password only to curl (`rsync -u` is
    /// "update", its `host:path` a remote path; Finding CWE-670, "Command
    /// redaction erases rsync paths, PWD, and token: URLs that are not
    /// secrets"): `userFlagIsCurl` checks the command — a cluster ending in
    /// u (`-fsSLu`) included. The long forms are always userinfo.
    private static let userFlag = re(#"((?:^|\s)(?:-[a-z0-9#]*?u|--user|--proxy-user)(?:\s+|=)?)(['"]?)"#)
    /// The command a flag at `location` belongs to is curl: a word named
    /// `curl` (any path, any case) since the start of its shell segment. The
    /// segment starts after an unquoted, unescaped `;` `&` `|` followed by a
    /// space (or the end) or a newline not escaped — never at `2>&1`, `&>`,
    /// `>|`, a quoted `a;b` or a URL's `a=1&b=2`; inside `(`…`)` or
    /// backticks a segment of its own, the outer one resuming after — so
    /// `bash -c 'curl …'` and `/usr/bin/curl` count and `rsync -u` doesn't.
    /// Erring toward curl only masks more.
    private static func userFlagIsCurl(_ ns: NSString, before location: Int) -> Bool {
        let chars = Array(ns.substring(to: location).unicodeScalars)
        var start = 0
        // `(`…`)` and backticks nest a segment; their closer resumes the
        // outer one (`curl -o $(mktemp) -u …`, a URL's `Foo_(bar)`).
        var outer: [Int] = []
        var inBacktick = false
        var quote: Unicode.Scalar? = nil
        var i = 0
        func spaceOrEnd(_ j: Int) -> Bool { j >= chars.count || chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\", q == "\"" { i += 1 }
            } else if c == "\\" {
                i += 1                                   // escaped: `\&`, a backslash-newline
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "(" || (c == "`" && !inBacktick) {
                outer.append(start)
                start = i + 1
                if c == "`" { inBacktick = true }
            } else if c == ")" || c == "`" {
                if c == "`" { inBacktick = false }
                if let o = outer.popLast() { start = o }
            } else if c == "\n" {
                start = i + 1
            } else if c == ";" || c == "|" || c == "&" {
                // Redirects, not separators: `2>&1`, `&>`, `>|` (clobber).
                let redirect = (c == "&" && ((i > 0 && chars[i - 1] == ">") || (i + 1 < chars.count && chars[i + 1] == ">")))
                    || (c == "|" && i > 0 && chars[i - 1] == ">")
                if !redirect, spaceOrEnd(i + 1) || (i + 1 < chars.count && (chars[i + 1] == "&" || chars[i + 1] == "|")) {
                    start = i + 1
                }
            }
            i += 1
        }
        let segment = String(String.UnicodeScalarView(chars[min(start, chars.count)...]))
        return segment.split(whereSeparator: { " \t\n'\"()`".contains($0) })
            .contains { ($0.split(separator: "/").last ?? $0).lowercased() == "curl" }
    }

    /// curl's `-b` / `--cookie name=value; …` (a value without `=` is a
    /// cookie file, and `-b` is `git checkout -b`'s branch: both kept;
    /// `--cookie-jar` is a path), and `-b` closing a cluster of short flags
    /// (`-sb`, `-fsSLb`, `-4b`, `-sbname=value`) when the command is curl, as
    /// `-u` does (Finding CWE-532, "Clustered curl -b leaves cookie values in
    /// the timeline and the org upload").
    /// The cluster is lazy: curl starts a glued argument at the FIRST `b`
    /// (`-sbAWSALB=x` is the cookie `AWSALB=x`), and the `=` must stay in the
    /// value for it to read as a cookie. The short flag is case-sensitive, as
    /// curl's are: `-B` is `--use-ascii` and takes nothing, so `-fsSLB -b
    /// s=x` is a cluster then the real cookie, and `-fsSLB URL` keeps its URL
    /// (Finding CWE-532, "A curl -B cluster is read as -b, so the real cookie
    /// is uploaded"). A `b` glued to `=` is `gluedCookie`'s.
    private static let cookieFlag = re(#"((?:^|\s)(?:(?-i:-[a-zA-Z0-9#]*?b)(?!=)(?:\s+)?|--cookie(?:\s+|=)))(['"]?)"#)
    /// A short `-b` glued to `=` (`-b=x`, `-sb=x`, `-sb="$SECRET"`): curl
    /// keeps that `=` in its argument, so the argument always holds one and
    /// is always sent as a Cookie header (`-sb=hunter2` sends
    /// `Cookie: =hunter2`), never read as a file (Finding CWE-532, "Glued
    /// equals stays in curl's cookie argument and is uploaded"). The first
    /// `b` of the cluster only: `-sbab=x` is the cookie `ab=x`. Case-sensitive
    /// like `cookieFlag` (`-B=x` is no cookie).
    private static let gluedCookie = re(#"((?:^|\s)(?-i:-[ac-zA-Z0-9#]*b=))(['"]?)"#)
    /// curl's `-E` / `--cert` / `--proxy-cert certificate:passphrase`: the
    /// passphrase after the first `:` (a value without one is a path). `-E`
    /// is case-sensitive (`-e` is the referer) and may close a cluster.
    private static let certFlag = re(#"((?:^|\s)(?:(?-i:-[a-zA-Z0-9#]*?E)(?:\s+|=)?|--cert(?:\s+|=)|--proxy-cert(?:\s+|=)))(['"]?)"#)
    /// `Authorization: Bearer x`, `X-Api-Key: x`, `Cookie: …`, `*-Token: x`.
    /// Group 2 is the quote opening the whole header argument
    /// (`-H 'Cookie: a=1; b=2'`): the value runs to its match.
    private static let header = re(
        #"()(['"]?)((?:proxy-)?authorization|x-api-key|api-key|x-auth-token|cookie|x-[a-z0-9-]*-token)(\s*:\s*)((?:bearer|basic|token|digest)\s+)?"#)
    /// `--password value`, `--token value`, … and curl's own secret-taking
    /// options (`--pass` / `--proxy-pass` key passphrases, `--oauth2-bearer`,
    /// `--tlspassword` / `--proxy-tlspassword`).
    private static let secretFlag = re(
        #"(--(?:password|passwd|token|secret|api-key|apikey|access-key|secret-key|private-key|auth-token|pass|proxy-pass|oauth2-bearer|tlspassword|proxy-tlspassword)(?:\s+|=))(['"]?)"#)
    /// `PASSWORD=x`, `api_key=x`, `?access_token=x`, `"token": "x"`. The key
    /// is taken whole, and the secret word ends it or a `_`/`-`/`.` follows
    /// (`API_TOKEN_V2`, not `tokens:list`); the shell's own `PWD` / `OLDPWD`
    /// is a directory, not a password (`DB_PWD` still is).
    private static let keyValue = re(
        #"((?<![A-Za-z0-9_.-])(?!(?:old)?pwd['"]?\s*[=:])[A-Za-z0-9_.-]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|credential|private[_-]?key|access[_-]?key)(?:[_.-][A-Za-z0-9_.-]*)?['"]?\s*[=:]\s*)(['"]?)"#)

    /// The value starting at `start` (UTF-16): through the matching `quote`
    /// when there is one (to the end if it's never closed), else while no
    /// space, quote or `stops` character comes; an unquoted cookie value
    /// goes on across its `; name=value` pairs (the sentry's argv is the
    /// process's arguments joined by spaces, its quotes gone).
    private static func valueEnd(_ ns: NSString, from start: Int, quote: String, stops: String,
                                 cookiePairs: Bool = false) -> Int {
        let n = ns.length
        if !quote.isEmpty {
            let q = ns.range(of: quote, options: [], range: NSRange(location: start, length: n - start))
            return q.location == NSNotFound ? n : q.location
        }
        let stop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"" + stops))
        func run(_ i: Int) -> Int {
            var j = i
            // A surrogate (half a non-BMP character) is never a stop.
            while j < n {
                if let u = UnicodeScalar(ns.character(at: j)), stop.contains(u) { break }
                j += 1
            }
            return j
        }
        var end = run(start)
        while cookiePairs, end > start, end < n, ns.character(at: end - 1) == 0x3B /* ; */ {
            var k = end
            while k < n, ns.character(at: k) == 0x20 { k += 1 }
            let next = run(k)
            guard next > k, ns.substring(with: NSRange(location: k, length: next - k)).contains("=") else { break }
            end = next
        }
        return end
    }

    /// Every match of `rx`, its value (see `valueEnd`) replaced by what
    /// `masked(value)` returns (nil = left as is). The prefix (all groups
    /// but the value) is kept.
    private static func replacingValues(_ s: String, _ rx: NSRegularExpression, stops: String = "",
                                        when applies: (NSTextCheckingResult, NSString) -> Bool = { _, _ in true },
                                        cookiePairs: (NSTextCheckingResult, NSString) -> Bool = { _, _ in false },
                                        masked: (String) -> String?) -> String {
        let ns = s as NSString
        var out = ""
        var pos = 0
        // Resumed after each value: `^` and `\s` still see the whole string.
        while pos < ns.length,
              let m = rx.firstMatch(in: s, options: [.withoutAnchoringBounds, .withTransparentBounds],
                                    range: NSRange(location: pos, length: ns.length - pos)) {
            let start = m.range.location + m.range.length
            guard applies(m, ns) else {
                // Not this kind of value here (`rsync -u host:path`): kept.
                out += ns.substring(with: NSRange(location: pos, length: max(start, pos + 1) - pos))
                pos = max(start, pos + 1)
                continue
            }
            let q = m.range(at: 2)
            let quote = q.location == NSNotFound || q.length == 0 ? "" : ns.substring(with: q)
            let end = valueEnd(ns, from: start, quote: quote, stops: stops, cookiePairs: cookiePairs(m, ns))
            out += ns.substring(with: NSRange(location: pos, length: start - pos))
            let value = ns.substring(with: NSRange(location: start, length: end - start))
            out += value.isEmpty ? "" : (masked(value) ?? value)
            pos = end
        }
        if pos < ns.length { out += ns.substring(from: pos) }
        return out
    }

    static func redact(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        // Known schemes first: their label keeps rows correlatable.
        let ns = out as NSString
        var labelled = ""
        var last = 0
        for m in knownTokens.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            labelled += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            labelled += "[\(SecretFingerprint.label(ns.substring(with: m.range)))]"
            last = m.range.location + m.range.length
        }
        if last > 0 { out = labelled + ns.substring(from: last) }
        out = urlUserinfo.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                                   withTemplate: "$1:\(mask)@")
        // user:password — the user stays; a short -u / -U only for curl.
        out = replacingValues(out, userFlag, when: { m, ns in
            ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).hasPrefix("--")
                || userFlagIsCurl(ns, before: m.range.location)
        }) { v in
            v.firstIndex(of: ":").map { String(v[..<$0]) + ":" + mask }
        }
        // name=value cookies — a clustered short -b only for curl.
        out = replacingValues(out, gluedCookie, when: { m, ns in
            let flag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return flag == "-b=" || userFlagIsCurl(ns, before: m.range.location)
        }, cookiePairs: { _, _ in true }) { _ in mask }
        out = replacingValues(out, cookieFlag, when: { m, ns in
            let flag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return flag.hasPrefix("--") || flag == "-b" || userFlagIsCurl(ns, before: m.range.location)
        }, cookiePairs: { _, _ in true }) { $0.contains("=") ? mask : nil }
        // A client certificate's passphrase (curl only).
        out = replacingValues(out, certFlag, when: { m, ns in userFlagIsCurl(ns, before: m.range.location) }) { v in
            v.firstIndex(of: ":").map { String(v[..<$0]) + ":" + mask }
        }
        out = replacingValues(out, header, cookiePairs: { m, ns in
            ns.substring(with: m.range(at: 3)).lowercased() == "cookie"
        }) { _ in mask }
        out = replacingValues(out, secretFlag) { _ in mask }
        out = replacingValues(out, keyValue, stops: "&,}") { _ in mask }
        return out
    }

    /// An event's data with every command-line field redacted, at any depth.
    static func scrub(_ data: [String: AnyJSON]) -> [String: AnyJSON] {
        var out = data
        for (k, v) in data { out[k] = scrub(v, commandField: commandFields.contains(k)) }
        return out
    }

    private static func scrub(_ v: AnyJSON, commandField: Bool) -> AnyJSON {
        switch v {
        case .string(let s): return commandField ? .string(redact(s)) : v
        case .array(let a): return .array(a.map { scrub($0, commandField: commandField) })
        case .object(let o):
            var r: [String: AnyJSON] = [:]
            for (k, x) in o { r[k] = scrub(x, commandField: commandField || commandFields.contains(k)) }
            return .object(r)
        default: return v
        }
    }
}
