import Foundation
import Testing
@testable import bromure_ac

/// Hermes Agent's composer, as `capture-pane -e` returns it (captured live,
/// Hermes 0.23): a rule, the `❯ ` row, a rule, the status bar. Its empty box
/// shows a rotating suggestion in italic yellow — read as typed text, every
/// message to Hermes looked stuck in the box after its Enter: Enter again,
/// then "Not delivered", though Hermes had taken it.
@Suite("Hermes input box")
struct HermesInputBoxTests {
    private let rule = "\u{1B}[38;5;102m" + String(repeating: "─", count: 60) + "\u{1B}[39m"
    private let bar = "\u{1B}[38;5;250m ☤ \u{1B}[1m\u{1B}[38;5;220mgpt-5.5\u{1B}[0m\u{1B}[38;5;101m · ctx -- · / commands · @ files · ! shell\u{1B}[39m"

    private func screen(_ inputRow: String) -> String {
        ["\u{1B}[38;5;230mOK, done.\u{1B}[39m", "", rule, inputRow, rule, bar].joined(separator: "\n")
    }

    @Test("the italic suggestion in an empty box is a placeholder, not a draft")
    func placeholder() {
        let idle = screen("\u{1B}[38;5;230m❯ \u{1B}[3m\u{1B}[38;5;136mDraft a reply to the last email in my inbox\u{1B}[0m")
        #expect(AgentInputBox.content(idle) == .empty)
        #expect(!PaneTypeGuard.boxHolds(idle))
    }

    @Test("typed text is a draft")
    func typed() {
        let draft = screen("\u{1B}[38;5;230m❯ \u{1B}[39msay hello world please")
        #expect(AgentInputBox.content(draft) == .text("say hello world please"))
        #expect(PaneTypeGuard.boxHolds(draft))
    }

    @Test("while a turn runs, its italic hint holds nothing")
    func busy() {
        let busy = screen("\u{1B}[3m\u{1B}[38;5;136m☤ ❯ type to redirect this turn · Tab queues it for after\u{1B}[0m")
        #expect(!PaneTypeGuard.boxHolds(busy))
    }

    @Test("italic ends with SGR 23 or a reset: text after it counts")
    func italicOff() {
        let mixed = screen("\u{1B}[38;5;230m❯ \u{1B}[3mhint\u{1B}[23m real")
        #expect(AgentInputBox.content(mixed) == .text("real"))
    }
}
