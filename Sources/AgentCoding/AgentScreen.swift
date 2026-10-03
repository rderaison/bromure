import Foundation

// How the beautified view reads a coding agent's terminal when the agent's
// structured channels (its transcript's typed errors, its hooks) have nothing
// to say. Two layers, in this order:
//
// 1. SHAPES (`AgentScreen`): a cursor beside a list of sibling options at the
//    bottom of the screen, a sign-in URL, a device code, a folder path. They
//    look the same whatever the agent's words are, in whatever language, and
//    survive an agent rewording its dialogs between versions.
// 2. WORDING (`AgentPhrases`): what each agent's chrome actually says, per
//    agent. None of the five agents translates its own UI (verified under
//    fr/de/ja/zh locales and their own language settings, 2026-10) — only
//    model output and passed-through provider messages vary — so this is a
//    drift problem, not a translation one: keep the table current, never
//    match the conversation (the caller drops lines the transcript echoes).

/// One selectable row of a dialog the agent put up ("1. Yes, proceed").
struct LoginOption: Equatable, Identifiable {
    let index: Int
    let label: String
    var id: Int { index }
}

enum AgentScreen {
    /// A dialog's options as they stand right now: what the cursor is on
    /// (arrow moves go from there) and where the list sits on screen.
    struct Menu: Equatable {
        var options: [LoginOption]
        var selected: Int?
        var firstOffset: Int
        var lastOffset: Int
        /// The rows carry their own numbers ("1. Yes"). Unnumbered rows
        /// ("❯ No, exit / Yes, I trust this folder") are numbered here.
        var numbered: Bool
    }

    /// Glyphs agents draw beside the highlighted row: Claude ❯, Codex ›,
    /// Kimi ▶/❯, omp ❯, others ➤ ►. `>` only before a number — bare it is
    /// also a quote / prompt marker.
    static let cursorGlyphs: [Character] = ["❯", "›", "▶", "➤", "►", "→"]

    /// The numbered options of a dialog that is up RIGHT NOW: 1…n below
    /// `after`, one of them under the selection cursor, and at the bottom
    /// of the screen (a footer and the box's edge may follow). A numbered
    /// list in the agent's own reply has no cursor and scrolls up. Falls
    /// back to an unnumbered list (the cursor row and the rows aligned with
    /// it) when the dialog doesn't number its rows.
    static func liveMenu(_ lines: [String], after from: Int) -> Menu? {
        numberedMenu(lines, after: from) ?? unnumberedMenu(lines, after: from)
    }

    private static func numberedMenu(_ lines: [String], after from: Int) -> Menu? {
        let rows = lines.enumerated().compactMap { i, l -> (Int, NumberedRow)? in
            guard i > from, let r = numberedRow(l) else { return nil }
            return (i, r)
        }
        // The LAST run 1…n: a list scrolled up above the dialog is earlier.
        guard let startAt = rows.lastIndex(where: { $0.1.index == 1 }) else { return nil }
        var run = [rows[startAt]]
        for r in rows[(startAt + 1)...] where r.1.index == run.count + 1 { run.append(r) }
        guard run.count >= 2, let cursor = run.first(where: { $0.1.cursor }),
              let first = run.first, let last = run.last else { return nil }
        guard tailIsFooter(lines, after: last.0) else { return nil }
        return Menu(options: run.map { LoginOption(index: $0.1.index, label: $0.1.label) },
                    selected: cursor.1.index, firstOffset: first.0, lastOffset: last.0, numbered: true)
    }

