#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Loads SVG icons bundled under `Resources/icons` (cached). The SVGs use
/// `currentColor`/stroke so they tint as template images.
@MainActor
enum BromureIcons {
    private static var cache: [String: PlatformImage] = [:]

    static func image(_ name: String) -> PlatformImage? {
        if let img = cache[name] { return img }
        guard let url = acResourceBundle.url(
                forResource: name, withExtension: "svg", subdirectory: "icons"),
              let data = try? Data(contentsOf: url),
              let img = PlatformImage(data: data) else { return nil }
#if os(macOS)
        img.isTemplate = true
#endif
        cache[name] = img
        return img
    }

    static let knownAgents: [String] = [
        "claude", "codex", "grok", "aider", "goose", "amp",
        "opencode", "gemini", "cursor",
    ]

    /// The foreground program a tmux window reports maps to a coding agent (and
    /// which one), so the sidebar can badge it. nil = a plain shell / other.
    ///
    /// Tolerant of the shapes the guest reports: a bare name, a path
    /// (`/usr/bin/claude`), an extension (`claude.exe`, `claude.js`), or a
    /// wrapped command (`node claude`). Matches on the command basename's stem
    /// first, then falls back to a substring scan.
    static func agentKind(forLabel label: String) -> String? {
        let lower = label.lowercased()
        // Basename of the first whitespace-separated token, minus any extension.
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
        let base = (firstWord as NSString).lastPathComponent
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        if knownAgents.contains(stem) { return stem }
        // Fallback: the agent name appears anywhere (e.g. `node /opt/claude.js`).
        return knownAgents.first { lower.contains($0) }
    }
}

/// SwiftUI wrapper that renders a bundled SVG as a tintable template image,
/// falling back to an SF Symbol when the asset is missing.
struct SVGIcon: View {
    let name: String
    var fallbackSymbol: String = "questionmark"
    var size: CGFloat = 14

    var body: some View {
        if let img = BromureIcons.image(name) {
            Self.templateImage(img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.92))
        }
    }

    /// The bundled SVG as a tintable template `Image`, platform image type
    /// bridged. Returns `Image` (not `some View`) so the caller's `.resizable()`
    /// chain type-checks.
    private static func templateImage(_ img: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: img).renderingMode(.template)
        #else
        Image(uiImage: img).renderingMode(.template)
        #endif
    }
}
