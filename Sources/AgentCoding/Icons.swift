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

    nonisolated static let knownAgents: [String] = [
        "claude", "codex", "grok", "aider", "goose", "amp",
        "opencode", "gemini", "cursor",
    ]

    /// The foreground program a tmux window reports maps to a coding agent (and
    /// which one), so the sidebar can badge it. nil = a plain shell / other.
    ///
    /// Tolerant of the shapes the guest reports: a bare name, a path
    /// (`/usr/bin/claude`), an extension (`claude.exe`, `claude.js`), a wrapped
    /// command (`node claude`), or — once the agent sets its OSC-2 session title
    /// — the renamed form the guest publishes, `"<title> (<agent>)"`. That
    /// trailing marker is authoritative and checked FIRST: the title is free
    /// text that may itself name another tool ("Port the codex prompts
    /// (claude)"), so a scan over the whole label would pick the wrong one.
    nonisolated static func agentKind(forLabel label: String) -> String? {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        // "<session title> (<agent>)" — bromure-agentd's `_resolve_tab_name`.
        if lower.hasSuffix(")"), let open = lower.lastIndex(of: "(") {
            let marker = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            if knownAgents.contains(marker) { return marker }
        }
        // Basename of the first whitespace-separated token, minus any extension.
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
        let base = (firstWord as NSString).lastPathComponent
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        if knownAgents.contains(stem) { return stem }
        // Fallback: the agent name appears as a whole word somewhere in the
        // label (e.g. `node /opt/claude.js`) — word-wise, not a raw substring,
        // so "claudette" or "amplify" don't read as agents.
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
        return knownAgents.first { words.contains($0) }
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
