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

    // The agent-label helpers live in AgentLabel (AgentLabels.swift), which
    // builds without AppKit/SwiftUI (the Linux daemon's session model uses it).
    nonisolated static var knownAgents: [String] { AgentLabel.knownAgents }
    nonisolated static var agentAliases: [String: String] { AgentLabel.agentAliases }
    nonisolated static func agentKind(forLabel label: String) -> String? { AgentLabel.agentKind(forLabel: label) }
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
