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
    private func bold(_ s: String) -> String   { "\u{1B}[1m\(s)\u{1B}[22m" }
    private func dim(_ s: String) -> String     { "\u{1B}[2m\(s)\u{1B}[22m" }
    private func invert(_ s: String) -> String  { "\u{1B}[7m\(s)\u{1B}[27m" }

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
              initial: Int = 0) -> Int? {
        guard !items.isEmpty else { return nil }
        var sel = min(max(initial, 0), items.count - 1)
        while true {
            render(title: title, items: items, selected: sel,
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

    private func render(title: String, items: [String], selected: Int, footer: String) {
        clear()
        let (cols, rows) = size
        let width = max(20, min(cols, 100))
        let bar = String(repeating: "─", count: width - 2)
        move(row: 1, col: 1); write("┌" + bar + "┐")
        move(row: 2, col: 1); write("│ " + bold(pad(title, width - 4)) + " │")
        move(row: 3, col: 1); write("├" + bar + "┤")

        // Body, clipped to the available rows (leave room for header + footer).
        let bodyRows = max(1, rows - 6)
        let start = max(0, min(selected - bodyRows + 1, items.count - bodyRows))
        var line = 4
        for i in start..<min(items.count, start + bodyRows) {
            let label = " " + pad(items[i], width - 4) + " "
            move(row: line, col: 1)
            write("│" + (i == selected ? invert(label) : label) + "│")
            line += 1
        }
        move(row: line, col: 1); write("└" + bar + "┘")
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
            move(row: 1, col: 1); write(bold(pad(title, width)))
            move(row: 2, col: 1); write(dim(String(repeating: "─", count: width)))
            var line = 3
            for i in top..<min(lines.count, top + bodyRows) {
                move(row: line, col: 1); write(pad(clip(lines[i], width), width)); line += 1
            }
            let more = lines.count > bodyRows ? " · ↑/↓ scroll" : ""
            move(row: rows, col: 1); write(dim(pad("q/Enter back\(more)", width)))
            switch readKey() {
            case .up:   top = max(0, top - 1)
            case .down: top = min(max(0, lines.count - bodyRows), top + 1)
            case .enter, .escape, .char("q"), .char("Q"): return
            default: break
            }
        }
    }

    /// Single-line text input with echo. Returns nil on Esc.
    func prompt(_ label: String, secret: Bool = false) -> String? {
        // Render on a clean screen, with the cursor visible for typing.
        clear()
        write("\u{1B}[?25h")
        defer { write("\u{1B}[?25l") }
        move(row: 2, col: 2); write(bold(label))
        move(row: 4, col: 2); write("> ")
        var buf = ""
        while true {
            switch readKey() {
            case .enter:  return buf
            case .escape: return nil
            case .backspace:
                if !buf.isEmpty { buf.removeLast(); write("\u{8} \u{8}") }
            case .char(let c):
                buf.append(c)
                write(secret ? "*" : String(c))
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
        move(row: rows - 1, col: 2); write(invert(" \(message) "))
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
