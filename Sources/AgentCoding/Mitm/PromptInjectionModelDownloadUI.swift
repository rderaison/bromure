import AppKit
import Foundation

/// Confirm-then-download UX for a prompt-injection detector model, shown when
/// the user enables a detector in the profile editor. First a confirmation
/// alert that states the on-disk cost, then a determinate progress panel.
/// Kept out of `PromptInjectionModels` so the model/IO logic stays UI-free.
///
/// `onFinish(true)` = installed (or already present); `onFinish(false)` =
/// the user declined or the download failed/cancelled — the caller uses that
/// to revert the toggle, since a detector without its model is a no-op.
@MainActor
final class PromptInjectionModelDownloader: NSObject {

    /// Thread-safe fraction (0…1) the background download writes and the
    /// main-thread poll timer reads. Avoids capturing this @MainActor object
    /// in the @Sendable progress closure.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Double = 0
        func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
        var value: Double { lock.lock(); defer { lock.unlock() }; return v }
    }

    // Keep controllers alive for the duration of the async download.
    private static var active: Set<PromptInjectionModelDownloader> = []

    private let kind: PromptInjectionModels.Kind
    private let onFinish: (Bool) -> Void
    private let box = ProgressBox()
    private var window: NSWindow?
    private var bar: NSProgressIndicator?
    private var pct: NSTextField?
    private var poll: Timer?
    private var task: Task<Void, Never>?

    private init(kind: PromptInjectionModels.Kind, onFinish: @escaping (Bool) -> Void) {
        self.kind = kind
        self.onFinish = onFinish
    }

    /// Entry point. No-op + `onFinish(true)` if the model is already installed
    /// or a download is already running. Otherwise confirm, then download.
    static func start(_ kind: PromptInjectionModels.Kind,
                      onFinish: @escaping (Bool) -> Void = { _ in }) {
        if PromptInjectionModels.isInstalled(kind) { onFinish(true); return }
        if PromptInjectionModels.isDownloading(kind) { onFinish(true); return }
        let c = PromptInjectionModelDownloader(kind: kind, onFinish: onFinish)
        active.insert(c)
        // Defer past the current SwiftUI update before showing modal UI.
        DispatchQueue.main.async { c.confirm() }
    }

    private func confirm() {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString(
            "Download the %@ detector model?", comment: "confirm model download"),
            kind.detectorName)
        alert.informativeText = String(format: NSLocalizedString(
            "This downloads about %@ from bromure.io and uses roughly that much disk space. The detector starts working once the download finishes.",
            comment: "model download size warning"), kind.approxSizeString)
        alert.addButton(withTitle: NSLocalizedString("Download", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else {
            finish(success: false); return
        }
        // Preflight disk space before committing, so the user is warned up front
        // rather than watching the progress panel appear and immediately fail.
        if let err = PromptInjectionModels.diskSpaceError(for: kind) {
            finish(success: false, error: err); return
        }
        guard PromptInjectionModels.claimInFlight(kind) else {
            // Something else started it between our checks.
            finish(success: true); return
        }
        showProgressPanel()
        let box = self.box
        let kind = self.kind
        task = Task { @MainActor in
            defer { PromptInjectionModels.releaseInFlight(kind) }
            do {
                try await PromptInjectionModels.download(kind) { frac in box.set(frac) }
                finish(success: true)
            } catch is CancellationError {
                finish(success: false)
            } catch let e as URLError where e.code == .cancelled {
                finish(success: false)
            } catch {
                finish(success: false, error: error)
            }
        }
    }

    private func showProgressPanel() {
        let title = NSTextField(labelWithString: String(format: NSLocalizedString(
            "Downloading the %@ model…", comment: ""), kind.detectorName))
        title.font = .systemFont(ofSize: 12)

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let pct = NSTextField(labelWithString: "0%")
        pct.font = .systemFont(ofSize: 11)
        pct.textColor = .secondaryLabelColor

        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""),
                              target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [title, bar, pct, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = NSLocalizedString("Downloading model", comment: "")
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.center()
        w.makeKeyAndOrderFront(nil)

        self.window = w; self.bar = bar; self.pct = pct

        // Poll the thread-safe box ~10×/s and reflect it on the bar. Added in
        // .common mode so it keeps ticking while the user interacts with the
        // window. (Unscheduled Timer + a single add — never add a timer twice.)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.poll = timer
    }

    private func tick() {
        let v = box.value
        bar?.doubleValue = v
        pct?.stringValue = "\(Int(v * 100))%"
    }

    @objc private func cancelTapped() {
        task?.cancel()
    }

    private func finish(success: Bool, error: Error? = nil) {
        poll?.invalidate(); poll = nil
        window?.orderOut(nil); window = nil
        if let error {
            let a = NSAlert()
            a.messageText = NSLocalizedString("Couldn't download the detector model", comment: "")
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            a.runModal()
        }
        onFinish(success)
        Self.active.remove(self)
    }
}
