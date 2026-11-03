import Foundation

// What an agent's terminal screen says, read from its text: a blocking
// prompt (sign-in, a dialog, a picker) or a failure banner. The chat view
// shows them; a server without a view (the Linux daemon) reads them too.

/// A failure the agent surfaced to its terminal but never wrote to the
/// transcript — most importantly an invalid subscription / auth error, which
/// otherwise leaves the beautified view stuck on "Thinking…". Detected by
/// sniffing the tail of the tab's terminal for high-signal error banners.
struct SessionFailure: Equatable {
    /// `blocked`: Bromure's own proxy refused the request (`BromureBlock`).
    enum Kind: Equatable { case auth, quota, generic, blocked }
    let kind: Kind
    /// A short human line lifted verbatim from the terminal (what the agent
    /// actually said), shown under the headline.
    let detail: String
    /// Which engine, when `kind == .blocked`.
    var blockedBy: BromureBlock? = nil

    var headline: String {
        switch kind {
        case .auth:    return NSLocalizedString("The agent couldn't authenticate", comment: "failure")
        case .quota:   return NSLocalizedString("The agent hit a usage limit", comment: "failure")
        case .generic: return NSLocalizedString("The agent stopped with an error", comment: "failure")
        case .blocked: return (blockedBy ?? .unknown).headline
        }
    }

    // High-signal banners live in `AgentPhrases` (.auth / .quota / .generic),
    // per agent. They're the fallback: a refusal the agent RECORDS comes from
    // its transcript, typed (`recorded(in:)`); the screen is read for what
    // never reaches it — a retry loop in progress, a logged-out banner at
    // startup. Deliberately phrase-specific — bare "error"/"401" are NOT
    // triggers — and a false positive self-heals the instant real
    // transcript content returns.

    static func detect(inScreen screen: String, agent: String? = nil) -> SessionFailure? {
        detect(tail: terminalTail(screen), agent: agent)
    }

    init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    init(_ error: AgentAPIError) {
        switch error.kind {
        case .auth: kind = .auth
        case .quota, .rateLimit: kind = .quota
        case .overloaded, .other: kind = .generic
        case .blocked: kind = .blocked; blockedBy = error.blockedBy ?? .unknown
        }
        let line = error.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        detail = line.isEmpty ? (error.status.map { "HTTP \($0)" } ?? "") : Self.clean(line)
    }

    /// The refusal the agent recorded for its latest turn — the transcript's
    /// last word, with nothing (a new prompt, an answer) after it. Read from
    /// the agent's own error enum / HTTP status, so it holds in any locale
    /// and through any rewording of the banner.
    static func recorded(in items: [TranscriptItem]) -> SessionFailure? {
        for item in items.reversed() {
            switch item.kind {
            case .agentError(let e): return SessionFailure(e)
            case .todo: continue
            default: return nil
            }
        }
        return nil
    }

    /// Whether the model has answered since the user's latest prompt — a
    /// call, a thought, or text that isn't itself an auth error (Claude logs
    /// "API Error: 401 …" as an assistant message).
    static func modelAnswered(since items: [TranscriptItem]) -> Bool {
        for item in items.reversed() {
            switch item.kind {
            case .userText: return false
            case .toolUse, .thinking, .question, .todo: return true
            case .assistantText(let t):
                if !AgentPhrases.matches(t, .auth, agent: nil) { return true }
            default: continue
            }
        }
        return false
    }

