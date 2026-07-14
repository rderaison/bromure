import AppKit
import SandboxEngine
import SwiftUI

// MARK: - Init progress model

/// Observable model the GUI binds to during base-image creation.
/// `ACAppDelegate` updates `status` and appends to `consoleLog` from
/// `createBaseImage`'s progress callback; the views below redraw as it
/// changes.
@MainActor
@Observable
final class InitProgressModel {
    var status: String = NSLocalizedString("Preparing…", comment: "Initial setup status pill, shown before the first installer progress message arrives")
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
    /// Instance-settable: the browser-image install
    /// (BrowserImageInstaller) is far quieter and overrides this.
    var expectedTotalLines = 7500

    /// Cap line-driven progress here so the host's terminal phase
    /// always has visible distance to cover. "Base image ready"
    /// bumps to 1.0; everything else is line-driven below this.
    private static let progressCeiling = 0.97

    /// Public so the caller can log it on completion (drives the
    /// process of tuning `expectedTotalLines`). Counts every \n
    /// observed in `appendLog`.
    private(set) var linesSeen = 0

    // Phase-weighted accounting for the prebuilt-image download path:
    // the image download fills 0→60% of the bar, expansion 60→80%, and
    // the postinstall steps the rest. The postinstall segment anchors
    // wherever the bar sits when it starts, so a standalone postinstall
    // run (consent prompt) maps its steps across the whole bar, and the
    // local bake — which emits none of these messages and stays
    // line-driven — is unaffected.
    private var expectedPostinstallSteps = 0
    private var completedPostinstallSteps = 0
    private var postinstallBase: Double?

    // Browser-image mode (BrowserImageInstaller): phase weights and
    // guest-log narration are delegated to SandboxEngine's shared
    // BrowserInstallProgress (Bromure Web's first-run UI uses the same
    // mapper). Off for the AC Ubuntu flows, whose guest logs use
    // different markers and weights.
    var narrateBrowserGuestLog = false
    private var browserProgress = BrowserInstallProgress()

    private let maxLines = 100
    private var lines: [String] = []
    private var trailing: String = ""

    /// Reset for a new bake run. Called by the start path before
    /// kicking off `createBaseImage`.
    func reset() {
        status = NSLocalizedString("Preparing…", comment: "Initial setup status pill, shown before the first installer progress message arrives")
        consoleLog = ""
        error = nil
        isRunning = true
        progress = 0.0
        linesSeen = 0
        lines = []
        trailing = ""
        expectedPostinstallSteps = 0
        completedPostinstallSteps = 0
        postinstallBase = nil
        narrateBrowserGuestLog = false
        browserProgress = BrowserInstallProgress()
        expectedTotalLines = 7500
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

    /// One-stop host-progress intake: sets the status pill (with any
    /// trailing percentage stripped — the bar is the single percentage
    /// shown in the GUI), advances the phase-weighted bar, and bookmarks
    /// the console log with a leading marker.
    func noteHostProgress(_ msg: String) {
        status = Self.strippingTrailingPercent(from: msg)
        recordHostPhase(msg)
        appendLog("\n▶ " + msg + "\n")
    }

    /// Host-phase recogniser. For the local bake it's just the bookends
    /// (cached-image fast path, final "ready" jump) — everything in
    /// between is line-driven. The download path additionally reports
    /// its phases with percentages, which map onto the 60/20/20 split
    /// documented above.
    func recordHostPhase(_ msg: String) {
        let m = msg.lowercased()
        if m.contains("base image already at") || m.contains("base image ready")
            || m.contains("packages installed") {
            bumpProgress(to: 1.0)
            return
        }
        // "Downloading Ubuntu 24.04 image (2.9 GB)… 37%" → 0…0.60.
        // (The Alpine netboot download doesn't carry a percentage, so it
        // can't match.)
        if m.hasPrefix("downloading"), m.contains("image"), m.hasSuffix("%") {
            if let pct = Self.trailingPercent(of: m) {
                bumpProgress(to: 0.60 * pct)
            }
            return
        }
        if m.hasPrefix("verifying checksum") {
            bumpProgress(to: 0.60)
            return
        }
        // "Expanding image…" / "Expanding image… 45%" → 0.60…0.80.
        if m.hasPrefix("expanding image") {
            bumpProgress(to: 0.60 + 0.20 * (Self.trailingPercent(of: m) ?? 0.0))
            return
        }
        // "Installing recommended packages (4 step(s)…" — anchor the
        // final segment at the bar's current position; each guest-side
        // "END   step" line (spotted by appendLog) advances it.
        if m.hasPrefix("installing recommended packages") {
            if let n = Self.firstInt(of: m), n > 0 {
                expectedPostinstallSteps = n
                completedPostinstallSteps = 0
                postinstallBase = progress
            }
            return
        }
    }

    /// Browser-image host-progress intake (AC downloading Bromure Web's
    /// Alpine/Chromium image — BrowserImageInstaller). Same pill/log
    /// handling as `noteHostProgress`; the phase weights come from the
    /// shared SandboxEngine mapper.
    func noteBrowserHostProgress(_ msg: String) {
        browserProgress.noteHostMessage(msg)
        status = browserProgress.status
        bumpProgress(to: browserProgress.fraction)
        appendLog("\n▶ " + msg + "\n")
    }

    /// "…foo… 37%" → 0.37. nil when the message doesn't end in a percent.
    private static func trailingPercent(of msg: String) -> Double? {
        guard msg.hasSuffix("%") else { return nil }
        let digits = msg.dropLast().reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let v = Int(String(digits.reversed())) else { return nil }
        return min(1.0, Double(v) / 100.0)
    }

    /// First run of digits in the message ("(4 step(s)…" → 4).
    private static func firstInt(of msg: String) -> Int? {
        var current = ""
        for ch in msg {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                break
            }
        }
        return Int(current)
    }

