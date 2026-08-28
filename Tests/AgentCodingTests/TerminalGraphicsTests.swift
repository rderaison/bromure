import Foundation
import Testing
@testable import bromure_ac

/// The terminal-graphics opt-in (`defaults write io.bromure.agentic-coding
/// terminal.allowGraphics -bool YES`): OFF blocks every image protocol on
/// the host surface; ON lifts the block. Serialized — the toggle rides
/// UserDefaults.standard.
@Suite("Terminal graphics toggle", .serialized)
struct TerminalGraphicsTests {

    @Test("Default deny: the generated ghostty config disables image protocols")
    func defaultDeny() {
        UserDefaults.standard.removeObject(forKey: "terminal.allowGraphics")
        let cfg = TerminalAppDefaults.ghosttyConfig(for: nil, terminalDefaults: .load())
        #expect(cfg.contains("image-storage-limit = 0"))
    }

    @Test("Opt-in lifts the image block")
    func optIn() {
        UserDefaults.standard.set(true, forKey: "terminal.allowGraphics")
        defer { UserDefaults.standard.removeObject(forKey: "terminal.allowGraphics") }
        let cfg = TerminalAppDefaults.ghosttyConfig(for: nil, terminalDefaults: .load())
        #expect(!cfg.contains("image-storage-limit = 0"))
    }
}
