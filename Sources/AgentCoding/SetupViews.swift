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
    /// Rolling buffer of the installer's serial output. Capped so a
    /// long apt/debootstrap run (which can emit hundreds of KB) doesn't
    /// pin SwiftUI on Text-reflow.
    var consoleLog: String = ""
    var error: String?
    var isRunning: Bool = false

    /// Soft cap on `consoleLog`: when the buffer exceeds `maxBytes`,
    /// drop the front to bring it back to `keepBytes`. Tuned so the user
    /// always sees the tail of the log (including the SANDBOX_SETUP_DONE
    /// marker or whatever errored out).
    private let maxBytes = 120_000
    private let keepBytes = 80_000

    func appendLog(_ chunk: String) {
        consoleLog += chunk
        if consoleLog.utf8.count > maxBytes {
            consoleLog = "[…earlier output trimmed…]\n"
                + String(consoleLog.suffix(keepBytes))
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
            Text("First-time setup downloads Ubuntu Server and installs Node.js, Claude Code, Codex, kitty, and the desktop chrome inside an isolated VM. Takes about 10 minutes; only happens once per base-image version.")
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

    /// Console pane is expanded by default (the user explicitly asked
    /// to see installer output) but the user can collapse it via the
    /// disclosure arrow if they want a smaller window.
    @State private var consoleExpanded: Bool = true

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

            HStack(spacing: 10) {
                if model.error == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                Text(model.error ?? model.status)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
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

            HStack {
                Spacer()
                if model.error != nil {
                    Button("Close", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text("Tip: keep an eye on the console for `apt`, `npm`, and `cargo` activity.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
