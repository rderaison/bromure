import Foundation

/// Parser for an existing `~/.gitconfig` (or any file in git's config format).
///
/// Two things are worth lifting out of a real config:
///
///  • **Identity** — `[user] name/email`, which populates the editor's Git
///    Identity fields instead of retyping them.
///  • **Embedded tokens** — the common trick for non-interactive HTTPS auth is
///    to bake a token into a URL rewrite:
///
///        [url "https://ghp_xxx@github.com/"]
///            insteadOf = https://github.com/
///        [url "https://oauth2:glpat-xxx@gitlab.com/"]
///            insteadOf = https://gitlab.com/
///
///    Each of those becomes a `GitHTTPSCredential`, which means the real token
///    stays on the host and the VM only ever sees the fake — the proxy swaps it
///    back on outbound requests, exactly like a hand-entered token. Importing is
///    therefore strictly safer than copying the user's config into the guest.
///
/// Entries that name a host but carry no token (`[credential "https://host"]
/// username = …`, or a plain `insteadOf` with no credentials in the URL) are
/// counted as `skippedNoToken` so the UI can say what it ignored rather than
/// silently dropping them.
///
/// Format notes (git-config(1)): INI-like; `#`/`;` comments; sections as
/// `[section]` or `[section "subsection"]` where the subsection is
/// case-SENSITIVE and backslash-escaped; keys are case-insensitive; a bare key
/// means boolean true; values may be quoted and may continue across lines with
/// a trailing backslash.
enum GitConfigImport {

    struct Identity: Equatable {
        var name: String
        var email: String
        var isEmpty: Bool { name.isEmpty && email.isEmpty }
    }

    struct Entry: Equatable {
        let host: String
        let username: String
        let token: String
    }

    struct Result: Equatable {
        let identity: Identity
        let entries: [Entry]
        /// Host-ish entries we recognized but couldn't use (no token in them).
        let skippedNoToken: Int
    }

