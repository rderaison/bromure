import SwiftUI

/// The "something is happening" screen shown over a terminal pane while its VM
/// boots and the guest tmux comes up — removed the instant the first roster
/// lands (see `SessionPane`). Ghost-in-the-Shell themed: a cyber digital-rain
/// field, a diving-reticle HUD, and cycling boot chatter. Doubles as the boot
/// watchdog surface: after the timeout it flips to a failure state offering a
/// base-image reset.
@MainActor
@Observable
final class BootOverlayModel {
    var workspaceName: String = ""
    /// Workspace accent, drives the HUD reticle + glow.
    var accentHex: String = "#38f9d7"
    /// Flipped by the watchdog: swap the dive HUD for the failure panel.
    var failed = false
    /// When the boot began — the HUD elapsed counter + rain seed.
    let startedAt = Date()
}

struct BootAnimationView: View {
    @Bindable var model: BootOverlayModel
    /// Failure panel actions.
    let onReset: () -> Void
    let onKeepWaiting: () -> Void

    private var accent: Color { Color(hex: model.accentHex) }

    var body: some View {
        ZStack {
            Color.black
            // Subtle depth behind the HUD.
            RadialGradient(
                colors: [accent.opacity(model.failed ? 0 : 0.10), .clear],
                center: .center, startRadius: 0, endRadius: 360)
            RadialGradient(
                colors: [.clear, .black.opacity(0.7)],
                center: .center, startRadius: 40, endRadius: 520)
            if model.failed {
                FailurePanel(workspaceName: model.workspaceName,
                             onReset: onReset, onKeepWaiting: onKeepWaiting)
            } else {
                DiveHUD(model: model, accent: accent)
            }
            ScanlineOverlay()
        }
        .clipped()
    }
}

// MARK: - Dive HUD

private struct DiveHUD: View {
    @Bindable var model: BootOverlayModel
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(model.startedAt)
            VStack(spacing: 22) {
                Reticle(accent: accent, elapsed: elapsed)
                    .frame(width: 128, height: 128)

                Text(model.workspaceName.isEmpty ? "WORKSPACE" : model.workspaceName.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.9))

                IndeterminateBar(accent: accent, elapsed: elapsed)
                    .frame(width: 220, height: 3)
            }
        }
    }
}

/// Rotating dashed dive-reticle: two counter-spinning rings, a crosshair, and
/// a pulsing core.
private struct Reticle: View {
    let accent: Color
    let elapsed: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   dash: [3, 6]))
                .rotationEffect(.degrees(elapsed * 60))
            Circle()
                .trim(from: 0, to: 0.35)
                .stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .padding(14)
                .rotationEffect(.degrees(-elapsed * 110))
            // Crosshair.
            Path { p in
                p.move(to: CGPoint(x: 64, y: 40)); p.addLine(to: CGPoint(x: 64, y: 54))
                p.move(to: CGPoint(x: 64, y: 74)); p.addLine(to: CGPoint(x: 64, y: 88))
                p.move(to: CGPoint(x: 40, y: 64)); p.addLine(to: CGPoint(x: 54, y: 64))
                p.move(to: CGPoint(x: 74, y: 64)); p.addLine(to: CGPoint(x: 88, y: 64))
            }
            .stroke(accent.opacity(0.6), lineWidth: 1)
            let pulse = 0.5 + 0.5 * sin(elapsed * 3)
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .opacity(0.5 + 0.5 * pulse)
                .shadow(color: accent, radius: 6 * pulse)
        }
    }
}

/// Indeterminate scanning bar — a bright packet sweeping a dim track.
private struct IndeterminateBar: View {
    let accent: Color
    let elapsed: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = (sin(elapsed * 1.6) * 0.5 + 0.5) * (w - 60)
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.clear, accent, .white, accent, .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 60)
                    .offset(x: x)
            }
        }
    }
}

// MARK: - Scanline sheen

private struct ScanlineOverlay: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geo in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let y = (t.truncatingRemainder(dividingBy: 4) / 4) * geo.size.height
                LinearGradient(colors: [.clear, .white.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .offset(y: y - 45)
                    .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Failure / watchdog panel

private struct FailurePanel: View {
    let workspaceName: String
    let onReset: () -> Void
    let onKeepWaiting: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
                .shadow(color: .red.opacity(0.6), radius: 10)
            VStack(spacing: 6) {
                Text("DIVE FAILED")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(.white)
                Text(workspaceName.isEmpty
                     ? "No terminal handshake after 30 seconds."
                     : "“\(workspaceName)” never returned a terminal after 30 seconds.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Text("The VM may be stuck, or the base image may be damaged.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button(action: onKeepWaiting) {
                    Text("Keep Waiting")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().strokeBorder(.white.opacity(0.3)))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                Button(action: onReset) {
                    Text("Reset Base Image…")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(.red.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.red.opacity(0.4)))
    }
}
