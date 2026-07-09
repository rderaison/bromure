import AppKit
import Foundation

/// Downloads the prompt-injection detector models that ship with Bromure by
/// default, with a visible, non-blocking progress panel — so the ~900 MB
/// first-run fetch reads as "something is happening" rather than a silent
/// background stall. Unlike `PromptInjectionModelDownloader` (the editor's
/// confirm-then-download flow), this asks for no confirmation: the models are
/// part of the default install, already consented to at setup.
///
/// Idempotent and deduped against every other download path via
/// `PromptInjectionModels.claimInFlight`, so calling it at each launch simply
/// heals a missing or interrupted install.
@MainActor
final class DefaultModelDownloader: NSObject {
    static let shared = DefaultModelDownloader()

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0.0
        func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
        var value: Double { lock.lock(); defer { lock.unlock() }; return v }
    }

    private struct Row {
        let bar: NSProgressIndicator
        let pct: NSTextField
        let box: ProgressBox
    }

    private var window: NSWindow?
    private var rows: [PromptInjectionModels.Kind: Row] = [:]
    private var poll: Timer?
    private var remaining = 0

    private override init() {}

    /// Fetch any missing default models. Headless agents skip the panel and
    /// fall back to the silent background fetch (no GUI to show it in).
    func ensureModels(headless: Bool) {
        let missing = PromptInjectionModels.Kind.allCases.filter {
            !PromptInjectionModels.isInstalled($0) && !PromptInjectionModels.isDownloading($0)
        }
        guard !missing.isEmpty else { return }

        if headless {
            for kind in missing { PromptInjectionModels.ensureInstalledInBackground(kind) }
            return
        }

        // Claim the slots up front so a concurrent path (editor toggle, a
        // second launch tick) doesn't double-download the same model.
        let claimed = missing.filter { PromptInjectionModels.claimInFlight($0) }
        guard !claimed.isEmpty else { return }

        SupplyChainLog.shared.record(
            "[prompt-injection] downloading default models: "
            + claimed.map(\.dirName).joined(separator: ", "))
        if window == nil { buildPanel() }
        for kind in claimed { addRow(for: kind) }
        remaining += claimed.count
        window?.makeKeyAndOrderFront(nil)
        startPoll()

        for kind in claimed { download(kind) }
    }

    // MARK: Download

    private func download(_ kind: PromptInjectionModels.Kind) {
        guard let box = rows[kind]?.box else { return }
        Task { @MainActor in
            defer { PromptInjectionModels.releaseInFlight(kind) }
            do {
                try await PromptInjectionModels.download(kind) { frac in box.set(frac) }
                box.set(1.0)
                markDone(kind, failed: false)
            } catch {
                SupplyChainLog.shared.record(
                    "[prompt-injection] \(kind.dirName) default download failed: \(error.localizedDescription)")
                markDone(kind, failed: true, message: error.localizedDescription)
            }
        }
    }

    private func markDone(_ kind: PromptInjectionModels.Kind, failed: Bool,
                          message: String? = nil) {
        if failed, let row = rows[kind] {
            row.pct.stringValue = "Failed"
            row.pct.textColor = .systemRed
            if let message { row.pct.toolTip = message }
        }
        remaining -= 1
        guard remaining <= 0 else { return }
        // All settled — let the last bar paint, then dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.dismiss()
        }
    }

    private func dismiss() {
        poll?.invalidate(); poll = nil
        window?.orderOut(nil)
        window = nil
        rows.removeAll()
    }

    // MARK: Panel

    private func buildPanel() {
        let title = NSTextField(labelWithString: NSLocalizedString(
            "Downloading security models", comment: "model download panel title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let subtitle = NSTextField(labelWithString: NSLocalizedString(
            "Bromure's prompt-injection detectors. This runs once in the background.",
            comment: ""))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 12
        rowsStack.setHuggingPriority(.defaultLow, for: .horizontal)
        rowsStack.identifier = Self.rowsStackID

        let outer = NSStackView(views: [title, subtitle, rowsStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = NSLocalizedString("Security models", comment: "")
        w.isReleasedWhenClosed = false
        w.contentView = outer
        // Bottom-right, out of the way of the main window.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.maxX - 460, y: f.minY + 40))
        } else {
            w.center()
        }
        window = w
    }

    private static let rowsStackID = NSUserInterfaceItemIdentifier("io.bromure.modeldl.rows")

    private func addRow(for kind: PromptInjectionModels.Kind) {
        guard rows[kind] == nil,
              let rowsStack = window?.contentView?.firstDescendant(id: Self.rowsStackID)
                as? NSStackView else { return }

        let name = NSTextField(labelWithString: String(format: NSLocalizedString(
            "%@ · %@", comment: "model name · size"),
            kind.detectorName, kind.approxSizeString))
        name.font = .systemFont(ofSize: 11)

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let pct = NSTextField(labelWithString: "0%")
        pct.font = .systemFont(ofSize: 11)
        pct.textColor = .secondaryLabelColor

        let barRow = NSStackView(views: [bar, pct])
        barRow.orientation = .horizontal
        barRow.spacing = 8

        let row = NSStackView(views: [name, barRow])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        rowsStack.addArrangedSubview(row)

        rows[kind] = Row(bar: bar, pct: pct, box: ProgressBox())
    }

    private func startPoll() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func tick() {
        for row in rows.values {
            let v = row.box.value
            row.bar.doubleValue = v
            // Don't clobber a "Failed" label.
            if row.pct.textColor != .systemRed {
                row.pct.stringValue = "\(Int(v * 100))%"
            }
        }
    }
}

private extension NSView {
    /// First descendant (depth-first) whose identifier matches.
    func firstDescendant(id: NSUserInterfaceItemIdentifier) -> NSView? {
        for sub in subviews {
            if sub.identifier == id { return sub }
            if let found = sub.firstDescendant(id: id) { return found }
        }
        return nil
    }
}
