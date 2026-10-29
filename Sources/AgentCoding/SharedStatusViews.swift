import SwiftUI

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
                // A slow turn (one every 6 s), redrawn at 20 fps at most: a
                // handful of these in a sidebar costs next to nothing, and the
                // timeline stops with the view (no lingering animation).
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { t in
                    orb(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) * 60)
                }
            }
        }
        .accessibilityLabel(NSLocalizedString("Unread", comment: "session list: the agent replied and the user hasn't looked"))
        .help(NSLocalizedString("Unread", comment: "session list: the agent replied and the user hasn't looked"))
    }
}
