import AppKit
import SwiftUI

/// The Sidecar mark (the app icon's glyph) at menu sizes.
enum SidecarMark {
    static let mark: NSImage? = AgentSpec.resourceImage("brand/mark.svg")

    /// The menu-bar image: the mark as a template, and a dot cut beside it
    /// when an agent needs the user.
    static func menuBarImage(badge: Bool) -> NSImage {
        guard let mark else {
            return NSImage(systemSymbolName: badge ? "exclamationmark.bubble" : "terminal",
                           accessibilityDescription: "Bromure Sidecar") ?? NSImage()
        }
        let h: CGFloat = 16
        let w = (h * mark.size.width / max(mark.size.height, 1)).rounded()
        let dot: CGFloat = 6
        let size = NSSize(width: badge ? w + dot - 1 : w, height: h)
        let img = NSImage(size: size, flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            if badge {
                let r = NSRect(x: size.width - dot, y: h - dot, width: dot, height: dot)
                // A clear ring first, so the dot reads apart from the mark.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// `image` scaled to `height`, keeping its proportions (menu item icons).
    static func sized(_ image: NSImage, height: CGFloat) -> NSImage {
        let w = (height * image.size.width / max(image.size.height, 1)).rounded()
        let img = NSImage(size: NSSize(width: w, height: height), flipped: false) { r in
            image.draw(in: r)
            return true
        }
        img.isTemplate = image.isTemplate
        return img
    }
}

/// The menu's first row: the mark, the name, and where this Mac's agents
/// can be reached from.
enum SidecarMenuHeader {
    struct Status {
        enum Tone { case good, busy, idle, error }
        var text: String
        var tone: Tone
    }

    @MainActor static func view(status: Status) -> NSView {
        let host = NSHostingView(rootView: HeaderView(status: status))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 54)
        return host
    }

    private struct HeaderView: View {
        let status: Status

        var body: some View {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.40, green: 0.46, blue: 1.0),
                                                      Color(red: 0.30, green: 0.36, blue: 0.97)],
                                             startPoint: .top, endPoint: .bottom))
                    if let mark = SidecarMark.mark {
                        Image(nsImage: mark).resizable().renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bromure Sidecar").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(dotColor).frame(width: 6, height: 6)
                        Text(status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: 300, height: 54, alignment: .leading)
        }

        private var dotColor: Color {
            switch status.tone {
            case .good: return .green
            case .busy: return .orange
            case .idle: return .secondary
            case .error: return .red
            }
        }
    }
}
