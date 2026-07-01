import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Minimal hand-rolled ANSI TUI

/// A tiny curses-style terminal UI built on raw ANSI escapes — no ncurses
/// dependency. Drives STDIN/STDOUT directly, so it works transparently over an
/// SSH PTY. Used by `bromure-ac __remote-menu`.
final class TUI {
    enum Key: Equatable {
        case up, down, left, right
        case enter, escape, backspace
        case char(Character)
    }

    private var orig = termios()
    private var rawActive = false

    // MARK: Terminal lifecycle

    /// Enter raw mode + alternate screen + hide cursor. Call `end()` to restore.
    func begin() {
        if isatty(STDIN_FILENO) != 0 {
            tcgetattr(STDIN_FILENO, &orig)
            var raw = orig
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            rawActive = true
        }
        write("\u{1B}[?1049h")   // alternate screen buffer
        write("\u{1B}[?25l")     // hide cursor
    }

    func end() {
        write("\u{1B}[?25h")     // show cursor
        write("\u{1B}[?1049l")   // leave alternate screen
        if rawActive {
            var o = orig
            tcsetattr(STDIN_FILENO, TCSANOW, &o)
            rawActive = false
        }
    }

    /// Current terminal size, defaulting to 80x24 if unknown.
    var size: (cols: Int, rows: Int) {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        return (ws.ws_col == 0 ? 80 : Int(ws.ws_col), ws.ws_row == 0 ? 24 : Int(ws.ws_row))
    }

    // MARK: Low-level output