    /// Drop a trailing " NN%" so the status pill doesn't show a second
    /// percentage next to the bar's.
    static func strippingTrailingPercent(from msg: String) -> String {
        guard msg.hasSuffix("%") else { return msg }
        var s = msg.dropLast()
        let digitsEnd = s.endIndex
        while let c = s.last, c.isNumber { s = s.dropLast() }
        guard s.endIndex != digitsEnd else { return msg }  // bare "%" — leave it
        while s.last == " " { s = s.dropLast() }
        return String(s)
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
            if narrateBrowserGuestLog {
                // Browser-image install: the guest log narrates the pill
                // and drives the tail segment via the shared mapper (its
                // own step accounting — the generic handler below would
                // double-count).
                browserProgress.noteGuestLine(line)
                if !browserProgress.status.isEmpty { status = browserProgress.status }
                bumpProgress(to: browserProgress.fraction)
            } else if expectedPostinstallSteps > 0, line.contains(" END   step ") {
                // Postinstall step completions (the guest's "END   step …"
                // marker) advance the final weighted segment armed by
                // recordHostPhase's "Installing recommended packages (N…".
                completedPostinstallSteps += 1
                let base = postinstallBase ?? 0
                let span = max(0, 0.99 - base)
                let done = min(completedPostinstallSteps, expectedPostinstallSteps)
                bumpProgress(to: base + span * Double(done)
                                        / Double(expectedPostinstallSteps))
            }
            // Each line nudges the bar by 1/expectedTotalLines,
            // capped at progressCeiling so the final phase jump to
            // 1.0 is always visible. If real installs exceed the
            // estimate the bar simply pins at the ceiling for the
            // tail.
            let frac = Double(linesSeen) / Double(expectedTotalLines)
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
                Image(nsImage: { $0.size = NSSize(width: 96, height: 96); return $0 }(icon))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }
            Text("Welcome to Bromure Agentic Coding")
                .font(.title2.bold())
            Text("First-time setup downloads a prebuilt Ubuntu 24.04 image (or builds it locally when the download isn't available) and installs Node.js, Claude Code, Codex, and the terminal tooling inside an isolated VM. Only happens once per base-image version.")
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

/// Shown while `downloadBaseImage` / `createBaseImage` /
/// `applyPostinstallSteps` is running. Spinner + latest status +
/// collapsible console log of every progress message.
struct InitializingView: View {
    let model: InitProgressModel
    var title: String = NSLocalizedString("Building base image", comment: "Setup progress window title")
    var subtitle: String = NSLocalizedString("This is the one-time install. Don't close the window.", comment: "Setup progress window subtitle")
    let onCancel: () -> Void

    /// Console pane is collapsed by default — the determinate progress
    /// bar is enough for the common case. Power users can expand the
    /// disclosure arrow to watch the firehose.
    @State private var consoleExpanded: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: { $0.size = NSSize(width: 36, height: 36); return $0 }(icon))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
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
                        Text(model.consoleLog.isEmpty ? NSLocalizedString("(waiting for installer output…)", comment: "Placeholder in the setup console pane before any installer output arrives") : model.consoleLog)
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