    /// "❯ No, exit" + "  Yes, I trust this folder": the cursor row and the
    /// rows whose text starts in the same column, contiguous. A row indented
    /// deeper, or a sentence under a short label, is that option's
    /// description. Never the agent's input box — a cursor glyph right
    /// under a horizontal rule — and only when the cursor row is the
    /// screen's last glyph row (an echoed prompt higher up isn't a dialog).
    private static func unnumberedMenu(_ lines: [String], after from: Int) -> Menu? {
        guard let cursorAt = lines.indices.last(where: { $0 > from && cursorColumn(lines[$0]) != nil }),
              let col = cursorColumn(lines[cursorAt]) else { return nil }
        let label = { (l: String) in String(unboxed(l).dropFirst(col)).trimmingCharacters(in: .whitespaces) }
        guard !label(lines[cursorAt]).isEmpty else { return nil }
        if let above = lines[..<cursorAt].last(where: { !unboxed($0).isEmpty }), isRule(above) { return nil }
        let sentence = { (s: String) in s.hasSuffix(".") || s.hasSuffix("。") }
        let cursorIsSentence = sentence(label(lines[cursorAt]))
        func isOption(_ i: Int) -> Bool? {   // nil = not part of the list
            let raw = unboxed(lines[i])
            guard !raw.isEmpty, !isRule(lines[i]) else { return nil }
            let lead = raw.prefix(while: { $0 == " " }).count
            if lead == col { return cursorIsSentence || !sentence(label(lines[i])) }
            if lead > col { return false }   // a description line
            return nil
        }
        var first = cursorAt, last = cursorAt
        while first - 1 > from, isOption(first - 1) != nil { first -= 1 }
        while last + 1 < lines.count, isOption(last + 1) != nil { last += 1 }
        let rows = (first...last).filter { $0 == cursorAt || isOption($0) == true }
        guard rows.count >= 2, tailIsFooter(lines, after: last) else { return nil }
        let options = rows.enumerated().map { LoginOption(index: $0.offset + 1, label: label(lines[$0.element])) }
        let selected = rows.firstIndex(of: cursorAt).map { $0 + 1 }
        return Menu(options: options, selected: selected,
                    firstOffset: rows.first ?? cursorAt, lastOffset: last, numbered: false)
    }

    /// A checklist the agent put up ("Select any you wish to enable."): rows
    /// with a check box — "❯ [✔] playwright", "  [ ] github", numbered or
    /// not — and, usually, a button row under them ("Enable selected").
    /// Enter on a row there only ticks it; the button submits.
    struct Checklist: Equatable {
        var options: [LoginOption]
        var checked: [Bool]
        /// The row the cursor is on (0-based); nil = on the button.
        var cursor: Int?
        /// The button's label, when the list has one (else Enter submits).
        var submitLabel: String?
        var firstOffset: Int
        var lastOffset: Int
    }

    static func checklist(_ lines: [String]) -> Checklist? {
        struct Row { let at: Int; let label: String; let checked: Bool; let cursor: Bool }
        func row(_ i: Int) -> Row? {
            var s = Substring(unboxed(lines[i]).trimmingCharacters(in: .whitespaces))
            var cursor = false
            if let g = s.first, cursorGlyphs.contains(g) || g == ">" {
                cursor = true
                s = s.dropFirst().drop(while: { $0 == " " || $0 == "\u{00a0}" })
            }
            let digits = s.prefix(while: \.isNumber)
            if !digits.isEmpty, s.dropFirst(digits.count).first == "." {
                s = s.dropFirst(digits.count + 1).drop(while: { $0 == " " })
            }
            guard s.first == "[", s.count >= 4 else { return nil }
            let mark = s[s.index(after: s.startIndex)]
            guard s[s.index(s.startIndex, offsetBy: 2)] == "]" else { return nil }
            let ticks: Set<Character> = ["✔", "✓", "x", "X", "*", "■", "●"]
            guard mark == " " || ticks.contains(mark) else { return nil }
            let label = s.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            return Row(at: i, label: label, checked: mark != " ", cursor: cursor)
        }
        // The last run of check rows on screen.
        guard let lastAt = lines.indices.last(where: { row($0) != nil }) else { return nil }
        var rows: [Row] = []
        var i = lastAt
        while i >= 0, let r = row(i) { rows.insert(r, at: 0); i -= 1 }
        // The button: the first glyph row under the list, without a box.
        var submit: String?
        var submitFocused = false
        var end = lastAt
        if let b = lines.indices.first(where: { $0 > lastAt && !unboxed(lines[$0]).trimmingCharacters(in: .whitespaces).isEmpty }),
           b <= lastAt + 2, !isRule(lines[b]) {
            var t = Substring(unboxed(lines[b]).trimmingCharacters(in: .whitespaces))
            if let g = t.first, cursorGlyphs.contains(g) {
                submitFocused = true
                t = t.dropFirst().drop(while: { $0 == " " || $0 == "\u{00a0}" })
            }
            // A short label, not a sentence (a footer explains the keys).
            if !t.isEmpty, t.count <= 40, !t.contains("·"), !t.hasSuffix(".") {
                submit = String(t)
                end = b
            } else {
                submitFocused = false
            }
        }
        guard tailIsFooter(lines, after: end) else { return nil }
        let cursor = rows.firstIndex(where: \.cursor)
        guard cursor != nil || submitFocused else { return nil }   // a live dialog has focus somewhere
        return Checklist(options: rows.enumerated().map { LoginOption(index: $0.offset + 1, label: $0.element.label) },
                         checked: rows.map(\.checked), cursor: cursor, submitLabel: submit,
                         firstOffset: rows.first?.at ?? lastAt, lastOffset: end)
    }

