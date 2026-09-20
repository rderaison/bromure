import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Cross-platform UI shims
//
// The handful of AppKit touchpoints the shared SwiftUI views need, expressed
// once for both platforms so the same view sources compile into bromure-ac
// (macOS) and the iOS fat client. Values on macOS are byte-identical to the
// direct AppKit calls they replaced.

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

extension PlatformColor {
    /// `NSColor.labelColor` / `UIColor.label`.
    static var platformLabel: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    /// `NSColor.textBackgroundColor` / `UIColor.systemBackground`.
    static var platformTextBackgroundColor: PlatformColor {
        #if os(macOS)
        return .textBackgroundColor
        #else
        return .systemBackground
        #endif
    }
}

// MARK: - Palette
//
// The light appearance is warm paper rather than white-on-white: the values
// are claude.ai's light theme (sidebar #FBFBF9, canvas #FCFCFB, cards pure
// white behind a #E3E3E1 hairline, a warm-grey selection #EDECE8). Dark
// stays the system's. One place to tune.
extension PlatformColor {
    #if os(macOS)
    private static func paper(light: (Int, Int, Int), dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : NSColor(srgbRed: CGFloat(light.0) / 255, green: CGFloat(light.1) / 255, blue: CGFloat(light.2) / 255, alpha: 1)
        }
    }
    /// The content canvas: stage surfaces, headers, the titlebar backing.
    static let acCanvas = paper(light: (0xFC, 0xFC, 0xFB), dark: .windowBackgroundColor)
    /// The sidebar, a touch warmer than the canvas.
    static let acSidebar = paper(light: (0xFB, 0xFB, 0xF9), dark: .windowBackgroundColor)
    /// The titlebar backing. The unified toolbar's strip renders white in the
    /// light appearance whatever sits under it, so the backing is white too —
    /// one uniform titlebar over the paper below.
    static let acTitlebar = paper(light: (0xFF, 0xFF, 0xFF), dark: .windowBackgroundColor)
    /// Card edges (composer, sheets) instead of a shadow.
    static let acHairline = paper(light: (0xE3, 0xE3, 0xE1), dark: NSColor.separatorColor)
    /// The selected sidebar row.
    static let acSelection = paper(light: (0xED, 0xEC, 0xE8), dark: NSColor.controlAccentColor.withAlphaComponent(0.16))
    #endif
}

extension Color {
    /// `NSColor.windowBackgroundColor` / iOS system background.
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .acCanvas)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The sidebar's ground (macOS: warm paper in light, system in dark).
    static var acSidebar: Color {
        #if os(macOS)
        Color(nsColor: .acSidebar)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Card edge hairline.
    static var acHairline: Color {
        #if os(macOS)
        Color(nsColor: .acHairline)
        #else
        Color.primary.opacity(0.10)
        #endif
    }

    /// The selected row's fill.
    static var acSelection: Color {
        #if os(macOS)
        Color(nsColor: .acSelection)
        #else
        Color.accentColor.opacity(0.16)
        #endif
    }

    /// `NSColor.controlBackgroundColor` / iOS secondary system background.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// `NSColor.textBackgroundColor` / iOS system background.
    static var platformTextBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// `NSColor.tertiaryLabelColor` / iOS tertiary label.
    static var platformTertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// `NSColor.separatorColor` / iOS separator.
    static var platformSeparator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}

/// A human-readable name for this device — used when enrolling with the P2P
/// directory. `Host` (Foundation) is macOS-only, so iOS uses UIDevice.
func platformDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    return UIDevice.current.name
    #endif
}

/// Put a string on the general pasteboard (copy-IP, copy-public-key buttons).
func platformCopyToPasteboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}

/// Open a URL in the default browser (`NSWorkspace` / `UIApplication`).
func platformOpenURL(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

/// Fixed-pitch font families installed on this device, for the terminal
/// appearance picker. AppKit exposes `isFixedPitch`; UIKit callers probe a
/// glyph-width heuristic ("i" vs "W") per family.
func platformMonospacedFontFamilies() -> [String] {
    #if os(macOS)
    return NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12)?.isFixedPitch ?? false }
        .sorted()
    #else
    return UIFont.familyNames.filter { family in
        guard let font = UIFont(name: family, size: 12) else { return false }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let narrow = ("i" as NSString).size(withAttributes: attrs).width
        let wide = ("W" as NSString).size(withAttributes: attrs).width
        return abs(narrow - wide) < 0.01
    }.sorted()
    #endif
}


// MARK: - Cross-platform SwiftUI style helpers

extension View {
    /// `.buttonStyle(.link)` is macOS-only; iOS renders a tinted plain button.
    @ViewBuilder func platformLinkButtonStyle() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.plain).foregroundStyle(.tint)
        #endif
    }

    /// `.toggleStyle(.checkbox)` is macOS-only; iOS keeps the default switch.
    @ViewBuilder func platformCheckboxToggle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// Conditional `.labelsHidden()` — SwiftUI's own takes no flag, which
    /// forces callers that sometimes want a visible label into duplicated
    /// view code.
    @ViewBuilder func labelsHidden(_ hide: Bool) -> some View {
        if hide { self.labelsHidden() } else { self }
    }

    /// `.menuStyle(.borderlessButton)` is macOS-only; iOS keeps the default.
    @ViewBuilder func platformBorderlessMenuStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton)
        #else
        self
        #endif
    }

    /// `.onExitCommand` (Escape) exists on macOS only; touch platforms
    /// dismiss with their own gestures, so the action is simply not wired.
    @ViewBuilder func platformExitCommand(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }

    /// Popover content that stays a popover on a compact iPhone instead of
    /// turning into a sheet (the content is sized for an anchored bubble).
    @ViewBuilder func platformCompactPopover() -> some View {
        #if os(iOS) || os(visionOS)
        self.presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }

    /// A fixed popover width, narrowed on a phone so the bubble fits.
    @ViewBuilder func platformPopoverWidth(_ width: CGFloat) -> some View {
        #if os(iOS)
        self.frame(width: UIDevice.current.userInterfaceIdiom == .phone ? min(width, 340) : width)
        #else
        self.frame(width: width)
        #endif
    }

    /// `.pickerStyle(.radioGroup)` is macOS-only; iOS renders a menu picker.
    @ViewBuilder func platformRadioGroupPickerStyle() -> some View {
        #if os(macOS)
        self.pickerStyle(.radioGroup)
        #else
        self.pickerStyle(.menu)
        #endif
    }

    /// Expand to fill the available width when `expand` is true — used by the
    /// phone-compact layouts to make buttons/cards share a row evenly.
    @ViewBuilder func fillWidth(_ expand: Bool) -> some View {
        if expand { self.frame(maxWidth: .infinity) } else { self }
    }

    /// Wrap dense fixed-width content (macOS tables) in a horizontal scroll on a
    /// phone so it scrolls instead of clipping; unchanged elsewhere.
    @ViewBuilder func horizontalScrollIfCompact(_ compact: Bool) -> some View {
        if compact {
            ScrollView(.horizontal, showsIndicators: false) { self }
        } else {
            self
        }
    }
}


#if os(iOS) || os(visionOS)
import UniformTypeIdentifiers

/// A downloaded file to hand to the iOS share sheet (Save to Files / share).
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController bridged into SwiftUI — the iOS "share / Save to
/// Files" sheet for a downloaded guest file.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
