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
