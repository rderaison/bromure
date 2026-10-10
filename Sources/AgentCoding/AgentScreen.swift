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
    /// The option's description, when the dialog draws one under it (omp's
    /// ask: "○ Red" + "      A warm color").
    var detail: String? = nil
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
        // A dialog replaces the agent's input box, so its cursor row is the
        // LAST cursor glyph on screen. One below it — the input box, even
        // bare ("❯" once trailing blanks are trimmed) — means the row is the
        // user's own message echoed in the conversation ("❯ What is…?"
        // wrapped onto a second, aligned line read as two options: every
        // question showed as a card while the agent started thinking).
        let lastGlyph = lines.indices.last { $0 > from && glyphRow(lines[$0]) }
        guard let menu = numberedMenu(lines, after: from) ?? unnumberedMenu(lines, after: from)
        else { return nil }
        if let lastGlyph, lastGlyph > menu.lastOffset { return nil }
        return menu
    }

    /// A line that starts with a cursor glyph — a highlighted row, or an
    /// input box's prompt with nothing typed in it.
    private static func glyphRow(_ line: String) -> Bool {
        let t = unboxed(line).trimmingCharacters(in: .whitespaces)
        guard let g = t.first, cursorGlyphs.contains(g) else { return false }
        return t.count == 1 || t.dropFirst().first.map { $0 == " " || $0 == "\u{00a0}" } == true
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
        // A row too long for a narrow pane goes on, wrapped, on the lines
        // under it: Grok at 52 columns draws "1 (●) Yes, and don't ask again
        // for anything (" + "always-approve mode)". Join them back.
        var labels = run.map { $0.1.label }
        var lastLine = last.0
        for k in run.indices {
            let limit = k + 1 < run.count ? run[k + 1].0 : min(lines.count, run[k].0 + 4)
            var i = run[k].0 + 1
            while i < limit, let more = wrappedContinuation(lines[i], of: labels[k]) {
                labels[k] = joinWrapped(labels[k], more)
                if k == run.count - 1 { lastLine = i }
                i += 1
            }
        }
        guard tailIsFooter(lines, after: lastLine) else { return nil }
        return Menu(options: zip(run, labels).map { LoginOption(index: $0.0.1.index, label: $0.1) },
                    selected: cursor.1.index, firstOffset: first.0, lastOffset: lastLine, numbered: true)
    }

    /// `line` as the wrapped rest of an option whose label so far is
    /// `label`, or nil: never another row, a rule, the key-hint footer, or
    /// a description under a complete label — only text that finishes a
    /// label that was cut (an open parenthesis, a lowercase word going on).
    static func wrappedContinuation(_ line: String, of label: String) -> String? {
        let t = unboxed(line).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !isRule(line), numberedRow(line) == nil, !glyphRow(line),
              !isKeyHintLine(line), !isStatusChrome(line) else { return nil }
        let opens = label.filter { $0 == "(" || $0 == "[" }.count
        let closes = label.filter { $0 == ")" || $0 == "]" }.count
        if opens > closes { return t }
        guard let c = t.first, c.isLowercase,
              let end = label.last, !".!?:;)]。？".contains(end) else { return nil }
        return t
    }

    /// "anything (" + "always-approve mode)" → "anything (always-approve
    /// mode)"; words otherwise get their space back.
    static func joinWrapped(_ head: String, _ tail: String) -> String {
        if let e = head.last, "(/[-".contains(e) { return head + tail }
        return head + " " + tail
    }

    /// A footer of key hints, however it wrapped at a narrow width — "1/3:
    /// select │ Tab:next option │ ←/→:scope", "Ctrl+c:cancel", "↑/↓ to move".
    static func isKeyHintLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if AgentPhrases.matches(t, .footer, agent: nil) { return true }
        let low = t.lowercased()
        if low.range(of: #"(ctrl|tab|esc|enter|shift|space|alt)\s*[+:]"#, options: .regularExpression) != nil {
            return true
        }
        if low.range(of: #"^[0-9]+/[0-9]+\s*:"#, options: .regularExpression) != nil { return true }
        // Arrow-key hints: Grok's "← → narrow scope" under its approval
        // title, "↑/↓ to move". A line opening on ←/↑/↓, or on two arrows
        // ("→" alone is also Kimi's cursor glyph).
        if t.range(of: #"^[←↑↓⇅⇄]"#, options: .regularExpression) != nil
            || t.range(of: #"^[←→↑↓]\s*/?\s*[←→↑↓]"#, options: .regularExpression) != nil { return true }
        // Hints separated by a bar inside the line ("a:b │ c:d").
        let inner = t.dropFirst().dropLast()
        return inner.contains("│") && t.contains(":")
    }

    /// A dialog that is up but doesn't fit the pane: a selection footer
    /// ("1/4:select │ Tab:next option") at the bottom, with fewer option rows
    /// above it than a menu needs — Grok's approval at 52x20 showed only
    /// "1 (●) Yes, and don't ask again for anything (". Returns where the
    /// visible rows start and where the footer is; nil when no such footer
    /// is up (an idle prompt's own hints never say "select").
    static func partialDialog(_ lines: [String]) -> (firstRow: Int, footer: Int)? {
        guard let last = lines.indices.last(where: { !unboxed(lines[$0]).trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        // The footer may wrap over a couple of lines at a narrow width.
        var footer: Int?
        var i = last
        while i >= 0, i >= last - 2, isKeyHintLine(lines[i]) || isRule(lines[i])
                || unboxed(lines[i]).trimmingCharacters(in: .whitespaces).isEmpty {
            if isSelectionHint(lines[i]) { footer = i }
            i -= 1
        }
        guard let footer else { return nil }
        var rows: [Int] = []
        var j = footer - 1
        while j >= 0, j >= footer - 8 {
            let t = unboxed(lines[j]).trimmingCharacters(in: .whitespaces)
            if numberedRow(lines[j]) != nil || cursorColumn(lines[j]) != nil { rows.append(j) }
            else if !rows.isEmpty, t.isEmpty || isRule(lines[j]) { break }
            else if rows.isEmpty, !t.isEmpty, !isKeyHintLine(lines[j]), !isRule(lines[j]),
                    j < footer - 3 { break }
            j -= 1
        }
        guard let first = rows.min() else { return nil }
        return (first, footer)
    }

    /// A footer hint about picking among options: "1/4:select",
    /// "enter select", "Tab:next option", "↑/↓ to move".
    static func isSelectionHint(_ line: String) -> Bool {
        let low = line.lowercased()
        guard isKeyHintLine(line) else { return false }
        return low.range(of: #"[0-9]+/[0-9]+\s*:"#, options: .regularExpression) != nil
            || low.contains("select") || low.contains("next option") || low.contains("to move")
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
        let label = { (l: String) in
            optionMarkerStripped(String(unboxed(l).dropFirst(col)).trimmingCharacters(in: .whitespaces))
        }
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
        // The lines indented under a row are its description.
        func detail(_ k: Int) -> String? {
            let end = k + 1 < rows.count ? rows[k + 1] : last + 1
            let text = ((rows[k] + 1)..<end).filter { isOption($0) == false }
                .map { unboxed(lines[$0]).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        let options = rows.enumerated().map {
            LoginOption(index: $0.offset + 1, label: label(lines[$0.element]), detail: detail($0.offset))
        }
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

    /// A row's label without the radio / check mark drawn before it
    /// ("○ Red", "◉ Blue" — omp's ask).
    static func optionMarkerStripped(_ label: String) -> String {
        guard let m = label.first, "○◉●◯◎".contains(m),
              label.dropFirst().first.map({ $0 == " " || $0 == "\u{00a0}" }) == true else { return label }
        return String(label.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    /// A box's titled top edge or inner divider ("╭─ Ask ──╮", "├────┤").
    static func isBoxEdge(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = t.first, "╭┌├╞".contains(c) else { return false }
        return t.contains("──")
    }

    /// Below the list: at most a few footer lines, blanks and box edges.
    private static func tailIsFooter(_ lines: [String], after last: Int) -> Bool {
        guard last + 1 < lines.count else { return true }
        // Key-hint lines don't count: a footer wraps onto several at a
        // narrow width and is still just the footer.
        return lines[(last + 1)...].filter {
            !unboxed($0).trimmingCharacters(in: .whitespaces).isEmpty && !isRule($0) && !isKeyHintLine($0)
        }.count <= 3
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
        // Kimi's question dialog brackets its numbers: "→ [1] Option".
        let bracketed = body.first == "["
        if bracketed { body = body.dropFirst() }
        let digits = body.prefix(while: \.isNumber)
        guard let n = Int(digits), (1...9).contains(n) else { return nil }
        var rest = body.dropFirst(digits.count)
        if bracketed {
            guard rest.first == "]" else { return nil }
            rest = rest.dropFirst()
        } else if rest.first == "." || rest.first == ")" {
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
        let banner = dataRetentionRange(lines)
        func prose(_ l: String) -> String? {
            let t = deglyphed(unboxed(l).trimmingCharacters(in: .whitespaces))
            guard !t.isEmpty, t.count <= 90, t.contains(where: \.isLetter), !isStatusChrome(l),
                  !isKeyHintLine(unboxed(l)),
                  !(banner.map { r in lines[r].contains(l) } ?? false),
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
        // A line carrying a link is the dialog's fine print ("Release
        // notes: https://…" under Codex's "Update available!"), not its
        // heading — unless there is nothing else.
        // The nearest prose line, taken back to the top of its paragraph: a
        // heading over a wrapped explanation ("Select model / Switch between
        // Claude models. … For / other/previous model names, specify with
        // --model.") is titled by its heading, never by the wrap's tail.
        let rows = Array(above)   // nearest first
        guard let pick = rows.firstIndex(where: { prose($0).map { !$0.contains("://") } ?? false })
                ?? rows.firstIndex(where: { prose($0) != nil })
        else { return "" }
        var top = pick
        while top + 1 < rows.count, prose(rows[top + 1]) != nil { top += 1 }
        return prose(rows[top]) ?? ""
    }

    /// What the dialog is about: its lines between the box's top edge (or 12
    /// lines up) and the options, minus the title. A dashed rule is inside
    /// the dialog (Claude frames a diff with ╌╌╌), not its edge.
    /// With no edge at all (Codex draws its dialogs unboxed), what sits
    /// above the title past a blank line is the conversation's scrollback
    /// ("• Ran …", "11:50 AM"): the body is the title's own paragraph (a
    /// "Bash command: …" line right above it) and what follows it.
    static func context(_ lines: [String], before first: Int, title: String) -> String {
        let edge = { (l: String) in (isRule(l) || isBoxEdge(l)) && !l.contains("╌") && !l.contains("┄") }
        let floor = max(0, first - 12)
        var start = lines[..<first].lastIndex(where: edge).map { $0 + 1 } ?? floor
        if start <= floor, !title.isEmpty,
           let t = lines[floor..<first].lastIndex(where: {
               deglyphed(unboxed($0).trimmingCharacters(in: .whitespaces)) == title
           }) {
            var top = t
            while top - 1 >= floor, !unboxed(lines[top - 1]).trimmingCharacters(in: .whitespaces).isEmpty { top -= 1 }
            start = top
        }
        // Not the dialog's: the agent's spinner line, and Grok's
        // data-retention banner (a card of its own — see `TerminalPrompt`).
        let banner = dataRetentionRange(lines)
        return lines.indices[max(start, floor)..<first]
            .filter { !(banner?.contains($0) ?? false) && !isStatusChrome(lines[$0])
                && !isKeyHintLine(unboxed(lines[$0])) }
            .map { deglyphed(unboxed(lines[$0]).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && $0 != title && $0.contains(where: \.isLetter) }
            .joined(separator: "\n")
    }

    /// The agent's working line, not anything a dialog says: Grok's "◆
    /// Fetch https://… 25s   28s ↓22.5k" and its "[stop]" button, an
    /// "esc to interrupt" hint, a token counter.
    static func isStatusChrome(_ line: String) -> Bool {
        let t = unboxed(line).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let low = t.lowercased()
        if low == "[stop]" || low.hasSuffix(" [stop]") || low.contains("esc to interrupt")
            || low.contains("esc to cancel") || low.contains("ctrl+c to interrupt") { return true }
        // A token counter ("↓22.5k", "↑ 1.2k tokens").
        if t.range(of: #"[↓↑]\s?[0-9][0-9.,]*\s?[kKmM]?(\s+tokens)?\s*\)?$"#, options: .regularExpression) != nil {
            return true
        }
        // A spinner glyph, what's running, how long ("◆ Fetch … 25s").
        if let g = t.unicodeScalars.first, !g.properties.isAlphabetic, !("0"..."9").contains(Character(g)),
           !"[(\"'`/~.-".unicodeScalars.contains(g),
           t.range(of: #"\s[0-9]+(m\s?[0-9]+)?s$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Grok's "Help improve Grok [Opt out] [Opt in]" banner (whether xAI may
    /// keep your coding data): its line range on screen, nil when it isn't up.
    static func dataRetentionRange(_ lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: {
            let l = $0.lowercased()
            return l.contains("help improve grok") || (l.contains("[opt in]") && l.contains("[opt out]"))
        }) else { return nil }
        var end = start
        var i = start + 1
        while i < lines.count, i <= start + 9 {
            let l = unboxed(lines[i]).trimmingCharacters(in: .whitespaces)
            if l.isEmpty { break }
            end = i
            if l.lowercased().contains("privacy policy") { break }
            i += 1
        }
        return start...end
    }

    /// What the data-retention banner says, its buttons left out; nil when
    /// it isn't up. (Grok's own words: its TUI isn't translated.)
    static func dataRetentionNotice(_ lines: [String]) -> String? {
        guard let r = dataRetentionRange(lines) else { return nil }
        let text = lines[r].dropFirst().map { l -> String in
            unboxed(l).replacingOccurrences(of: "[Opt out]", with: "")
                .replacingOccurrences(of: "[Opt in]", with: "")
                .trimmingCharacters(in: .whitespaces)
        }.filter { $0.contains(where: \.isLetter) }.joined(separator: " ")
        return text.isEmpty ? "" : text
    }

    /// The banner's buttons as Grok draws them. Grok's TUI takes no key for
    /// them (Tab, arrows and Enter all go to its input box): they answer a
    /// mouse click, which Grok asks the terminal to report.
    static let optOutButton = "[Opt out]"
    static let optInButton = "[Opt in]"

    /// A guest shell snippet that clicks `label` where it sits on screen in
    /// tmux pane "$_bt": finds its row/column in a fresh capture (pane
    /// rows, 1-based) and types an SGR mouse press + release there — what a
    /// terminal sends for a click once the app turned mouse reporting on.
    /// Nothing is sent when the label isn't on screen. Columns count
    /// characters (the banner's line is plain text).
    static func clickLabelCommand(_ label: String) -> String {
        let finder = """
        import sys
        b = sys.argv[1]
        for n, l in enumerate(sys.stdin.read().split("\\n"), 1):
            i = l.find(b)
            if i >= 0:
                print(n, i + 2)
                break
        """
        let b64 = Data(finder.utf8).base64EncodedString()
        let quoted = "'" + label.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "set -- $(tmux capture-pane -p -t \"$_bt\" 2>/dev/null"
            + " | python3 -c \"$(echo \(b64) | base64 -d)\" \(quoted))"
            + "; [ -n \"$1\" ] && tmux send-keys -t \"$_bt\" -l"
            + " \"$(printf '\\033[<0;%d;%dM\\033[<0;%d;%dm' \"$2\" \"$1\" \"$2\" \"$1\")\""
    }

    /// A heading without the marker some agents draw before it — Kimi 2.1
    /// heads its approval panel "▶ Run this command?" with the same glyph
    /// as its cursor row.
    static func deglyphed(_ t: String) -> String {
        guard let g = t.first, cursorGlyphs.contains(g),
              t.dropFirst().first.map({ $0 == " " || $0 == "\u{00a0}" }) == true else { return t }
        return String(t.dropFirst().drop(while: { $0 == " " || $0 == "\u{00a0}" }))
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
    ///
    /// The screen is the agent's pane — diffs and files it prints too —
    /// so what it shows is untrusted. A line that quotes or assigns a URL
    /// is code, the rest of it ignored (finding 2510C61A), and a URL is
    /// taken only when it is the exact sign-in page `agent` itself prints
    /// (`isSignInURL`: host, path, and for an authorize page its client
    /// and where it sends the code) — not any page on a provider's domain
    /// (finding 30BA541B: script.google.com, a GitHub consent page for an
    /// attacker's app, a device page with an attacker's code).
    static func signInURL(_ lines: [String], agent: String? = nil) -> String? {
        for line in lines {
            var rest = Substring(line)
            scan: while let r = rest.range(of: "https://") {
                let url = String(rest[r.lowerBound...].prefix(while: { !$0.isWhitespace }))
                let before = rest[..<r.lowerBound]
                if let c = before.last, "\"'`=(<[".contains(c) { break scan }
                if before.contains(where: { "\"'`".contains($0) }) { break scan }
                // Past the whole URL: one quoted string can't hide another.
                rest = rest[rest.index(r.lowerBound, offsetBy: url.count)...]
                if isSignInURL(url, agent: agent) { return url }
            }
        }
        return nil
    }

    /// One agent sign-in page: its exact hosts and path, and for an OAuth
    /// authorize page the clients it may name (nil = any) and the
    /// redirect hosts it may send the code to besides loopback (a page
    /// that shows the code for pasting back).
    struct SignInPage: Sendable {
        enum Kind: Sendable { case authorize, device }
        var kind: Kind
        var hosts: Set<String>
        var paths: Set<String>
        var clientIDs: Set<String>? = nil
        var codePages: Set<String> = []
    }

    /// Claude Code's OAuth client.
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static let claudePages = [
        SignInPage(kind: .authorize,
                   hosts: ["claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com"],
                   paths: ["/oauth/authorize", "/cai/oauth/authorize"],
                   clientIDs: [claudeClientID],
                   codePages: ["platform.claude.com", "console.anthropic.com"]),
    ]
    static let codexPages = [
        SignInPage(kind: .device, hosts: ["auth.openai.com"], paths: ["/codex/device"]),
        SignInPage(kind: .authorize, hosts: ["auth.openai.com"], paths: ["/oauth/authorize"]),
    ]

    /// The sign-in pages each agent prints (nil agent: any of them).
    /// GitHub's device page is no one's: its code is whoever's printed.
    static let signInPages: [String: [SignInPage]] = [
        "claude": claudePages,
        "codex": codexPages,
        "grok": [
            SignInPage(kind: .device, hosts: ["accounts.x.ai", "auth.x.ai"], paths: ["/oauth2/device"]),
            SignInPage(kind: .authorize, hosts: ["accounts.x.ai", "auth.x.ai"],
                       paths: ["/oauth2/auth", "/oauth2/authorize"]),
        ],
        "kimi": [
            SignInPage(kind: .device,
                       hosts: ["auth.kimi.ai", "kimi.ai", "www.kimi.ai", "auth.kimi.com", "kimi.com", "www.kimi.com"],
                       paths: ["/device", "/authorize_device", "/code/authorize_device", "/api/oauth/authorize_device"]),
        ],
        "omp": claudePages + codexPages + [
            SignInPage(kind: .authorize, hosts: ["accounts.google.com"],
                       paths: ["/o/oauth2/auth", "/o/oauth2/v2/auth"]),
        ],
    ]

    /// `url` is a sign-in page `agent` prints: exact host and path; an
    /// authorize page names one of its clients and redirects to loopback
    /// (or to its own code page).
    static func isSignInURL(_ url: String, agent: String?) -> Bool {
        signInPage(for: url, agent: agent) != nil
    }

    static func signInPage(for url: String, agent: String?) -> SignInPage? {
        guard let host = signInHost(url), let u = URLComponents(string: url) else { return nil }
        let path = u.path.lowercased()
        let pages = agent.flatMap { signInPages[$0] } ?? signInPages.values.flatMap { $0 }
        for page in pages where page.hosts.contains(host) && page.paths.contains(path) {
            switch page.kind {
            case .device:
                return page
            case .authorize:
                let items = u.queryItems ?? []
                func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
                if let ids = page.clientIDs, !ids.contains(value("client_id") ?? "") { continue }
                guard let redirect = value("redirect_uri").flatMap(URLComponents.init(string:)),
                      let rh = redirect.host?.lowercased() else { continue }
                if Self.isLoopback(rh) || (redirect.scheme == "https" && page.codePages.contains(rh)) {
                    return page
                }
            }
        }
        return nil
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// `url`'s host, lowercased — what the card's button names.
    static func signInHost(_ url: String) -> String? {
        guard let u = URLComponents(string: url), u.scheme?.lowercased() == "https",
              let host = u.host?.lowercased(), !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        return host
    }

    /// The agent's sign-in shows: a dialog's own wording anywhere (but in
    /// quotes), or
    /// everyday wording ("not logged in", "run /login") as a status line
    /// says it — leading the line, or after its " · " / "error:" — never
    /// inside quotes or a code or diff line the agent printed (the card
    /// came up over a diff with `# "Not logged in". Then exec …` in it).
    static func loginShown(_ lines: [String], agent: String?) -> Bool {
        let phrases = AgentPhrases.phrases(.login, agent: agent)
        for raw in lines {
            let line = AgentPhrases.normalize(raw)
            for phrase in phrases {
                guard let r = line.range(of: phrase) else { continue }
                if Self.quoted(line, at: r) { continue }
                if !AgentPhrases.everydayLogin.contains(phrase) { return true }
                if Self.isStatusMention(line, at: r) { return true }
            }
        }
        return false
    }

    /// `phrase` at `r` sits in a string: a quote opened before it on the
    /// line, or one left open after it — the tail of a string the TUI
    /// wrapped onto this line (`please run /login")`).
    static func quoted(_ line: String, at r: Range<String.Index>) -> Bool {
        let before = line[..<r.lowerBound], after = line[r.upperBound...]
        if before.contains(where: { $0 == "\"" || $0 == "`" }) || before.last == "'" { return true }
        return after.filter { $0 == "\"" }.count % 2 == 1 || after.filter { $0 == "`" }.count % 2 == 1
    }

    /// `phrase` at `r` reads as the agent's own message, not quoted text.
    static func isStatusMention(_ line: String, at r: Range<String.Index>) -> Bool {
        // The line's content: past the frame, the agent's markers and a
        // list number ("⎿ ", "● ", "│ ", "1. ").
        var body = Substring(line).drop { c in
            c.isWhitespace || "│┃|>❯›▶●⎿✗✘⚠•*■".contains(c)
                || (c.unicodeScalars.first.map { (0x2500...0x257F).contains($0.value) } ?? false)
        }
        if let dot = body.firstIndex(where: { !$0.isNumber }), dot > body.startIndex,
           ".)".contains(body[dot]) {
            body = body[body.index(after: dot)...].drop(while: \.isWhitespace)
        }
        // Code or a diff line: a comment, or "123 +"/"-" gutter.
        if body.hasPrefix("#") || body.hasPrefix("//") || body.hasPrefix("+") || body.hasPrefix("-") { return false }
        if body.range(of: #"^\d+\s*[+-]"#, options: .regularExpression) != nil { return false }
        if body.startIndex == r.lowerBound { return true }
        let lead = line[body.startIndex..<r.lowerBound]
        return lead.hasSuffix("· ") || lead.hasSuffix("error: ") || lead.hasSuffix("error:")
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
        // Only a sign-in page whose redirect is its provider's own code
        // page: a code pasted back goes nowhere else (`code=true` alone
        // proved nothing — anyone can put it in a URL).
        guard let page = signInPage(for: url, agent: nil), page.kind == .authorize,
              let redirect = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
                .flatMap(URLComponents.init(string:)),
              let rh = redirect.host?.lowercased() else { return false }
        return page.codePages.contains(rh)
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
            // 1.0.46's folder-trust gate: "Do you trust the contents of this
            // directory? / Grok Build may run or modify contents in this
            // directory, posing security risks. / y Yes, proceed / n No,
            // quit / Enter or y to trust".
            .trust: ["do you trust the contents of this directory", "enter or y to trust",
                     "grok build may run or modify contents"],
            .permission: ["yes, proceed", "no, reject", "don't ask again"],
            // Its trust gate's key line: a dialog is up (typing would answer it).
            .footer: ["enter or y to trust"],
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

    /// Sign-in wording that also turns up in ordinary text — code the agent
    /// prints, a diff, a chat answer about logins. It counts only as the
    /// agent's own status line says it (see `AgentScreen.loginShown`); the
    /// rest of `.login` names a sign-in dialog and counts anywhere.
    static let everydayLogin: Set<String> = [
        "not logged in", "please run /login", "run /login", "please log in", "not signed in",
        "login required", "llm not set", "run /login or /provider", "kimi login", "grok login",
        "oauth login expired", "no models available", "no api key", "api key is not set",
        "missing api key", "anthropic_api_key", "no model selected",
    ]

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

    /// `menuOpenRegex` on the host side, for a screen already captured
    /// (`tmux capture-pane -p`): its bottom 30 rows, lowercased.
    static func menuOpen(_ screen: String) -> Bool {
        let tail = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(30)
            .joined(separator: "\n").lowercased()
        if phrases(.footer, agent: nil).contains(where: { tail.contains($0) }) { return true }
        return tail.range(of: "(❯|▶) *[0-9]+[.)]|[0-9] \\((●|○)\\)", options: .regularExpression) != nil
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

// MARK: - Input box

/// What sits in an agent's input box right now, read from a pane capture
/// WITH its escapes (`tmux capture-pane -p -e`): the host must never type a
/// message onto text already there (a stray "/exit" + "Please continue…"
/// went out as "/exitPlease continue…").
///
/// The box is found by shape — a prompt glyph row with a horizontal rule
/// (or box edge) right above or below it, near the bottom of the screen —
/// and what follows the glyph is read without the agent's placeholder
/// ("Try …", "Ask Codex to do anything": dim or grey) and without its
/// drawn cursor (inverse video). Anything else there is a draft.
enum AgentInputBox {
    enum Content: Equatable {
        /// The box is there and empty.
        case empty
        /// Text in the box (its first line, trimmed).
        case text(String)
        /// No input box recognized (a menu, a busy screen, an unknown TUI).
        case unknown
    }

    /// Prompt glyphs agents draw at the start of their input row.
    static let promptGlyphs: [Character] = ["❯", "›", ">", "▌"]

    /// One screen row: its plain text, and for each character whether it
    /// counts as typed content (not placeholder/cursor styling).
    struct Row {
        var text: String = ""
        var content: [Bool] = []
    }

    /// Splits an `-e` capture into rows, tracking SGR state: dim (2), grey
    /// foregrounds (90, 256-colour greys, near-grey truecolor) and inverse
    /// video (7) mark characters as not-content.
    static func rows(_ capture: String) -> [Row] {
        var rows: [Row] = []
        for rawLine in capture.split(separator: "\n", omittingEmptySubsequences: false) {
            var row = Row()
            var dim = false, grey = false, inverse = false
            var it = rawLine.unicodeScalars.makeIterator()
            var pending: Unicode.Scalar? = nil
            func next() -> Unicode.Scalar? {
                if let p = pending { pending = nil; return p }
                return it.next()
            }
            while let c = next() {
                if c == "\u{1B}" {
                    guard let k = next() else { break }
                    if k == "[" {
                        var params = ""
                        var final: Unicode.Scalar? = nil
                        while let p = next() {
                            if (0x40...0x7E).contains(p.value) { final = p; break }
                            params.unicodeScalars.append(p)
                        }
                        if final == "m" {
                            applySGR(params, dim: &dim, grey: &grey, inverse: &inverse)
                        }
                    } else if k == "]" {
                        // OSC: up to BEL or ST.
                        while let p = next() {
                            if p == "\u{07}" { break }
                            if p == "\u{1B}" { _ = next(); break }
                        }
                    }
                    continue
                }
                if c == "\r" { continue }
                row.text.unicodeScalars.append(c)
                // Content per Character: combining scalars ride on the last.
                if row.content.count < row.text.count {
                    row.content.append(!(dim || grey || inverse))
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func applySGR(_ params: String, dim: inout Bool, grey: inout Bool, inverse: inout Bool) {
        let p = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var i = 0
        while i < p.count {
            switch p[i] {
            case 0: dim = false; grey = false; inverse = false
            case 2: dim = true
            case 22: dim = false
            case 7: inverse = true
            case 27: inverse = false
            case 90: grey = true
            case 30...37, 91...97, 39: grey = false
            case 38:
                if i + 2 < p.count, p[i + 1] == 5 {
                    let n = p[i + 2]
                    grey = n == 8 || (232...252).contains(n) || [59, 102, 145, 188].contains(n)
                    i += 2
                } else if i + 4 < p.count, p[i + 1] == 2 {
                    let (r, g, b) = (p[i + 2], p[i + 3], p[i + 4])
                    let spread = max(r, g, b) - min(r, g, b)
                    grey = spread <= 20 && (70...200).contains(r)
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    /// The input box's content in a capture (see the type's notes).
    static func content(_ capture: String) -> Content {
        var rows = rows(capture)
        while let last = rows.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        guard !rows.isEmpty else { return .unknown }
        let low = max(0, rows.count - 20)
        if let band = ompBand(rows, low: low) { return band }
        func isRule(_ i: Int) -> Bool {
            rows.indices.contains(i) && AgentScreen.isRule(rows[i].text)
        }
        for i in stride(from: rows.count - 1, through: low, by: -1) {
            let text = rows[i].text
            // Leading blanks and a box edge, then the glyph.
            var idx = text.startIndex
            var off = 0
            while idx < text.endIndex, text[idx] == " " || "│┃|".contains(text[idx]) {
                idx = text.index(after: idx); off += 1
            }
            guard idx < text.endIndex, promptGlyphs.contains(text[idx]) else { continue }
            // A status bar whose segments are split by `>` (omp's) is chrome.
            guard !isStatusBar(text) else { continue }
            let after = text.index(after: idx)
            guard after == text.endIndex || text[after] == " " || text[after] == "\u{00a0}" else { continue }
            // An input box, not an echoed message: a rule hugs it.
            guard isRule(i - 1) || isRule(i + 1) || isRule(i - 2) || isRule(i + 2) else { continue }
            let flags = rows[i].content
            var typed = ""
            var k = after, n = off + 1
            while k < text.endIndex {
                let ch = text[k]
                if n < flags.count, flags[n], !"│┃|".contains(ch) { typed.append(ch) }
                else { typed.append(" ") }
                k = text.index(after: k); n += 1
            }
            var t = typed.trimmingCharacters(in: .whitespaces)
            // Continuation rows of a multi-line draft below the prompt row.
            if t.isEmpty, i + 1 < rows.count, !isRule(i + 1), !isStatusBar(rows[i + 1].text) {
                let next = AgentScreen.unboxed(rows[i + 1].text).trimmingCharacters(in: .whitespaces)
                let nextContent = rows[i + 1].content.contains(true) && !next.isEmpty
                if nextContent, rows.indices.contains(i + 2), isRule(i + 2) {
                    t = next
                }
            }
            return t.isEmpty ? .empty : .text(t)
        }
        return .unknown
    }

    /// omp's status bar: powerline segments split by `>` (or the nerd-font
    /// separator), ending in a cap and a rule fill —
    /// ` π > ⬢ GLM-5.3 > 📁 ~/app ▶──────`. Never a draft, never a prompt.
    static func isStatusBar(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !AgentScreen.isRule(t) else { return false }
        if t.contains("▶─") || t.contains("\u{E0B0}─") { return true }
        let fill = t.reversed().prefix(while: { "─━".contains($0) }).count
        guard fill >= 3 else { return false }
        return t.contains(" > ") || t.contains("\u{E0B1}") || t.hasPrefix("π")
    }

    /// omp's band composer: its status bar on top, then the input rows
    /// behind a `╰─ ` gutter (continuation rows indented to match). What
    /// sits ABOVE the bar — its queue ("╰─ Queued: …", "1. …") — is not the
    /// input box. nil: no band composer on screen.
    static func ompBand(_ rows: [Row], low: Int) -> Content? {
        guard rows.count >= 2 else { return nil }
        for b in stride(from: rows.count - 2, through: max(0, low), by: -1) where isStatusBar(rows[b].text) {
            func gutterText(_ r: Row) -> (typed: String, gutter: Bool) {
                let chars = Array(r.text)
                var k = 0
                while k < chars.count, chars[k] == " " { k += 1 }
                var gutter = false
                if k + 1 < chars.count, chars[k] == "╰", chars[k + 1] == "─" {
                    gutter = true
                    k += 2
                }
                var typed = ""
                while k < chars.count {
                    typed.append(k < r.content.count && r.content[k] ? chars[k] : " ")
                    k += 1
                }
                return (typed.trimmingCharacters(in: .whitespaces), gutter)
            }
            let first = gutterText(rows[b + 1])
            guard first.gutter else { continue }
            if !first.typed.isEmpty { return .text(first.typed) }
            // A draft that opens with a blank line: its text is on the rows below.
            var j = b + 2
            while j < min(rows.count, b + 5) {
                if AgentScreen.isRule(rows[j].text) || isStatusBar(rows[j].text) { break }
                let next = gutterText(rows[j])
                if next.gutter { break }
                if !next.typed.isEmpty { return .text(next.typed) }
                j += 1
            }
            return .empty
        }
        return nil
    }

    /// The probe for TUIs that draw no ruled box but keep the terminal's
    /// own cursor in their input line (prompt_toolkit — Kimi): the cursor
    /// state, then the visible screen.
    nonisolated static func cursorProbeCommand(target t: String) -> String {
        "tmux display-message -p -t \(t) '#{cursor_flag} #{cursor_x} #{cursor_y} #{pane_height}' 2>/dev/null; "
            + "tmux capture-pane -p -t \(t) 2>/dev/null"
    }

    /// Reads `cursorProbeCommand`'s output: text typed just left of a
    /// visible cursor sitting in the screen's bottom rows is a draft; a
    /// prompt (a glyph or a blank right before the cursor) is an empty box.
    /// Hidden cursor or a cursor up the screen: unknown.
    static func cursorContent(_ probe: String) -> Content {
        var lines = probe.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return .unknown }
        let head = lines.removeFirst().split(separator: " ").compactMap { Int($0) }
        guard head.count == 4, head[0] == 1 else { return .unknown }
        let (x, y, height) = (head[1], head[2], head[3])
        guard y >= max(0, height - 12), lines.indices.contains(y), x > 0 else { return .unknown }
        // The cursor parked on a status bar (omp's, while its editor isn't
        // focused) says nothing about the input.
        guard !isStatusBar(lines[y]) else { return .unknown }
        // Columns → characters (wide glyphs take two columns).
        var left = ""
        var col = 0
        for ch in lines[y] {
            if col >= x { break }
            left.append(ch)
            col += ch.unicodeScalars.contains { $0.properties.isEmojiPresentation
                || (0x1100...0x115F).contains($0.value) || (0x2E80...0xA4CF).contains($0.value)
                || (0xAC00...0xD7A3).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0xFF00...0xFF60).contains($0.value) || (0xFFE0...0xFFE6).contains($0.value) } ? 2 : 1
        }
        guard let last = left.last else { return .unknown }
        // `─`: omp's band gutter ("╰─ ").
        let promptEnds: Set<Character> = Set(promptGlyphs).union(["$", "#", "%", ":", "»", "✨", "💫", "▶", "─"])
        if last.isWhitespace || promptEnds.contains(last) { return .empty }
        // The draft: back to the prompt (a glyph followed by a space).
        var draft = Substring(left)
        if let g = left.lastIndex(where: { promptEnds.contains($0) }),
           left.index(after: g) < left.endIndex, left[left.index(after: g)] == " " {
            draft = left[left.index(after: g)...]
        }
        let t = draft.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? .empty : .text(t)
    }

    /// Is `draft` (as the box shows it) the start of `text` — Bromure's own
    /// message, typed by an earlier try that held off before Enter?
    static func isOwn(_ draft: String, of text: String) -> Bool {
        func squash(_ s: String) -> String {
            s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let d = squash(draft), t = squash(text)
        guard !d.isEmpty else { return false }
        let probe = String(d.prefix(40))
        return t.hasPrefix(probe)
    }
}
