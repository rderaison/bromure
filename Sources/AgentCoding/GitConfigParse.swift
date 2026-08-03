import Foundation

/// Reader for git's config format, used by the onboarding scan to pull an
/// identity and any embedded credentials out of `~/.gitconfig` and
/// `~/.git-credentials`.
///
/// The credentials matter more than the identity: the common trick for
/// non-interactive HTTPS auth is to bake a token into a URL rewrite —
///
///     [url "https://ghp_xxx@github.com/"]  insteadOf = https://github.com/
///
/// — and lifting that into a `GitHTTPSCredential` means the real token stays on
/// the host while the VM sees only a fake the proxy swaps back. Importing is
/// therefore strictly safer than the file it came from, where the secret sits
/// in cleartext.
///
/// Format per git-config(1): INI-like; `#`/`;` comments; `[section]` or
/// `[section "subsection"]` (subsection case-sensitive, backslash-escaped);
/// case-insensitive keys; values may be quoted and may continue across lines
/// with a trailing backslash.
enum GitConfigParse {

    struct Result: Equatable {
        var identity: (name: String, email: String)
        var creds: [ConfigScan.GitCred]
        /// Recognized host entries that carried no token (nothing to swap).
        var skippedNoToken: Int

        static func == (a: Result, b: Result) -> Bool {
            a.identity == b.identity && a.creds == b.creds
                && a.skippedNoToken == b.skippedNoToken
        }
    }

    enum Error: LocalizedError {
        case nothingFound
        var errorDescription: String? {
            NSLocalizedString("No git identity or credentials found.", comment: "")
        }
    }

    static func parse(_ text: String) throws -> Result {
        var name = "", email = ""
        var creds: [ConfigScan.GitCred] = []
        var skipped = 0
        var seen = Set<String>()
        var section = "", subsection = ""

        func note(_ c: ConfigScan.GitCred) {
            if seen.insert("\(c.host)|\(c.username)").inserted { creds.append(c) }
        }

        for raw in unfold(text) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                (section, subsection) = header(line)
                // A URL rewrite carries its credentials in the SUBSECTION.
                if section == "url" {
                    if let c = credential(fromURL: subsection) { note(c) }
                    else if hostOnly(subsection) != nil { skipped += 1 }
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }   // bare bool
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))

            switch (section, key) {
            case ("user", "name"):  if name.isEmpty { name = value }
            case ("user", "email"): if email.isEmpty { email = value }
            case ("credential", "username"):
                if hostOnly(subsection) != nil { skipped += 1 }
            default:
                // Some configs put the credential in the VALUE instead:
                // `[remote "origin"] url = https://tok@host/…`.
                if ["url", "insteadof", "pushinsteadof"].contains(key),
                   let c = credential(fromURL: value) { note(c) }
            }
        }

        guard !name.isEmpty || !email.isEmpty || !creds.isEmpty || skipped > 0 else {
            throw Error.nothingFound
        }
        return Result(identity: (name, email), creds: creds, skippedNoToken: skipped)
    }

    /// Pull `user:token@host` out of a URL; nil when there's no userinfo (so
    /// nothing to swap) or no host.
    ///
    /// Shapes seen in the wild:
    ///   https://TOKEN@github.com/                → user "", token TOKEN
    ///   https://user:TOKEN@github.com/           → user user, token TOKEN
    ///   https://TOKEN:x-oauth-basic@github.com/  → classic GitHub: token is the
    ///                                              USER half, password a dummy
    static func credential(fromURL string: String) -> ConfigScan.GitCred? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard let scheme = s.range(of: "://") else { return nil }
        let afterScheme = s[scheme.upperBound...]
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }

        let userinfo = String(authority[..<at])
        let hostPart = String(authority[authority.index(after: at)...])
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard !host.isEmpty, !userinfo.isEmpty else { return nil }

        var username: String, token: String
        if let colon = userinfo.firstIndex(of: ":") {
            username = String(userinfo[..<colon])
            token = String(userinfo[userinfo.index(after: colon)...])
        } else {
            username = ""
            token = userinfo
        }
        username = username.removingPercentEncoding ?? username
        token = token.removingPercentEncoding ?? token

        // Classic GitHub basic-auth: token in the user field, dummy password.
        // Reading it the obvious way would import the dummy and lose the token.
        if token == "x-oauth-basic" || token == "x-oauth2" {
            token = username
            username = "x-access-token"
        }
        guard !token.isEmpty, token != "x-access-token" else { return nil }
        if username.isEmpty { username = "x-access-token" }
        return ConfigScan.GitCred(host: host.lowercased(), username: username, token: token)
    }

    /// Host of a credential-less URL — used to count what we recognized but
    /// couldn't import, so the UI can say so instead of dropping it silently.
    private static func hostOnly(_ s: String) -> String? {
        guard let scheme = s.range(of: "://") else { return nil }
        let after = s[scheme.upperBound...]
        let end = after.firstIndex(of: "/") ?? after.endIndex
        let authority = String(after[..<end])
        guard !authority.contains("@") else { return nil }
        let host = authority.split(separator: ":").first.map(String.init) ?? authority
        return host.isEmpty ? nil : host
    }

    private static func header(_ line: String) -> (String, String) {
        var body = line
        if body.hasPrefix("[") { body.removeFirst() }
        if let close = body.lastIndex(of: "]") { body = String(body[..<close]) }
        body = body.trimmingCharacters(in: .whitespaces)
        if let q = body.firstIndex(of: "\"") {
            let name = body[..<q].trimmingCharacters(in: .whitespaces).lowercased()
            var sub = String(body[body.index(after: q)...])
            if sub.hasSuffix("\"") { sub.removeLast() }
            sub = sub.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\", with: "\\")
            return (name, sub)
        }
        if let dot = body.firstIndex(of: ".") {      // legacy [url.https://…]
            return (String(body[..<dot]).lowercased(),
                    String(body[body.index(after: dot)...]))
        }
        return (body.lowercased(), "")
    }

    /// Join lines ending in an odd number of backslashes.
    private static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        var pending = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                pending += l.dropLast()
            } else {
                out.append(pending + l)
                pending = ""
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }

    /// Strip a `#`/`;` comment, honouring quotes.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false, escaped = false, out = ""
        for ch in line {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); out.append(ch); continue }
            if (ch == "#" || ch == ";") && !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    private static func unquote(_ v: String) -> String {
        var s = v
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        return s.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