    /// The keystrokes that make a checklist read `want`, then submit it:
    /// to each row that has to change, Space; then Down onto the button and
    /// Enter (without a button, Enter on a row submits). Positions: rows
    /// 0…n-1, the button n — Down from the last row reaches it, Up from it
    /// goes back to the last row.
    static func checklistKeys(_ c: Checklist, want: [Bool]) -> [String] {
        let n = c.checked.count
        var at = c.cursor ?? n
        var keys: [String] = []
        func move(to i: Int) {
            keys += Array(repeating: i > at ? "Down" : "Up", count: abs(i - at))
            at = i
        }
        for i in 0..<n where i < want.count && want[i] != c.checked[i] {
            move(to: i)
            keys.append("Space")
        }
        if c.submitLabel != nil { move(to: n) }
        keys.append("Enter")
        return keys
    }

    /// Below the list: at most a few footer lines, blanks and box edges.
    private static func tailIsFooter(_ lines: [String], after last: Int) -> Bool {
        guard last + 1 < lines.count else { return true }
        return lines[(last + 1)...].filter { !unboxed($0).isEmpty && !isRule($0) }.count <= 3
    }

    /// Where a cursor row's label starts (in the unboxed line), when the
    /// line is one — "  ❯ Trust this folder" → 4.
    private static func cursorColumn(_ line: String) -> Int? {
        let s = unboxed(line)
        let lead = s.prefix(while: { $0 == " " }).count
        let rest = s.dropFirst(lead)
        guard let g = rest.first, cursorGlyphs.contains(g) else { return nil }
        let afterGlyph = rest.dropFirst()
        let gap = afterGlyph.prefix(while: { $0 == " " || $0 == "\u{00a0}" }).count
        guard gap >= 1 else { return nil }
        return lead + 1 + gap
    }

    private struct NumberedRow { let index: Int; let label: String; let cursor: Bool }

    /// "❯ 1. Yes", "› 2. No (esc)", "▶ 1. Approve once", "1) Yes", Grok's
    /// radio rows "1 (●) Yes, proceed" / "2 (○) No". The tagline after
    /// " · " is dropped ("1. Claude account with subscription · Pro, Max…").
    private static func numberedRow(_ line: String) -> NumberedRow? {
        let s = unboxed(line).trimmingCharacters(in: .whitespaces)
        var cursor = false
        var body = Substring(s)
        if let g = body.first, cursorGlyphs.contains(g) || g == ">" {
            cursor = true
            body = body.dropFirst().drop(while: { $0 == " " || $0 == "\u{00a0}" })
        }
        let digits = body.prefix(while: \.isNumber)
        guard let n = Int(digits), (1...9).contains(n) else { return nil }
        var rest = body.dropFirst(digits.count)
        if rest.first == "." || rest.first == ")" {
            rest = rest.dropFirst()
        } else if rest.hasPrefix(" (●)") || rest.hasPrefix(" (◉)") {
            cursor = true; rest = rest.dropFirst(4)
        } else if rest.hasPrefix(" (○)") || rest.hasPrefix(" ( )") {
            rest = rest.dropFirst(4)
        } else {
            return nil
        }
        guard rest.first == " " else { return nil }
        var label = rest.trimmingCharacters(in: .whitespaces)
        if let sep = label.range(of: " · ") { label = String(label[..<sep.lowerBound]) }
        guard !label.isEmpty else { return nil }
        return NumberedRow(index: n, label: label, cursor: cursor)
    }