    /// Scan a pre-split terminal tail (shared with `TerminalScan`, which splits
    /// once). Bottom-up: the lowest matching line is the current state.
    /// `agent`: the tab's agent, for the wording only it uses (nil = any).
    static func detect(tail: [String], agent: String? = nil) -> SessionFailure? {
        func match(_ topic: AgentPhrases.Topic) -> String? {
            for raw in tail.reversed() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if AgentPhrases.matches(line, topic, agent: agent) { return clean(line) }
            }
            return nil
        }
        // Bromure's own block, as the agent printed it (its body names us).
        for raw in tail.reversed() {
            if let b = BromureBlock.of(raw) {
                var f = SessionFailure(kind: .blocked, detail: clean(raw))
                f.blockedBy = b
                return f
            }
        }
        if let d = match(.quota) { return SessionFailure(kind: .quota, detail: d) }
        if let d = match(.auth)  { return SessionFailure(kind: .auth,  detail: d) }
        // The launcher's "<tool> exited with status N": what the agent said
        // before it went is the useful part.
        if let d = AgentSessionEngine.earlyExitReason(tail.joined(separator: "\n")) {
            return SessionFailure(kind: .generic, detail: clean(d))
        }
        // The agent stopped before it could start a turn — a run that died
        // on configuration (Kimi: "No model configured") or a launcher that
        // reported a non-zero exit.
        if let d = match(.generic) { return SessionFailure(kind: .generic, detail: d) }
        return nil
    }

    /// Strip a TUI box/bullet gutter (either end) and clamp length so the
    /// line reads cleanly. A line that is nothing but box art (a frame's
    /// "╰────╯" scraped off the screen) is no reason at all: "".
    static func clean(_ line: String) -> String {
        let gutter = Set("│┃|>•*✗✘⎿⏺●─╮╯╭╰ ")
        func isArt(_ c: Character) -> Bool {
            gutter.contains(c) || c.unicodeScalars.allSatisfy {
                (0x2500...0x259F).contains($0.value) || $0.properties.isWhitespace
            }
        }
        var s = Substring(line)
        while let f = s.first, isArt(f) { s.removeFirst() }
        while let l = s.last, isArt(l) { s.removeLast() }
        let out = s.trimmingCharacters(in: .whitespaces)
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return out.count > 160 ? String(out.prefix(160)) + "…" : out
    }

    /// What the card says under its headline: a board task's recorded
    /// reason (`CodingTask.lastError`) wins — it names the exit status —
    /// over the terminal scrape (a sign-in or usage-limit card keeps the
    /// agent's own words); "" when neither says anything.
    static func body(_ f: SessionFailure, taskError: String?) -> String {
        if f.kind == .generic, let e = taskError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !e.isEmpty { return e }
        return clean(f.detail)
    }
}

/// The last N lines of a terminal snapshot — "now". Split once and shared by
/// both detectors (an old banner scrolled above this isn't the current state).
/// Blank lines inside are kept — they separate a dialog from what's around
/// it — and the empty rows below the content are not.
func terminalTail(_ screen: String, _ n: Int = 45) -> [String] {
    var lines = screen.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    return Array(lines.suffix(n))
}

/// A blocking TUI prompt the agent is showing that the beautified view hides —
/// a folder-trust dialog or a `/login` flow. The whole `/login` interaction is
/// reconstructed as native UI (method buttons → an "Open sign-in page" button →
/// a paste-the-code field), so the user never has to find the hidden terminal.
/// Claude's trust dialog is likewise answerable inline (its arrow list puts
/// "Yes, I trust this folder" one Down from the default "No, exit").
struct TerminalPrompt: Equatable {
    /// `notice`: something the agent shows that isn't a dialog (Grok's
    /// data-retention banner) — told, not answered here.
    enum Kind: Equatable { case trust, login, picker, checklist, notice }
    let kind: Kind
    /// Trust: the folder path. (Login carries its state in the fields below.)
    var detail: String = ""
    /// Trust dialog we recognize well enough to answer inline.
    var canAnswerTrust: Bool = false
    /// The keystrokes that accept it: Claude's picker needs Down then Enter
    /// ("Yes, I trust this folder" is the second option); Codex defaults to
    /// "Yes, continue", so Enter alone.
    var trustKeys: [String] = ["Down", "Enter"]
    /// Login — the method menu (non-empty at the "Select login method" stage).
    var loginMethods: [LoginOption] = []
    /// Login — the OAuth sign-in URL, once the agent prints it.
    var authURL: String? = nil
    /// Login — the agent is waiting for the verification code ("Paste code here").
    var awaitingCode: Bool = false
    /// Login — a device-code sign-in: the code to confirm on the page.
    var deviceCode: String? = nil
    /// Picker — any other modal the agent put up ("Try the new fullscreen
    /// renderer?"): its title, its numbered options, and which one the
    /// cursor sits on (so an answer is arrow moves from there, then Enter).
    var title: String = ""
    var options: [LoginOption] = []
    var selectedOption: Int? = nil
    /// Checklist — a multi-select ("Select any you wish to enable."): its
    /// rows (`options`) and their check boxes as they stand on screen.
    var checklist: AgentScreen.Checklist? = nil
    /// Grok's data-retention banner, up with (or without) a dialog: what it
    /// says. Its own card, never mixed into a dialog's.
    var privacyNotice: String? = nil
    /// Picker — a dialog that's up but didn't fit the agent's terminal (its
    /// options cut off): `detail` holds what IS visible; the card offers the
    /// terminal instead of options it can't name.
    var partial: Bool = false

