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

extension Color {
    /// `NSColor.windowBackgroundColor` / iOS system background.
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
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