    /// Numbered rows anywhere on screen ("❯ 1. Claude account…"), for menus
    /// whose cursor we don't need (a sign-in method list).
    static func numberedOptions(_ lines: [String]) -> [LoginOption] {
        lines.compactMap(numberedRow).map { LoginOption(index: $0.index, label: $0.label) }
    }

    /// The dialog's title: the nearest question above the options, else the
    /// nearest line of prose — never a bullet, box art, or the footer.
    /// Questions end in "?" or a full-width "？".
    static func title(_ lines: [String], before end: Int) -> String {
        let above = lines[0..<end].suffix(12).reversed()
        func prose(_ l: String) -> String? {
            let t = unboxed(l).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 90, t.contains(where: \.isLetter),
                  !t.hasPrefix("·"), !t.hasPrefix("•"), !t.hasPrefix("-"), !t.hasPrefix("—")
            else { return nil }
            return t
        }
        if let q = above.compactMap(prose).first(where: { $0.hasSuffix("?") || $0.hasSuffix("？") }) { return q }
        // A title drawn into the box's top edge ("╭─ Allow tool: bash ──").
        if let edge = above.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╭") }) {
            let t = edge.trimmingCharacters(in: CharacterSet(charactersIn: " ╭╮─┬"))
            if t.contains(where: \.isLetter) { return t }
        }
        return above.compactMap(prose).first ?? ""
    }

    /// What the dialog is about: its lines between the box's top edge (or 12
    /// lines up) and the options, minus the title. A dashed rule is inside
    /// the dialog (Claude frames a diff with ╌╌╌), not its edge.
    static func context(_ lines: [String], before first: Int, title: String) -> String {
        let edge = { (l: String) in isRule(l) && !l.contains("╌") && !l.contains("┄") }
        let start = lines[..<first].lastIndex(where: edge).map { $0 + 1 } ?? max(0, first - 12)
        return lines[max(start, first - 12)..<first]
            .map { unboxed($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != title && $0.contains(where: \.isLetter) }
            .joined(separator: "\n")
    }

    /// A line without the dialog box drawn around it ("│ ❯ 1. Yes   │") —
    /// the border and the one space after it go, the indentation inside the
    /// box stays (it carries the alignment of a list).
    static func unboxed(_ line: String) -> String {
        var s = Substring(line)
        let inner = s.drop(while: { $0 == " " })
        if let c = inner.first, "│┃|".contains(c) {
            s = inner.dropFirst()
            if s.first == " " { s = s.dropFirst() }
        }
        while let c = s.last, " │┃|".contains(c) { s = s.dropLast() }
        return String(s)
    }

    /// A box's top or bottom edge, or a rule across the screen.
    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { "─━═╭╮╰╯┌┐└┘╌┄".contains($0) }
    }

    // MARK: Sign-in shapes

    /// A sign-in URL on screen: an OAuth authorize page (Claude, omp), a
    /// device-code page (Grok, Kimi, Codex). Not the changelog link or the
    /// percent-encoded redirect_uri buried inside one. tmux `-J` joins the
    /// wrapped URL back into one line.
    static func signInURL(_ lines: [String]) -> String? {
        for line in lines {
            var rest = Substring(line)
            while let r = rest.range(of: "https://") {
                let url = String(rest[r.lowerBound...].prefix(while: { !$0.isWhitespace }))
                rest = rest[r.upperBound...]
                let low = url.lowercased()
                if low.contains("/oauth/authorize") || low.contains("/oauth2/device")
                    || low.contains("authorize_device") || low.contains("/codex/device")
                    || low.contains("user_code=") {
                    return url
                }
            }
        }
        return nil
    }

    /// A device code standing on its own line ("QZQD-KPB5"), or after a
    /// colon ("Verification code:  XXXX-YYYY").
    static func deviceCode(_ lines: [String]) -> String? {
        let pattern = #"(?:^|:\s*)([A-Z0-9]{4}-[A-Z0-9]{4,6})$"#
        for line in lines.reversed() {
            let t = unboxed(line).trimmingCharacters(in: .whitespaces)
            guard t.count <= 60, let r = t.range(of: pattern, options: .regularExpression) else { continue }
            let code = t[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if code.contains(where: \.isLetter) { return code }
        }
        return nil
    }

    /// Whether the sign-in waits for a code pasted back: an authorize URL
    /// whose redirect goes to a page that SHOWS the code (Claude's
    /// `code=true` flow) rather than to a loopback listener.
    static func wantsPastedCode(_ url: String) -> Bool {
        let low = url.lowercased()
        guard low.contains("/oauth/authorize") else { return false }
        if low.contains("code=true") { return true }
        guard let r = low.range(of: "redirect_uri=") else { return false }
        let redirect = (low[r.upperBound...].prefix(while: { $0 != "&" }).removingPercentEncoding ?? "")
        return !(redirect.contains("localhost") || redirect.contains("127.0.0.1"))
    }

    /// The folder a dialog is about: a line that is just an absolute path
    /// (Claude, Kimi, Grok), else the first home path mentioned in a line
    /// ("You are in /home/…" — Codex). Never a file it mentions (a log).
    static func folder(_ lines: [String]) -> String? {
        let isFile: (Substring) -> Bool = { $0.hasSuffix(".log") || $0.contains("/logs/") }
        let trimmed = lines.map { unboxed($0).trimmingCharacters(in: .whitespaces) }
        if let p = trimmed.first(where: { $0.hasPrefix("/") && !$0.contains(" ") && !isFile($0[...]) }) { return p }
        return trimmed.joined(separator: " ").split(separator: " ")
            .first(where: { ($0.hasPrefix("/home/") || $0.hasPrefix("/root/") || $0.hasPrefix("/Users/")) && !isFile($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;)")) }
    }
}

/// What each agent's chrome says, lowercased — the fallback layer. Apply
/// with `matches`, which normalizes typography (curly quotes, spacing) so
/// "You’ve hit your usage limit" and "you've hit your usage limit" agree.
/// Only the TUI's own strings belong here; provider messages vary.
enum AgentPhrases {
    enum Topic { case login, trust, permission, auth, quota, generic, footer, questionFooter }

    /// agent → topic → phrases. "*" applies to every agent.
    static let table: [String: [Topic: [String]]] = [
        "*": [
            .auth: [
                "api key is invalid", "invalid api key", "invalid x-api-key", "incorrect api key",
                "api key not valid", "didn't provide an api key", "invalid_api_key",
                "x-api-key header is invalid", "invalid access token", "authentication_error",
                "authentication error", "authentication failed", "invalid authentication",
                "401 unauthorized", "not authenticated", "invalid bearer token",
                "could not refresh token", "permission_error", "login expired", "session expired",
                "token has expired", "token expired", "oauth token", "sign in again", "re-authenticate",
                "subscription has expired", "subscription is invalid", "subscription expired",
                "requires login", "requires you to log in", "run login", "authentication required",
                "no api key", "missing api key", "run `/login`", "please run /login", "please log in",
                "not logged in",
            ],
            // "rate limit" alone is NOT here: an answer that talks about one
            // shares the screen.
            .quota: [
                "credit balance is too low", "usage limit reached", "reached your usage limit",
                "you've reached your usage", "hit your limit", "hit your usage limit",
                "insufficient_quota", "rate_limit", "rate-limit", "rate limit reached",
                "rate limit exceeded", "rate limited", "being rate limit", "quota exceeded",
                "exceeded your current quota", "overloaded_error", "session limit reached",
                "out of credits", "too many requests", "monthly spend limit",
            ],
            .generic: ["no model configured", "failed to run prompt", "exited with status"],
            .footer: [
                "↑/↓", "↑↓", "enter to select", "enter to confirm", "esc to cancel", "esc to close",
                "esc to exit", "esc close", "press enter to continue", "press enter to confirm",
                "enter to submit", "esc to go back", "↵ confirm", "enter select", "enter confirm",
                "up/down navigate", "ctrl+c:cancel",
            ],
            // Claude's AskUserQuestion picker: its own card answers it.
            .questionFooter: ["enter to select", "space to toggle"],
        ],
        "claude": [
            .login: ["select login method", "browser didn't open", "paste code here",
                     "not logged in", "please run /login", "run /login"],
            .auth: ["please run /login", "not logged in", "please log in"],
            .trust: ["yes, i trust this folder", "quick safety check", "trust the files in this",
                     "is this a project you created"],
            .permission: ["do you want to proceed", "do you want to make this edit", "do you want to create",
                          "do you want to allow", "requires confirmation", "don't ask again"],
        ],
        "codex": [
            .login: ["sign in with chatgpt", "sign in with your chatgpt", "sign in with device code",
                     "provide your own api key", "finish signing in via your browser",
                     "paste or type your api key"],
            .auth: ["could not be refreshed", "please log out and sign in again", "auth error code"],
            .trust: ["do you trust the contents of this directory", "allow codex to work in this folder",
                     "you are running codex in"],
            .permission: ["would you like to run the following command", "would you like to make the following edits",
                          "would you like to grant", "don't ask again"],
        ],
        "kimi": [
            .login: ["kimi login", "llm not set", "run /login or /provider", "sign in to kimi code",
                     "oauth login expired", "login required"],
            .auth: ["provider.auth_error", "authorization failed", "llm not set", "oauth login expired"],
            .quota: ["provider.rate_limit", "insufficient balance"],
            .trust: ["trust this folder?", "don't trust"],
            .permission: ["run this command?", "write this file?", "apply these edits?", "approve once",
                          "approve for this session"],
        ],
        "grok": [
            .login: ["grok login", "approve in your browser", "to sign in, open this url", "not signed in"],
            .auth: ["run /login to re-authenticate", "authentication rejected", "not signed in"],
            .quota: ["hit your weekly limit", "hit your free usage limit"],
            .trust: ["do you trust the contents of this directory"],
            .permission: ["yes, proceed", "no, reject", "don't ask again"],
        ],
        "omp": [
            .login: ["set up your providers", "select provider to login", "paste the authorization code",
                     "no models available", "no api key", "api key is not set", "missing api key",
                     "anthropic_api_key", "no model selected"],
            .auth: ["no api key found", "missing api key"],
            .permission: ["allow tool:"],
        ],
    ]

    /// The phrases for `topic`: the shared ones plus `agent`'s — or every
    /// agent's when the caller doesn't know which agent it is.
    static func phrases(_ topic: Topic, agent: String?) -> [String] {
        var out = table["*"]?[topic] ?? []
        if let agent, let own = table[agent] {
            out += own[topic] ?? []
        } else if agent == nil {
            for (key, topics) in table where key != "*" { out += topics[topic] ?? [] }
        }
        return out
    }

    /// Lowercased, curly quotes straightened, runs of spaces folded.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for (from, to) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("\u{00a0}", " ")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func matches(_ text: String, _ topic: Topic, agent: String?) -> Bool {
        let t = normalize(text)
        return phrases(topic, agent: agent).contains { t.contains($0) }
    }

    /// The first phrase of `topic` in `text`, for callers that need which.
    static func firstMatch(_ text: String, _ topic: Topic, agent: String?) -> String? {
        let t = normalize(text)
        return phrases(topic, agent: agent).first { t.contains($0) }
    }

    /// An extended regex (for the guest's `grep -iE`) that is true when a
    /// menu is open: any agent's footer, or a highlighted numbered row
    /// ("❯ 1.", "▶ 1.", Grok's "1 (●)"). Not "›"/">": Codex prefixes the
    /// user's own past messages with them, and "1. …" is a common message.
    static var menuOpenRegex: String {
        let footers = phrases(.footer, agent: nil).map(eregEscape)
        // Alternations, not bracket sets: a set of multibyte glyphs is a
        // set of BYTES to a grep that isn't in a UTF-8 locale.
        let rows = ["(❯|▶) *[0-9]+[.)]", "[0-9] \\((●|○)\\)"]
        return (Array(Set(footers)).sorted() + rows).joined(separator: "|")
    }

    private static func eregEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\.^$|?*+()[]{}".contains(c) { out.append("\\") }
            if c == "'" { out += "'\\''"; continue }   // single-quoted in the shell
            out.append(c)
        }
        return out
    }
}