    var headline: String {
        switch kind {
        case .trust: return NSLocalizedString("The agent is waiting for you to trust this folder", comment: "prompt")
        case .login: return NSLocalizedString("Sign in to Claude", comment: "prompt")
        case .picker, .checklist:
            return title.isEmpty ? NSLocalizedString("The agent is asking", comment: "prompt") : title
        case .notice:
            return title
        }
    }

    /// The keystrokes that pick option `index`: from the highlighted row
    /// (the first one when unknown) to the target, then Enter. Arrow moves
    /// work in every Claude Code picker; digits only in some.
    func keys(picking index: Int) -> [String] {
        let from = selectedOption ?? options.first?.index ?? 1
        let moves = index - from
        return Array(repeating: moves > 0 ? "Down" : "Up", count: abs(moves)) + ["Enter"]
    }

    /// An option that approves more than this one action — Grok's "Yes, and
    /// don't ask again for anything (always-approve mode)", "always allow…",
    /// "approve for this session". The agent's own cursor often starts on
    /// it; the card never pushes it.
    static func isBlanketApproval(_ label: String) -> Bool {
        let l = AgentPhrases.normalize(label)
        return ["don't ask again", "always-approve", "always approve", "always allow",
                "for this session", "for the rest of the session", "yolo"].contains { l.contains($0) }
    }

    /// The options in the order the card lists them: one-off answers first,
    /// the blanket approvals last. Each keeps its own index (what the keys
    /// pick on screen).
    var cardOptions: [LoginOption] {
        options.filter { !Self.isBlanketApproval($0.label) } + options.filter { Self.isBlanketApproval($0.label) }
    }

    /// The option the card marks as the default: the agent's cursor row,
    /// unless that is a blanket approval — then the safest yes (allow once)
    /// when there is one, else none (all rows look alike).
    var cardHighlight: Int? {
        let current = selectedOption ?? options.first?.index
        guard let current, let row = options.first(where: { $0.index == current }) else { return nil }
        guard Self.isBlanketApproval(row.label) else { return current }
        return options.first(where: { o in
            let l = AgentPhrases.normalize(o.label)
            return !Self.isBlanketApproval(o.label) && (l.contains("once") || l.hasPrefix("yes"))
        })?.index
    }

    static func detect(inScreen screen: String, agent: String? = nil) -> TerminalPrompt? {
        detect(tail: terminalTail(screen), agent: agent)
    }

    /// `agent`: the tab's agent kind, for the wording only it uses (nil =
    /// any agent's). Shapes first — a sign-in URL, a live menu — wording
    /// only to name what a shape is (a sign-in method list, a trust dialog
    /// we can answer in one click).
    static func detect(tail: [String], agent: String? = nil) -> TerminalPrompt? {
        let lines = tail.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        let notice = AgentScreen.dataRetentionNotice(lines)
        guard var p = detectDialog(tail: tail, agent: agent) else {
            return notice.map(privacyCard)
        }
        p.privacyNotice = notice
        return p
    }

    /// The data-retention banner on its own.
    static func privacyCard(_ text: String) -> TerminalPrompt {
        TerminalPrompt(kind: .notice, detail: text,
                       title: NSLocalizedString("Grok asks whether xAI may keep your coding data",
                                                comment: "prompt: Grok data-retention banner"),
                       privacyNotice: text)
    }

