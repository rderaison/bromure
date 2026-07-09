import AppKit
import Foundation
import SandboxEngine

/// Snapshot of the user's Terminal.app default-profile settings —
/// background/foreground colors, font family, font size. Used to seed
/// kitty's appearance so moving from Terminal.app into Bromure AC's
/// kitty feels visually continuous.
public struct TerminalAppDefaults: Sendable {
    public let fontFamily: String
    public let fontSize: Int
    public let backgroundHex: String   // "#RRGGBB"
    public let foregroundHex: String

    /// Sensible fallback if Terminal.app isn't installed, has never been
    /// opened, or its prefs are unreadable.
    public static let fallback = TerminalAppDefaults(
        fontFamily: "JetBrains Mono",
        fontSize: 14,
        backgroundHex: "#0d1117",
        foregroundHex: "#c9d1d9"
    )

    /// Read ~/Library/Preferences/com.apple.Terminal.plist via UserDefaults.
    /// Falls back silently if anything's missing — never throws.
    public static func load() -> TerminalAppDefaults {
        guard let prefs = UserDefaults(suiteName: "com.apple.Terminal"),
              let windowSettings = prefs.dictionary(forKey: "Window Settings"),
              let defaultName = (prefs.string(forKey: "Default Window Settings")
                                 ?? prefs.string(forKey: "Startup Window Settings")),
              let profile = windowSettings[defaultName] as? [String: Any]
        else {
            return .fallback
        }

        // Font: stored as NSKeyedArchiver(NSFont).
        var family = fallback.fontFamily
        var size = fallback.fontSize
        if let fontData = profile["Font"] as? Data,
           let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: fontData) {
            family = font.familyName ?? font.fontName
            // Round to nearest int — kitty's font_size accepts floats but
            // most users picked round values in Terminal.
            size = max(8, Int(font.pointSize.rounded()))
        }

        let bg = hex(from: profile["BackgroundColor"] as? Data) ?? fallback.backgroundHex
        let fg = hex(from: profile["TextColor"] as? Data) ?? fallback.foregroundHex

        return TerminalAppDefaults(
            fontFamily: family,
            fontSize: size,
            backgroundHex: bg,
            foregroundHex: fg
        )
    }

    private static func hex(from data: Data?) -> String? {
        guard let data,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

import SwiftUI

extension Color {
    /// Parse "#RRGGBB" / "RRGGBB" into a SwiftUI Color. Falls back to
    /// black on malformed input.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        self = Color(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8)  & 0xFF) / 255.0,
            blue:  Double(rgb         & 0xFF) / 255.0
        )
    }

    /// Encode this Color as "#RRGGBB" via sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension TerminalAppDefaults {

    /// Render a ghostty config for a native terminal surface from the same
    /// profile appearance that drives `kittyConfig` — the host-side twin of
    /// the guest kitty translation. `profile` nil renders app-level
    /// defaults (used for the ghostty app's base config before any surface).
    ///
    /// Unlike kitty (guest X at synthetic DPI), ghostty renders host-side,
    /// so the point size is used as-is — no 1.5× DPI factor.
    public static func ghosttyConfig(for profile: Profile?,
                                     terminalDefaults: TerminalAppDefaults) -> String {
        let style = profile?.resolveStyle(against: terminalDefaults) ?? terminalDefaults

        // Only pass a family CoreText resolves to a fixed-pitch face — a
        // proportional or unresolvable font renders one glyph per grid
        // cell with gaps ("r o o t"). Family-based lookup (NSFont(name:)
        // wants a face name and misses families like "SF Mono", which
        // GhosttyRuntime registers from Terminal.app's private bundle).
        // Menlo always exists on macOS.
        var family = style.fontFamily
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family)
        let faceName = members?.first?.first as? String
        let probe = faceName.flatMap { NSFont(name: $0, size: CGFloat(style.fontSize)) }
        if probe?.isFixedPitch != true {
            family = "Menlo"
        }

        // kitty cursor names → ghostty's (beam is "bar" there).
        let cursor: String
        switch profile?.cursorShape ?? .beam {
        case .block: cursor = "block"
        case .beam: cursor = "bar"
        case .underline: cursor = "underline"
        }

        return """
        # Generated by Bromure AC — rewritten on every launch/profile save.
        font-family = \(family)
        font-size = \(style.fontSize)
        background = \(style.backgroundHex)
        foreground = \(style.foregroundHex)
        cursor-style = \(cursor)
        cursor-style-blink = \(profile?.cursorBlink ?? false)
        # The surface command is our attach pump, not a shell.
        shell-integration = none
        # Closing a surface must never prompt — tmux keeps the state.
        confirm-close-surface = false
        # The "remote" is the user's own tmux session.
        clipboard-paste-protection = false
        clipboard-read = allow
        clipboard-write = allow
        # macOS-like selection: a plain drag selects (tmux mouse is off, so
        # it's ghostty's own selection), selecting never copies on its own,
        # ⌘C copies and ⌘V pastes (bracketed).
        copy-on-select = false
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        # Font zoom, pinned for the same reason. `equal` covers the common
        # unshifted ⌘= press on ANSI layouts; `plus` the shifted/keypad one.
        keybind = super+equal=increase_font_size:1
        keybind = super+plus=increase_font_size:1
        keybind = super+minus=decrease_font_size:1
        keybind = super+zero=reset_font_size
        """
    }

}

extension Profile {
    /// Source the Terminal.app defaults into a brand-new profile's custom
    /// fields so the editor opens with sensible, editable starting values.
    ///
    /// Default font intentionally falls back to **JetBrains Mono** rather
    /// than Terminal.app's font — we install JetBrains Mono via apt at
    /// base-image build time, so it's *guaranteed* to render. macOS
    /// fonts copied into /usr/share/fonts/macos may or may not match
    /// kitty's fontconfig query (e.g. "SF Mono" → fontconfig may not
    /// register it under that exact name). Users can override via the
    /// Appearance picker.
    public mutating func seedAppearance(from terminalDefaults: TerminalAppDefaults) {
        // Hard-coded defaults the team standardized on (matches the
        // 'codex' canonical profile): JetBrains Mono 12 / dark slate
        // background. Foreground falls through to whatever the user's
        // Terminal.app currently uses since most users theme their
        // text colour and we want to respect that.
        if customFontFamily == nil { customFontFamily = "JetBrains Mono" }
        if customFontSize == nil { customFontSize = 12 }
        if customBackgroundHex == nil { customBackgroundHex = "#212734" }
        if customForegroundHex == nil { customForegroundHex = terminalDefaults.foregroundHex }
    }
}
