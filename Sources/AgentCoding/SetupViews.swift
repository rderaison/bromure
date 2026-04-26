import AppKit
import SwiftUI

// MARK: - Init progress model

/// Observable model the GUI binds to during base-image creation.
/// `ACAppDelegate` updates `status` and appends to `consoleLog` from
/// `createBaseImage`'s progress callback; the views below redraw as it
/// changes.
@MainActor
@Observable
final class InitProgressModel {
    var status: String = "Preparing…"
    /// Rolling buffer of the installer's serial output. Only the last
    /// `maxLines` complete lines (plus any in-progress trailing partial
    /// line) are kept so SwiftUI's Text reflow stays cheap during a
    /// long apt/debootstrap run that emits hundreds of KB.
    var consoleLog: String = ""
    var error: String?
    var isRunning: Bool = false

    /// 0…1, monotonic. Driven primarily by line count — every line
    /// of installer output (apt, debootstrap, npm, GitHub fetches,
    /// the host's own progress messages) bumps the bar by
    /// `1 / expectedTotalLines`. The "Base image ready" host phase
    /// then jumps to 1.0 so the tail is always reached.
    var progress: Double = 0.0

    /// Total log lines we expect during a full bake. Calibrated
    /// against a real run on Apple Silicon (≈7056 lines on a fresh
    /// debootstrap+apt+npm chain) with a small margin so future
    /// step additions or network retries don't overshoot the
    /// ceiling. With actual = 7056, the bar lands around 94% just
    /// before the final "Base image ready" phase jumps to 1.0.
    private static let expectedTotalLines = 7500

    /// Cap line-driven progress here so the host's terminal phase
    /// always has visible distance to cover. "Base image ready"
    /// bumps to 1.0; everything else is line-driven below this.
    private static let progressCeiling = 0.97

    /// Public so the caller can log it on completion (drives the
    /// process of tuning `expectedTotalLines`). Counts every \n
    /// observed in `appendLog`.
    private(set) var linesSeen = 0

    private let maxLines = 100
    private var lines: [String] = []
    private var trailing: String = ""

    /// Reset for a new bake run. Called by the start path before
    /// kicking off `createBaseImage`.
    func reset() {
        status = "Preparing…"
        consoleLog = ""
        error = nil
        isRunning = true
        progress = 0.0
        linesSeen = 0
        lines = []
        trailing = ""
    }

    /// No-op holdover so callers that paired `reset()` with `stop()`
    /// (back when an interpolation timer needed teardown) keep
    /// working without a behavioural change.
    func stop() {}

    /// Move the bar to at least `value`, clamped to [0, 1]. Never
    /// regresses — every setter routes through here.
    func bumpProgress(to value: Double) {
        let v = max(0.0, min(1.0, value))
        if v > progress { progress = v }
    }

    /// Bookend host-phase recogniser: cached-image fast path, and
    /// the final "ready" jump to 1.0. Everything in between is
    /// driven by the line counter — we don't need fine-grained
    /// host phases anymore because the host's progress messages
    /// also flow through `appendLog` and count as lines.
    func recordHostPhase(_ msg: String) {
        let m = msg.lowercased()
        if m.contains("base image already at") || m.contains("base image ready") {
            bumpProgress(to: 1.0)
        }
    }

    func appendLog(_ chunk: String) {
        // Normalise line endings before splitting. The Alpine
        // installer's serial console emits `\r` (or `\r\n`) for
        // newlines, not bare `\n`, so the original
        // `firstIndex(of: "\n")` matched zero times and every chunk
        // accumulated forever in `trailing`. Collapse CRLF to LF
        // first so we don't double-count, then turn any remaining
        // CR into LF.
        let normalized = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var buf = trailing + normalized
        trailing = ""
        while let nl = buf.firstIndex(of: "\n") {
            let line = String(buf[..<nl])
            lines.append(line)
            linesSeen += 1
            // Each line nudges the bar by 1/expectedTotalLines,
            // capped at progressCeiling so the final phase jump to
            // 1.0 is always visible. If real installs exceed the
            // estimate the bar simply pins at the ceiling for the
            // tail.
            let frac = Double(linesSeen) / Double(Self.expectedTotalLines)
            bumpProgress(to: min(frac, Self.progressCeiling))
            buf = String(buf[buf.index(after: nl)...])
        }
        trailing = buf
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        if trailing.isEmpty {
            consoleLog = lines.joined(separator: "\n")
        } else if lines.isEmpty {
            consoleLog = trailing
        } else {
            consoleLog = lines.joined(separator: "\n") + "\n" + trailing
        }
    }
}

// MARK: - First-run welcome

/// Shown when no base image exists. User clicks "Get Started" to kick
/// off `bromure-ac init` from inside the GUI.
struct SetupView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Welcome to Bromure Agentic Coding")
                .font(.title2.bold())
            Text("First-time setup downloads Ubuntu Server and installs Node.js, Claude Code, Codex, kitty, and the desktop chrome inside an isolated VM. Only happens once per base-image version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button(action: onStart) {
                Label("Get Started", systemImage: "arrow.down.circle.fill")
                    .frame(width: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Initializing progress

/// Shown while `createBaseImage` is running. Spinner + latest status +
/// collapsible console log of every progress message.
struct InitializingView: View {
    let model: InitProgressModel
    let onCancel: () -> Void

    /// Console pane is collapsed by default — the determinate progress
    /// bar is enough for the common case. Power users can expand the
    /// disclosure arrow to watch the firehose.
    @State private var consoleExpanded: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Building base image")
                        .font(.headline)
                    Text("This is the one-time install. Don't close the window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if model.error != nil {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    Text(model.error ?? model.status)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    if model.error == nil {
                        Text(String(format: "%.1f%%", model.progress * 100))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if model.error == nil {
                    ProgressView(value: model.progress, total: 1.0)
                        .progressViewStyle(.linear)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))

            DisclosureGroup(isExpanded: $consoleExpanded) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.consoleLog.isEmpty ? "(waiting for installer output…)" : model.consoleLog)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .id("console-bottom")
                    }
                    // Fixed height so the window stays a sensible size.
                    // Without this the ScrollView wants unbounded space
                    // and NSHostingView's intrinsicContentSize blows up
                    // the window. 280pt = ~22 monospace lines, plenty
                    // for watching apt scroll past.
                    .frame(height: 280)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.consoleLog) {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
            } label: {
                HStack {
                    Text("Console output")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.consoleLog, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the console log to the clipboard")
                    .disabled(model.consoleLog.isEmpty)
                    // Don't let the button click also toggle the disclosure.
                    .allowsHitTesting(true)
                }
                // SwiftUI gives the entire label hit-testing for the
                // disclosure toggle. Make the label region tappable
                // explicitly so clicking the text behaves as expected.
                .contentShape(Rectangle())
            }
            .font(.caption)

            if model.error != nil {
                HStack {
                    Spacer()
                    Button("Close", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
