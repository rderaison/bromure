import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
private typealias OrbBaseView = NSView
#else
import UIKit
private typealias OrbBaseView = UIView
#endif

// MARK: - Shared status views
//
// Small SwiftUI views used by both the macOS windows and the shared boards
// (coding kanban, automation run window), extracted from UnifiedSessionWindow
// so the iOS fat client can compile them.

/// unpeel-style staggered "typing" dots shown while the agent is working.
/// Small status dot overlaid on an agent's icon. Orange gently pulses while the
/// agent is working; green means it finished its turn; red means it's waiting
/// on the user. A thin ring keeps it legible over any icon/background.
struct AgentStatusDot: View {
    let status: AgentStatus
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .working:   return .orange
        case .done:      return .green
        case .needsInput: return .red
        }
    }
    private var help: String {
        switch status {
        case .working:   return NSLocalizedString("Working…", comment: "agent status dot")
        case .done:      return NSLocalizedString("Done", comment: "agent status dot")
        case .needsInput: return NSLocalizedString("Needs your input", comment: "agent status dot")
        }
    }
    /// The bare dot — a filled circle with a thin background-colored ring so it
    /// stays legible over any icon.
    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color.platformWindowBackground, lineWidth: 1.2))
    }

    var body: some View {
        // Only the working dot animates. Done/needs-input render as a plain,
        // STEADY dot in a separate branch, so switching out of .working
        // destroys the animated view entirely — no lingering repeatForever
        // pulse on the green/red dot.
        Group {
            if status == .working {
                dot
                    .scaleEffect(pulse ? 1.12 : 0.82)
                    .opacity(pulse ? 1.0 : 0.5)
                    .onAppear {
                        pulse = false
                        // ~30% slower than the original 0.75s for a gentler pulse.
                        withAnimation(.easeInOut(duration: 0.98).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else {
                dot
            }
        }
        .help(help)
    }
}

/// A session's unread mark: the agent said something (it finished, or it's
/// asking) and nobody has looked yet. A small orb whose colours slowly turn,
/// with a soft glow -- read at a glance down a list, never loud. Still under
/// Reduce Motion. Shared by the Mac sidebar, the fat client and iOS.
struct UnreadMark: View {
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let colors: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 1.00), Color(red: 0.62, green: 0.40, blue: 1.00),
        Color(red: 0.20, green: 0.80, blue: 0.95), Color(red: 0.30, green: 0.55, blue: 1.00),
    ]

    private func orb(_ angle: Double) -> some View {
        Circle()
            .fill(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle)))
            .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.32, y: 0.28),
                                                  startRadius: 0, endRadius: size * 0.55)))
            .frame(width: size, height: size)
            .shadow(color: Self.colors[0].opacity(0.55), radius: size * 0.45)
    }

    var body: some View {
        Group {
            if reduceMotion {
                orb(0)
            } else {
                // The turn runs in Core Animation: a TimelineView redrew it 20
                // times a second, and every redraw re-measured the sidebar it
                // sits in (784 measure passes in 2 s for 20 rows, none now).
                orb(0)
                    .hidden()
                    .overlay(TurningOrb(size: size, colors: Self.colors.map(CrossColor.cg)))
            }
        }
        .accessibilityLabel(NSLocalizedString("Unread", comment: "session list: the agent replied and the user hasn't looked"))
        .help(NSLocalizedString("Unread", comment: "session list: the agent replied and the user hasn't looked"))
    }
}


enum CrossColor {
    static func cg(_ c: Color) -> CGColor {
        #if os(macOS)
        NSColor(c).cgColor
        #else
        UIColor(c).cgColor
        #endif
    }
}

/// `UnreadMark`'s orb, turned by Core Animation: one turn every 6 s in the
/// render server, with no SwiftUI update at all while it turns.
private final class TurningOrbLayerView: OrbBaseView {
    private let turn = CAGradientLayer()
    private let shine = CAGradientLayer()
    private let size: CGFloat
    private let colors: [CGColor]

    init(size: CGFloat, colors: [CGColor]) {
        self.size = size
        self.colors = colors
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        #if os(macOS)
        wantsLayer = true
        guard let base = layer else { return }
        #else
        let base = layer
        #endif
        turn.type = .conic
        turn.colors = colors
        turn.startPoint = CGPoint(x: 0.5, y: 0.5)
        turn.endPoint = CGPoint(x: 0.5, y: 0)
        turn.cornerRadius = size / 2
        turn.masksToBounds = true
        shine.type = .radial
        shine.colors = [CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0)]
        shine.startPoint = CGPoint(x: 0.32, y: 0.30)
        shine.endPoint = CGPoint(x: 0.32 + 0.55, y: 0.30 + 0.55)
        shine.cornerRadius = size / 2
        shine.masksToBounds = true
        base.shadowColor = colors.first
        base.shadowOpacity = 0.55
        base.shadowRadius = size * 0.45
        base.shadowOffset = .zero
        base.addSublayer(turn)
        base.addSublayer(shine)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 6
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        turn.add(spin, forKey: "turn")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(macOS)
    override func layout() { super.layout(); place() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); place() }
    #endif

    private func place() {
        let r = CGRect(x: 0, y: 0, width: size, height: size)
        turn.bounds = r
        turn.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shine.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
    }
}

#if os(macOS)
private struct TurningOrb: NSViewRepresentable {
    let size: CGFloat
    let colors: [CGColor]
    func makeNSView(context: Context) -> TurningOrbLayerView { TurningOrbLayerView(size: size, colors: colors) }
    func updateNSView(_ v: TurningOrbLayerView, context: Context) {}
}
#else
private struct TurningOrb: UIViewRepresentable {
    let size: CGFloat
    let colors: [CGColor]
    func makeUIView(context: Context) -> TurningOrbLayerView { TurningOrbLayerView(size: size, colors: colors) }
    func updateUIView(_ v: TurningOrbLayerView, context: Context) {}
}
#endif