    func write(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, bytes.count) }
    }

    func clear() { write("\u{1B}[2J\u{1B}[H") }
    func move(row: Int, col: Int) { write("\u{1B}[\(row);\(col)H") }

    // MARK: Theme (256-color; degrades gracefully on 8/16-color terminals)

    /// Palette. Muted, cohesive — a blue accent, soft grey chrome.
    private enum C {
        static let border  = 238   // box chrome
        static let title   = 45    // bright cyan title
        static let text    = 252   // primary row text
        static let dim     = 244   // secondary / hints
        static let selBg   = 24    // selection bar background (deep blue)
        static let selFg   = 231   // selection bar text (near-white)
        static let accent  = 39    // prompts, markers
    }
    private let reset = "\u{1B}[0m"
    private func fg(_ n: Int) -> String { "\u{1B}[38;5;\(n)m" }
    private func bg(_ n: Int) -> String { "\u{1B}[48;5;\(n)m" }
    private func bold(_ s: String) -> String   { "\u{1B}[1m\(s)\u{1B}[22m" }
    private func dim(_ s: String) -> String     { fg(C.dim) + s + reset }
    private func colored(_ s: String, _ n: Int) -> String { fg(n) + s + reset }

    // MARK: Input

    /// Block until a key is available. Translates the common escape sequences
    /// (arrows) into `Key` cases.
    func readKey() -> Key {
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(STDIN_FILENO, &b, 1)
            if n <= 0 { return .escape }       // EOF / disconnect → treat as escape
            switch b {
            case 0x0D, 0x0A: return .enter
            case 0x7F, 0x08: return .backspace
            case 0x03, 0x04: return .escape    // Ctrl-C / Ctrl-D
            case 0x1B:
                // Possibly an escape sequence (arrows). Peek ahead non-greedily.
                var b1: UInt8 = 0
                if Darwin.read(STDIN_FILENO, &b1, 1) <= 0 { return .escape }
                guard b1 == 0x5B || b1 == 0x4F else { return .escape }  // '[' or 'O'
                var b2: UInt8 = 0
                if Darwin.read(STDIN_FILENO, &b2, 1) <= 0 { return .escape }
                switch b2 {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                default:   return .escape
                }
            default:
                if let scalar = Unicode.Scalar(UInt32(b)) {
                    return .char(Character(scalar))
                }
            }
        }
    }

    // MARK: Widgets

    /// Draw a full-screen menu and run the selection loop. Returns the chosen
    /// index, or nil if the user backed out (Esc / q / left).
    /// `items` are the row labels; `footer` is the hint line at the bottom.
    func menu(title: String, items: [String], footer: String? = nil,
              header: [String] = [], initial: Int = 0) -> Int? {
        guard !items.isEmpty else { return nil }
        var sel = min(max(initial, 0), items.count - 1)
        while true {
            render(title: title, header: header, items: items, selected: sel,
                   footer: footer ?? "↑/↓ move · Enter select · q back")
            switch readKey() {
            case .up:    sel = (sel - 1 + items.count) % items.count
            case .down:  sel = (sel + 1) % items.count
            case .enter, .right: return sel
            case .escape, .left: return nil
            case .char("q"), .char("Q"): return nil
            case .char(let c) where c.isNumber:
                // 1-based digit jump (and immediate select if it's the only match path).
                if let d = c.wholeNumberValue, d >= 1, d <= items.count { return d - 1 }
            default: break
            }
        }
    }

    private func render(title: String, header: [String] = [], items: [String], selected: Int, footer: String) {
        clear()
        let (cols, rows) = size
        let width = max(24, min(cols, 100))
        let inner = width - 2                              // visible chars between borders
        let hbar = String(repeating: "─", count: inner)
        let border = fg(C.border)

        // Each drawn row is: border │ + `inner` visible chars + border │.
        func side(_ content: String) -> String { border + "│" + reset + content + border + "│" + reset }

        // Rounded top + a cyan title with a subtle left accent tick.
        move(row: 1, col: 1); write(border + "╭" + hbar + "╮" + reset)
        let titleContent = " " + colored("▎", C.accent) + bold(colored(pad(title, inner - 2), C.title))
        move(row: 2, col: 1); write(side(titleContent))
        move(row: 3, col: 1); write(border + "├" + hbar + "┤" + reset)
        var line = 4

        // Optional header block (e.g. a workspace's live vitals), set off with
        // its own separator.
        if !header.isEmpty {
            for h in header {
                move(row: line, col: 1); write(side(" " + dim(pad(h, inner - 1))))
                line += 1
            }
            move(row: line, col: 1); write(border + "├" + hbar + "┤" + reset)
            line += 1
        }

        // Body, clipped to the available rows (leave room for header + footer).
        let headerRows = header.isEmpty ? 0 : header.count + 1
        let bodyRows = max(1, rows - 6 - headerRows)
        let start = max(0, min(selected - bodyRows + 1, max(0, items.count - bodyRows)))
        let end = min(items.count, start + bodyRows)
        for i in start..<end {
            // Marker column (3) + label. Selected rows get a full-width blue bar.
            let marker = (i == selected) ? " ▸ " : "   "
            let rowText = marker + pad(items[i], inner - 3)
            let styled = (i == selected)
                ? bg(C.selBg) + fg(C.selFg) + "\u{1B}[1m" + rowText + reset
                : fg(C.text) + rowText + reset
            move(row: line, col: 1); write(side(styled))
            line += 1
        }
        // Subtle "more above / below" affordance on the bottom rule.
        var bottom = hbar
        if items.count > bodyRows {
            let hint = (start > 0 ? " ↑more " : "") + (end < items.count ? " ↓more " : "")
            if hint.count < inner { bottom = String(hbar.prefix(inner - hint.count)) + hint }
        }
        move(row: line, col: 1); write(border + "╰" + bottom + "╯" + reset)
        move(row: rows, col: 1); write(dim(pad(footer, width)))
    }

    /// Show scrollable text and wait for the user to dismiss it.
    func pager(title: String, body: String) {
        let lines = body.isEmpty ? ["(no output)"] : body
            .replacingOccurrences(of: "\t", with: "    ")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var top = 0
        while true {
            let (cols, rows) = size
            let width = max(20, min(cols, 200))
            let bodyRows = max(1, rows - 4)
            clear()
            move(row: 1, col: 1)
            write(" " + colored("▎", C.accent) + bold(colored(pad(title, width - 2), C.title)))
            move(row: 2, col: 1); write(colored(String(repeating: "─", count: width), C.border))
            var line = 3
            for i in top..<min(lines.count, top + bodyRows) {
                move(row: line, col: 1); write(fg(C.text) + pad(clip(lines[i], width), width) + reset); line += 1
            }
            let more = lines.count > bodyRows ? "  ·  ↑/↓ scroll" : ""
            move(row: rows, col: 1); write(dim(pad("q/Enter back\(more)", width)))
            switch readKey() {
            case .up:   top = max(0, top - 1)
            case .down: top = min(max(0, lines.count - bodyRows), top + 1)
            case .enter, .escape, .char("q"), .char("Q"): return
            default: break
            }
        }
    }

    /// Single-line text input with echo. Returns nil on Esc. `initial`
    /// pre-fills the buffer (editable) so callers can offer the current value
    /// when editing an existing field; `hint` is an optional dim line under the
    /// prompt (e.g. "leave blank to keep the stored secret").
    func prompt(_ label: String, secret: Bool = false,
                initial: String = "", hint: String? = nil) -> String? {
        // Render on a clean screen, with the cursor visible for typing.
        clear()
        write("\u{1B}[?25h")
        defer { write("\u{1B}[?25l") }
        move(row: 2, col: 2); write(colored("▎", C.accent) + " " + bold(colored(label, C.title)))
        if let hint { move(row: 3, col: 4); write(dim(hint)) }
        move(row: 5, col: 2); write(colored("❯ ", C.accent))
        var buf = initial
        write(secret ? String(repeating: "•", count: buf.count) : buf)
        while true {
            switch readKey() {
            case .enter:  return buf
            case .escape: return nil
            case .backspace:
                if !buf.isEmpty { buf.removeLast(); write("\u{8} \u{8}") }
            case .char(let c):
                buf.append(c)
                write(secret ? "•" : String(c))
            default: break
            }
        }
    }

    /// Multi-select checklist. Space toggles the highlighted row; Enter confirms
    /// and returns the set of checked indices; Esc/q returns nil (cancel).
    func checklist(title: String, items: [String], initiallyOn: Set<Int> = [],
                   footer: String? = nil) -> Set<Int>? {
        guard !items.isEmpty else { return [] }
        var on = initiallyOn
        var sel = 0
        while true {
            let rows = items.enumerated().map { i, label in
                "\(on.contains(i) ? "◉" : "◯")  \(label)"
            }
            render(title: title, header: [], items: rows, selected: sel,
                   footer: footer ?? "↑/↓ move  ·  Space toggle  ·  Enter confirm  ·  q cancel")
            switch readKey() {
            case .up:    sel = (sel - 1 + items.count) % items.count
            case .down:  sel = (sel + 1) % items.count
            case .char(" "):
                if on.contains(sel) { on.remove(sel) } else { on.insert(sel) }
            case .enter, .right: return on
            case .escape, .left, .char("q"), .char("Q"): return nil
            default: break
            }
        }
    }

    /// Yes/no confirmation. Default is the value pre-highlighted.
    func confirm(_ question: String, defaultYes: Bool = false) -> Bool {
        switch menu(title: question, items: ["No", "Yes"],
                    footer: "↑/↓ · Enter", initial: defaultYes ? 1 : 0) {
        case 1: return true
        default: return false
        }
    }

    /// Flash a short message and wait for any key.
    func toast(_ message: String) {
        let (_, rows) = size
        move(row: rows - 1, col: 2)
        write(bg(C.selBg) + fg(C.selFg) + "\u{1B}[1m" + " ✓ \(message) " + reset)
        _ = readKey()
    }

    // MARK: Text helpers

    private func pad(_ s: String, _ width: Int) -> String {
        let c = clip(s, width)
        return c.count < width ? c + String(repeating: " ", count: width - c.count) : c
    }
    private func clip(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(max(0, width - 1))) + "…"
    }
}
