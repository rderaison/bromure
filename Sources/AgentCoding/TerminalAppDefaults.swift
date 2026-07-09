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
    /// Host display backing scale (1 = non-Retina, 2 = Retina), used to size
    /// the guest's kitty font so it isn't doubled on a non-Retina screen.
    /// Mirrors the image-build-time detection in `UbuntuImageManager`.
    @MainActor public static func currentDisplayScale() -> Int {
        Int(NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// Render a complete kitty.conf for `profile` using its overrides
    /// (with `terminalDefaults` filling per-field gaps) plus the cursor
    /// shape, opacity, standard bindings, and URL-open hook. Result is
    /// dropped at ~/.config/kitty/kitty.conf in the guest's home.
    public static func kittyConfig(for profile: Profile,
                                   terminalDefaults: TerminalAppDefaults,
                                   displayScale: Int = 2) -> String {
        let style = profile.resolveStyle(against: terminalDefaults)
        // Empirical conversion: Terminal.app's 12pt visually matches kitty's
        // 18pt under our default X DPI (96) **on a Retina display** — VZ renders
        // the guest framebuffer at the host window's *backing* pixels (2× dense
        // on Retina, 1× otherwise). On a non-Retina display the framebuffer is
        // half as dense, so a fixed font_size renders ~2× larger physically.
        // Scale the 1.5× Retina factor by the host's backing scale so the font
        // is the same physical size on either screen: 1.5× on Retina (scale 2),
        // 0.75× on non-Retina (scale 1). Live ⌘+ / ⌘- still fine-tunes.
        let factor = 1.5 * Double(displayScale) / 2.0
        let size = max(8, Int((Double(style.fontSize) * factor).rounded()))
        let opacity = String(format: "%.2f", min(1.0, max(0.3, profile.windowOpacity)))
        _ = opacity  // intentionally unused: handled by NSWindow.alphaValue
        let stamp = ISO8601DateFormatter().string(from: Date())
        return """
        # Generated by Bromure Agentic Coding from this profile's appearance.
        # Profile: \(profile.name)  •  written: \(stamp)
        # font_family=\(style.fontFamily)  font_size=\(size)  cursor=\(profile.cursorShape.rawValue)
        # If kitty isn't using these values, run `kitty --debug-config`
        # inside the VM to see which kitty.conf it actually loaded.
        # Edit ~/.bashrc.local for shell customizations; this file is
        # rewritten on every launch.

        font_family \(style.fontFamily)
        font_size \(size)
        \(profile.fontLigatures ? "# Font ligatures enabled for this profile." : "disable_ligatures always")
        background \(style.backgroundHex)
        foreground \(style.foregroundHex)
        cursor_shape \(profile.cursorShape.rawValue)
        cursor_blink_interval 0
        # Disable shell integration's cursor management — by default it
        # injects bash hooks that toggle the cursor (beam during input,
        # block while a command runs), overriding cursor_shape from this
        # config. `no-cursor` keeps everything else (sane prompt, exit
        # status reporting) but leaves the cursor under our control.
        shell_integration no-cursor
        hide_window_decorations yes
        window_padding_width 16
        enable_audio_bell no
        remember_window_size no

        # Render-loop throttling. kitty renders via Mesa llvmpipe inside
        # the VM (LIBGL_ALWAYS_SOFTWARE=1 in xinitrc), so every frame is
        # pure guest CPU — AND every frame kitty presents is scanned out
        # over virtio-gpu and re-composited by the host VZVirtualMachineView,
        # so a high frame rate also pins the *host* GPU. An animating agent
        # TUI (spinner / token counter / input shimmer) produces continuous
        # damage, so kitty would otherwise repaint at the ~60 FPS floor
        # forever and hold the host GPU at ~40% on an "idle" session.
        #
        # Nothing here needs 60 FPS — it's an agent terminal that mostly
        # streams text. sync_to_monitor is off (no reliable vblank in the
        # VM — left on, it just busy-waits) and repaint_delay is set to
        # 250 ms (~4 FPS). An animating TUI then drives at most ~4 host
        # composites/sec instead of ~60, which is the bulk of the GPU win
        # (an idle-but-animating session drops from ~40% to single digits).
        # Trade-off: keystroke echo can lag up to repaint_delay; lower this
        # (e.g. 100 = 10 FPS) if typing feels sticky.
        sync_to_monitor no
        repaint_delay 250
        input_delay 10
        # Sealed VM — kitty's periodic update check is just a wakeup.
        update_check_interval 0
        # Transparency is handled host-side via NSWindow.alphaValue;
        # `background_opacity` here would error inside the VM (no X
        # compositor) and might cause kitty to ignore the whole config.

        # Hide kitty's own tab bar — Bromure AC uses macOS native window
        # tabs instead. Kitty stays single-tab forever.
        tab_bar_style hidden

        # Discard kitty's tab shortcuts entirely. `no_op` only kills the
        # kitty action, but kitty's extended keyboard protocol still
        # forwards the keystroke to the running shell (it shows up as
        # CSI sequences like `6;9u`). `discard_event` is the action that
        # truly consumes the keystroke at every level.
        map super+t              discard_event
        map super+w              discard_event
        map super+n              discard_event
        map super+h              discard_event
        map super+m              discard_event
        map super+q              discard_event
        map super+tab            discard_event
        map super+shift+tab      discard_event
        map super+space          discard_event
        map super+`              discard_event
        map super+shift+left     discard_event
        map super+shift+right    discard_event
        map super+1              discard_event
        map super+2              discard_event
        map super+3              discard_event
        map super+4              discard_event
        map super+5              discard_event
        map super+6              discard_event
        map super+7              discard_event
        map super+8              discard_event
        map super+9              discard_event

        # Fix double-delete (and double-enter / double-tab) for crossterm
        # TUIs like codex and grok. They enable kitty's keyboard protocol
        # with REPORT_EVENT_TYPES (codex pushes `CSI >7u`, grok `CSI >3u`),
        # and kitty 0.32.2 then reports the *release* of a legacy key by
        # re-emitting its legacy byte — so one Backspace arrives as `7f 7f`,
        # one Enter as `0d 0d`, one Tab as `09 09`, deleting/submitting
        # twice. (Ink-based agents like claude never enable the protocol, so
        # they're immune — hence the per-app asymmetry.) Mapping each key to
        # send_text makes kitty emit the byte once, on press only, bypassing
        # the protocol's release encoding. Modified variants (shift+enter for
        # newline, shift+tab, …) are distinct key specs and still flow
        # through the protocol untouched.
        map backspace send_text all \\x7f
        map enter     send_text all \\r
        map tab       send_text all \\t

        # macOS muscle memory: copy/paste/select-all + font size.
        map super+c    copy_to_clipboard
        map super+v    paste_from_clipboard
        map super+a    select_all
        map super+plus change_font_size all +2.0
        map super+minus change_font_size all -2.0
        map super+0    change_font_size all 0

        # Send URL clicks to the macOS host's default browser.
        open_url_with /usr/local/bin/bromure-open

        \(Self.scrollDirectionStanza())
        """
    }

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
        """
    }

    /// Natural-scrolling stanza for kitty, derived from the host's
    /// `com.apple.swipescrolldirection` pref captured at session prep.
    ///
    /// Why this is the right layer: the running base image doesn't
    /// ship `xinput`, so per-device libinput natural-scrolling toggles
    /// fail silently. VZ's USB HID does forward wheel reports, so the
    /// guest's X stack sees scroll events — kitty's
    /// `wheel_scroll_multiplier` (low-precision) /
    /// `touch_scroll_multiplier` (high-precision) flip the direction
    /// at the kitty level. Negative magnitudes preserve speed.
    private static func scrollDirectionStanza() -> String {
        let natural = VMConfig.detectNaturalScrolling()
        // Defaults pulled from kitty's documented values so we don't
        // accidentally change scroll speed when toggling direction.
        let wheel: Double = natural ? -5.0 : 5.0
        let touch: Double = natural ? -1.0 : 1.0
        return """
        # Scroll direction matches the macOS host (natural=\(natural)).
        # See: https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.wheel_scroll_multiplier
        wheel_scroll_multiplier \(wheel)
        touch_scroll_multiplier \(touch)
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
