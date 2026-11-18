#if os(macOS)
import AppKit
import SwiftUI

/// "Starting a sign-in machine…" on the window a remote sign-in was started
/// from: the remote boots a throwaway machine and the agent's login starts in
/// it before the page can open here -- half a minute, which otherwise looked
/// like nothing happening. Closed when the page opens in this Mac's browser,
/// when the run ends, or by the user (the sign-in goes on).
@MainActor
final class RemoteSignInProgress {
    private let panel: NSPanel
    private(set) var isClosed = false

    private init(panel: NSPanel) { self.panel = panel }

    static func show(provider: String, host: String, on window: NSWindow) -> RemoteSignInProgress {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let progress = RemoteSignInProgress(panel: panel)
        panel.contentViewController = NSHostingController(rootView: RemoteSignInProgressView(
            provider: provider, host: host, onHide: { [weak progress] in progress?.close() }))
        window.beginSheet(panel)
        return progress
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }
}

struct RemoteSignInProgressView: View {
    let provider: String
    let host: String
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(String(format: NSLocalizedString("Signing in to %@…", comment: "remote sign-in progress title; %@ = provider"), provider))
                    .font(.headline)
            }
            Text(String(format: NSLocalizedString(
                "Starting a private sign-in machine on %@. The sign-in page opens in your browser when it's ready, usually within a minute.",
                comment: "remote sign-in progress; %@ = the remote Mac's name"), host))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(NSLocalizedString("Hide", comment: "remote sign-in progress: dismiss, the sign-in goes on"), action: onHide)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
#endif