    private static func detectDialog(tail: [String], agent: String?) -> TerminalPrompt? {
        // Indentation kept (it aligns an unnumbered menu); trailing blanks off.
        let lines = tail.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        let screen = lines.joined(separator: "\n")
        let low = AgentPhrases.normalize(screen)

        // Sign-in: a sign-in URL or a device code on screen (any agent, any
        // wording), or the agent's own login wording — Claude's `/login`
        // method menu, Codex's first-run picker, the logged-out banners.
        let url = AgentScreen.signInURL(lines, agent: agent)
        let loginWords = AgentScreen.loginShown(lines, agent: agent)
        if url != nil || loginWords {
            return TerminalPrompt(
                kind: .login,
                loginMethods: AgentScreen.numberedOptions(lines),
                authURL: url,
                awaitingCode: url.map(AgentScreen.wantsPastedCode) == true
                    || low.contains("paste code here") || low.contains("paste the authorization code"),
                deviceCode: AgentScreen.deviceCode(lines))
        }

        // Folder trust we know well enough to answer in one click (Claude's
        // "Yes, I trust this folder" is one Down from "No, exit"). Kimi's
        // ONE-SHOT runs never ask: they print a warning that names the
        // dialog ("this folder is not trusted; … choose Trust this folder")
        // and carry on — no options on screen, nothing to answer.
        let kimiWarningOnly = low.contains("folder is not trusted")
            && !low.contains("don't trust") && !low.contains("❯ trust")
        if AgentPhrases.matches(screen, .trust, agent: agent), !kimiWarningOnly {
            let folder = AgentScreen.folder(lines) ?? NSLocalizedString("this folder", comment: "prompt")
            if low.contains("yes, i trust this folder") {
                return TerminalPrompt(kind: .trust, detail: folder, canAnswerTrust: true,
                                      trustKeys: ["Down", "Enter"])
            }
            // Anyone else's trust dialog is answered from its own options.
            if let menu = AgentScreen.liveMenu(lines, after: -1) {
                let asked = AgentScreen.title(lines, before: menu.firstOffset)
                return TerminalPrompt(kind: .picker, detail: folder,
                                      title: asked.isEmpty
                                          ? NSLocalizedString("Trust this folder?", comment: "prompt") : asked,
                                      options: menu.options, selectedOption: menu.selected)
            }
            // Codex's older dialog defaults to "Yes, continue": Enter takes it.
            // Grok's (1.0.46: "y  Yes, proceed / n  No, quit — Enter or y to
            // trust") has letter-keyed rows, no cursor: Enter takes it too.
            return TerminalPrompt(kind: .trust, detail: folder,
                                  canAnswerTrust: low.contains("yes, continue")
                                      || low.contains("enter or y to trust"),
                                  trustKeys: ["Enter"])
        }

        // Any other dialog up right now — a permission prompt, auto mode's
        // pause, an upsell, a quota menu — read from its SHAPE: a cursor on
        // one of sibling options at the bottom of the screen. What it says
        // doesn't matter, so it holds in any language and through rewording.
        // The card shows what's asked and relays the user's pick; it never
        // answers on its own.
        // A checklist ("2 new MCP servers found in this project — Select any
        // you wish to enable."): Enter on a row only ticks it there, so a
        // one-pick card could never submit it. Its own card holds the ticks
        // and relays them, then the button.
        if let list = AgentScreen.checklist(lines) {
            // Its heading is the box's first line ("2 new MCP servers found
            // in this project"), the rest what it explains.
            let body = AgentScreen.context(lines, before: list.firstOffset, title: "")
                .split(separator: "\n").map(String.init)
            return TerminalPrompt(kind: .checklist,
                                  detail: body.dropFirst().joined(separator: "\n"),
                                  title: body.first ?? "", options: list.options, checklist: list)
        }
        if let menu = AgentScreen.liveMenu(lines, after: -1) {
            // Claude's AskUserQuestion picker: its own card answers it.
            let footer = lines[(menu.lastOffset + 1)...].joined(separator: " ")
            if AgentPhrases.matches(footer, .questionFooter, agent: agent) { return nil }
            let title = AgentScreen.title(lines, before: menu.firstOffset)
            return TerminalPrompt(kind: .picker,
                                  detail: AgentScreen.context(lines, before: menu.firstOffset, title: title),
                                  title: title, options: menu.options, selectedOption: menu.selected)
        }
        // A dialog too big for the pane: still a card — what's visible of it,
        // and the terminal to answer in — never a bare "Needs you".
        if let partial = AgentScreen.partialDialog(lines) {
            let title = AgentScreen.title(lines, before: partial.firstRow)
            let context = AgentScreen.context(lines, before: partial.firstRow, title: title)
            let rows = lines[partial.firstRow..<partial.footer]
                .map { AgentScreen.unboxed($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !AgentScreen.isRule($0) && !AgentScreen.isKeyHintLine($0) }
            let detail = ([context] + rows).filter { !$0.isEmpty }.joined(separator: "\n")
            return TerminalPrompt(kind: .picker, detail: detail, title: title, partial: true)
        }
        return nil
    }
}

/// The one terminal state the beautified view surfaces. A blocking prompt wins
/// over an error banner — it's what the agent is waiting on right now.
enum TerminalState: Equatable {
    case prompt(TerminalPrompt)
    case failure(SessionFailure)
}

/// Classifies a terminal snapshot, splitting the tail once for both detectors.
enum TerminalScan {
    static func classify(_ screen: String, agent: String? = nil) -> TerminalState? {
        let tail = terminalTail(screen)
        if let p = TerminalPrompt.detect(tail: tail, agent: agent) { return .prompt(p) }
        if let f = SessionFailure.detect(tail: tail, agent: agent) { return .failure(f) }
        return nil
    }
}
