import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// The terminal consent prompt's screen and keystrokes: framed as the pty
/// protocol, a digit in range answers, Enter and stdin EOF deny, a resize
/// or an out-of-range digit doesn't, and a frame split across reads waits.
@Suite("Terminal consent screen")
struct PumpConsentScreenTests {
    typealias Screen = ACAutomationServer.PumpConsentScreen

    static func data(_ s: String) -> [UInt8] { Screen.frame(0, Array(s.utf8)) }

    @Test func thePromptIsOneDataFrame() {
        let f = Screen.prompt("Use the key?\nfor api.example", choices: ["Allow once", "Deny"])
        #expect(f[0] == 0)
        let len = (Int(f[1]) << 24) | (Int(f[2]) << 16) | (Int(f[3]) << 8) | Int(f[4])
        #expect(len == f.count - 5)
        let text = String(decoding: f.dropFirst(5), as: UTF8.self)
        #expect(text.contains("Use the key?\r\nfor api.example"))
        #expect(text.contains("1\u{1b}[0m) Allow once\r\n") && text.contains("2\u{1b}[0m) Deny\r\n"))
        #expect(text.hasSuffix("Choice [1-2]  (Enter or timeout = deny): "))
        #expect(Screen.clear == Self.data("\u{1b}[2J\u{1b}[H"))
    }

    @Test func aDigitInRangeAnswers() {
        var k = Screen.Keys(choices: 3)
        #expect(k.feed(Self.data("x9")) == .pending, "out of range")
        #expect(k.feed(Screen.frame(1, [0, 80, 0, 24])) == .pending, "a resize")
        #expect(k.feed(Self.data("2")) == .answered(1))
    }

    @Test func enterAndStdinEOFDeny() {
        var k = Screen.Keys(choices: 2)
        #expect(k.feed(Self.data("\r")) == .answered(nil))
        var e = Screen.Keys(choices: 2)
        #expect(e.feed(Screen.frame(3, [])) == .answered(nil))
    }

    @Test func aFrameSplitAcrossReadsWaits() {
        var k = Screen.Keys(choices: 2)
        let f = Self.data("ab1")
        #expect(k.feed(f.prefix(3)) == .pending)
        #expect(k.feed(f.dropFirst(3)) == .answered(0))
    }
}