    enum Error: LocalizedError {
        case unreadable
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return NSLocalizedString(
                    "The file isn't readable as text.", comment: "")
            case .nothingFound:
                return NSLocalizedString(
                    "No git identity or credentials found in that file.", comment: "")
            }
        }
    }

    // MARK: - Parse

    static func parse(_ text: String) throws -> Result {
        var identity = Identity(name: "", email: "")
        var entries: [Entry] = []
        var skipped = 0
        var seen = Set<String>()          // host|username, first wins

        var section = ""                  // lowercased
        var subsection = ""               // case-preserved

        for raw in unfoldContinuations(text) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                (section, subsection) = parseHeader(line)
                // A URL rewrite's credentials live in the SUBSECTION itself:
                // [url "https://token@github.com/"].
                if section == "url", let e = credential(fromURL: subsection) {
                    if seen.insert("\(e.host)|\(e.username)").inserted { entries.append(e) }
                } else if section == "url", !subsection.isEmpty {
                    if hostOnly(subsection) != nil { skipped += 1 }
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }   // bare bool key
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))

            switch (section, key) {
            case ("user", "name"):  if identity.name.isEmpty { identity.name = value }
            case ("user", "email"): if identity.email.isEmpty { identity.email = value }
            case ("credential", "username"):
                // A username hint with no token — useful context, but nothing
                // to swap, so report rather than import.
                if hostOnly(subsection) != nil { skipped += 1 }
            default:
                // Some configs put the token in the VALUE instead of the
                // subsection, e.g. `[url] insteadOf`-style rewrites written the
                // other way round, or `[remote "x"] url = https://tok@host/…`.
                if key == "url" || key == "insteadof" || key == "pushinsteadof",
                   let e = credential(fromURL: value) {
                    if seen.insert("\(e.host)|\(e.username)").inserted { entries.append(e) }
                }
            }
        }

        guard !identity.isEmpty || !entries.isEmpty || skipped > 0 else {
            throw Error.nothingFound
        }
        return Result(identity: identity, entries: entries, skippedNoToken: skipped)
    }

    static func parse(_ data: Data) throws -> Result {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { throw Error.unreadable }
        return try parse(text)
    }

    // MARK: - Pieces

    /// `[section]` / `[section "sub"]` / `[section.sub]` → (lowercased section,
    /// subsection with escapes resolved).
    private static func parseHeader(_ line: String) -> (String, String) {
        var body = line
        if body.hasPrefix("[") { body.removeFirst() }
        if let close = body.lastIndex(of: "]") { body = String(body[..<close]) }
        body = body.trimmingCharacters(in: .whitespaces)

        if let q = body.firstIndex(of: "\"") {
            let name = body[..<q].trimmingCharacters(in: .whitespaces).lowercased()
            var sub = String(body[body.index(after: q)...])
            if sub.hasSuffix("\"") { sub.removeLast() }
            // git escapes `\` and `"` inside the subsection.
            sub = sub.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\", with: "\\")
            return (name, sub)
        }
        // Legacy dotted form: [url.https://…] — split on the FIRST dot only.
        if let dot = body.firstIndex(of: ".") {
            return (String(body[..<dot]).lowercased(),
                    String(body[body.index(after: dot)...]))
        }
        return (body.lowercased(), "")
    }

    /// Pull `user:token@host` out of a URL. Returns nil when there is no
    /// userinfo (nothing to swap) or no host.
    ///
    /// Both shapes appear in the wild:
    ///   https://TOKEN@github.com/           → username "", token TOKEN
    ///   https://user:TOKEN@github.com/      → username user, token TOKEN
    /// A bare-token URL is normalized to git's conventional placeholder user so
    /// the generated `.git-credentials` line stays valid.
    static func credential(fromURL string: String) -> Entry? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard let schemeEnd = s.range(of: "://") else { return nil }
        let afterScheme = s[schemeEnd.upperBound...]
        // userinfo ends at the LAST '@' before the first '/' of the path.
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }

        let userinfo = String(authority[..<at])
        let hostPart = String(authority[authority.index(after: at)...])
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard !host.isEmpty, !userinfo.isEmpty else { return nil }

        var username: String
        var token: String
        if let colon = userinfo.firstIndex(of: ":") {
            username = String(userinfo[..<colon])
            token = String(userinfo[userinfo.index(after: colon)...])
        } else {
            username = ""
            token = userinfo
        }
        username = percentDecode(username)
        token = percentDecode(token)
        // Classic GitHub basic-auth puts the TOKEN in the user field and a
        // dummy password after it (`https://<token>:x-oauth-basic@github.com`).
        // Treating that password as the token would both lose the real one and
        // ship a useless credential, so swap the halves.
        if token == "x-oauth-basic" || token == "x-oauth2" {
            token = username
            username = "x-access-token"
        }
        guard !token.isEmpty, token != "x-access-token" else { return nil }
        if username.isEmpty { username = "x-access-token" }
        return Entry(host: host.lowercased(), username: username, token: token)
    }

    /// The host of a credential-ish URL that carries no userinfo.
    private static func hostOnly(_ string: String) -> String? {
        guard let schemeEnd = string.range(of: "://") else { return nil }
        let after = string[schemeEnd.upperBound...]
        let end = after.firstIndex(of: "/") ?? after.endIndex
        let authority = String(after[..<end])
        guard authority.firstIndex(of: "@") == nil else { return nil }
        let host = authority.split(separator: ":").first.map(String.init) ?? authority
        return host.isEmpty ? nil : host
    }

    /// Join lines ending in an odd number of backslashes (git's continuation).
    private static func unfoldContinuations(_ text: String) -> [String] {
        var out: [String] = []
        var pending = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            let trailing = l.reversed().prefix { $0 == "\\" }.count
            if trailing % 2 == 1 {
                pending += l.dropLast()          // drop the continuation slash
            } else {
                out.append(pending + l)
                pending = ""
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }

    /// Strip a `#`/`;` comment, honouring quotes (a token can contain neither
    /// unquoted, but a quoted value legitimately can).
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        var out = ""
        for ch in line {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); out.append(ch); continue }
            if (ch == "#" || ch == ";") && !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    private static func unquote(_ value: String) -> String {
        var v = value
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
