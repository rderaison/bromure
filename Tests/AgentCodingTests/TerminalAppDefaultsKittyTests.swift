import Foundation
import Testing
@testable import bromure_ac

/// Coverage for the non-Retina kitty font-size fix. VZ renders the guest
/// framebuffer at the host window's backing pixels (2× on Retina, 1× on a
/// non-Retina screen), so a fixed font_size renders ~2× larger physically on
/// non-Retina. kittyConfig scales the 1.5× Retina factor by the host's backing
/// scale: emitted `font_size = round(userPt * 1.5 * scale/2)` — i.e. 1.5× at
/// scale 2, 0.75× (half of that) at scale 1.
@Suite("kittyConfig font scaling")
struct TerminalAppDefaultsKittyTests {

    private func profile(fontSize: Int) -> Profile {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.customFontSize = fontSize
        return p
    }

    /// The standalone `font_size <n>` directive line (not the `font_size=<n>`
    /// comment), returned as the integer kitty will use.
    private func emittedFontSize(_ conf: String) -> Int? {
        for raw in conf.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("font_size "), !line.hasPrefix("font_size=") else { continue }
            return Int(line.dropFirst("font_size ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    @Test("Retina (scale 2) emits 1.5× the user's point size")
    func retina() {
        let conf = TerminalAppDefaults.kittyConfig(
            for: profile(fontSize: 20),
            terminalDefaults: .fallback,
            displayScale: 2)
        // 20 * 1.5 * 2/2 = 30
        #expect(emittedFontSize(conf) == 30)
        // The annotation comment carries the same value with '='.
        #expect(conf.contains("font_size=30"))
    }

    @Test("Non-Retina (scale 1) emits half of the Retina size — 0.75×")
    func nonRetina() {
        let conf = TerminalAppDefaults.kittyConfig(
            for: profile(fontSize: 20),
            terminalDefaults: .fallback,
            displayScale: 1)
        // 20 * 1.5 * 1/2 = 15  (exactly half of the scale-2 result)
        #expect(emittedFontSize(conf) == 15)
    }

    @Test("Scale-1 is exactly half of scale-2 across sizes")
    func halfRelationship() {
        for pt in [12, 16, 24, 40] {
            let two = TerminalAppDefaults.kittyConfig(
                for: profile(fontSize: pt), terminalDefaults: .fallback, displayScale: 2)
            let one = TerminalAppDefaults.kittyConfig(
                for: profile(fontSize: pt), terminalDefaults: .fallback, displayScale: 1)
            let a = emittedFontSize(two)!
            let b = emittedFontSize(one)!
            // round(pt*1.5) vs round(pt*0.75); for these even sizes b == a/2.
            #expect(b == a / 2)
        }
    }

    @Test("Font size is floored at 8 (kitty's minimum legible size)")
    func minClamp() {
        let conf = TerminalAppDefaults.kittyConfig(
            for: profile(fontSize: 4),     // 4 * 0.75 = 3 → clamped to 8
            terminalDefaults: .fallback,
            displayScale: 1)
        #expect(emittedFontSize(conf) == 8)
    }

    @Test("Defaults to terminalDefaults.fontSize when the profile has none")
    func usesTerminalDefault() {
        let p = Profile(name: "t", tool: .claude, authMode: .token)   // customFontSize nil
        let td = TerminalAppDefaults(fontFamily: "Menlo", fontSize: 12,
                                     backgroundHex: "#000000", foregroundHex: "#ffffff")
        let conf = TerminalAppDefaults.kittyConfig(for: p, terminalDefaults: td, displayScale: 2)
        // 12 * 1.5 = 18
        #expect(emittedFontSize(conf) == 18)
    }

    @Test("Emits the profile's resolved family + colors")
    func familyAndColors() {
        var p = profile(fontSize: 14)
        p.customFontFamily = "Fira Code"
        p.customBackgroundHex = "#101010"
        p.customForegroundHex = "#e0e0e0"
        let conf = TerminalAppDefaults.kittyConfig(
            for: p, terminalDefaults: .fallback, displayScale: 2)
        #expect(conf.contains("font_family Fira Code"))
        #expect(conf.contains("background #101010"))
        #expect(conf.contains("foreground #e0e0e0"))
    }
}
