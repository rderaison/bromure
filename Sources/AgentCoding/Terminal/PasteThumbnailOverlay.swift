import AppKit

/// Transient thumbnail chip floated over a `TerminalSurfaceView` during an
/// image paste: the human sees *what* was pasted while the terminal only
/// ever receives the guest file path. Purely host-side chrome — nothing of
/// it travels down the pty.
///
/// Lifecycle: `present` (fade in, accent progress line while the upload
/// runs) → `markDone` (line gone, lingers a few seconds) or `markFailed`
/// (red line, shorter linger) → fade out. A keystroke after the transfer
/// finished dismisses it early; during the transfer it stays — it's the
/// only feedback that the upload is still running. Hit-testing is disabled
/// so the chip never eats terminal input.
final class PasteThumbnailOverlay: NSView {

    private enum Phase { case uploading, done, failed }
    private var phase: Phase = .uploading

    private let imageView = NSImageView()
    private let progressLine = NSView()
    private var fadeWork: DispatchWorkItem?

    private static let thumbMax = NSSize(width: 160, height: 100)
    private static let inset: CGFloat = 4
    private static let lineHeight: CGFloat = 3

    // MARK: Presentation

    /// Show a chip for `sources` anchored at `view`'s caret (where the
    /// guest path is about to appear). Returns nil when nothing decodes
    /// as an image — the paste itself proceeds either way.
    @discardableResult
    static func present(over view: TerminalSurfaceView,
                        sources: [TerminalImagePaste.Source]) -> PasteThumbnailOverlay? {
        guard let image = firstImage(of: sources) else { return nil }
        // A newer paste replaces a lingering chip outright.
        view.pasteThumbnail?.removeFromSuperview()

        let overlay = PasteThumbnailOverlay(image: image, extraCount: sources.count - 1)
        // Degenerate fallback (no window yet): bottom-left corner.
        let caret = view.caretRect ?? NSRect(x: 8, y: 8, width: 8, height: 16)
        overlay.setFrameOrigin(chipFrame(chipSize: overlay.frame.size,
                                         caret: caret,
                                         bounds: view.bounds).origin)
        overlay.alphaValue = 0
        view.addSubview(overlay)
        view.pasteThumbnail = overlay
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 1
        }
        return overlay
    }

    private init(image: NSImage, extraCount: Int) {
        let thumb = Self.fitSize(image.size, within: Self.thumbMax)
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: thumb.width + Self.inset * 2,
                                 height: thumb.height + Self.inset * 2))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        imageView.frame = NSRect(x: Self.inset, y: Self.inset,
                                 width: thumb.width, height: thumb.height)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)

        if extraCount > 0 { addBadge("+\(extraCount)") }

        progressLine.wantsLayer = true
        progressLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressLine.frame = NSRect(x: 0, y: 0, width: 0, height: Self.lineHeight)
        addSubview(progressLine)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The chip never eats terminal input (clicks fall through to the
    /// surface underneath).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// "+2" pill for multi-file pastes (only the first image is shown).
    private func addBadge(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let pad: CGFloat = 4
        let size = NSSize(width: label.frame.width + pad * 2,
                          height: label.frame.height + 2)
        let badge = NSView(frame: NSRect(x: bounds.maxX - size.width - 6, y: 6,
                                         width: size.width, height: size.height))
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = size.height / 2
        label.setFrameOrigin(NSPoint(x: pad, y: 1))
        badge.addSubview(label)
        addSubview(badge)
    }

    // MARK: State

    func setProgress(_ fraction: Double) {
        guard phase == .uploading else { return }
        progressLine.frame.size.width = bounds.width * CGFloat(max(0, min(1, fraction)))
    }

    func markDone() {
        guard phase == .uploading else { return }
        phase = .done
        progressLine.isHidden = true
        scheduleFade(after: 4)
    }

    func markFailed() {
        guard phase == .uploading else { return }
        phase = .failed
        progressLine.layer?.backgroundColor = NSColor.systemRed.cgColor
        progressLine.frame.size.width = bounds.width
        scheduleFade(after: 2)
    }

    /// Typing after the transfer finished → get out of the way. During
    /// the upload the chip stays put (it's the transfer feedback).
    func keystrokeDismiss() {
        guard phase != .uploading else { return }
        scheduleFade(after: 0)
    }

    private func scheduleFade(after delay: TimeInterval) {
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.removeFromSuperview()
        }
    }

    // MARK: Geometry (pure, tested)

    /// Aspect-fit `image` into `limit`, never upscaling, with a floor so a
    /// tiny bitmap still yields a visible chip (the image view centers
    /// proportionally inside).
    static func fitSize(_ image: NSSize, within limit: NSSize) -> NSSize {
        guard image.width > 0, image.height > 0 else {
            return NSSize(width: 48, height: 36)
        }
        let scale = min(limit.width / image.width, limit.height / image.height, 1)
        return NSSize(width: max(image.width * scale, 32).rounded(),
                      height: max(image.height * scale, 24).rounded())
    }

    /// Chip placement: just above the caret line, flipped below it when
    /// that would clip at the top, clamped inside `bounds` either way.
    /// Coordinates are bottom-left origin (the surface view is unflipped).
    static func chipFrame(chipSize: NSSize, caret: NSRect, bounds: NSRect) -> NSRect {
        let gap: CGFloat = 6
        let margin: CGFloat = 4
        var origin = NSPoint(x: caret.minX, y: caret.maxY + gap)
        if origin.y + chipSize.height + margin > bounds.maxY {
            origin.y = caret.minY - gap - chipSize.height
        }
        origin.x = min(max(bounds.minX + margin, origin.x),
                       max(bounds.minX + margin, bounds.maxX - chipSize.width - margin))
        origin.y = min(max(bounds.minY + margin, origin.y),
                       max(bounds.minY + margin, bounds.maxY - chipSize.height - margin))
        return NSRect(origin: origin, size: chipSize)
    }

    /// First decodable image among the paste sources (decode failures fall
    /// through — a broken thumbnail must not block the chip for the rest).
    static func firstImage(of sources: [TerminalImagePaste.Source]) -> NSImage? {
        for source in sources {
            switch source {
            case .bitmap(let data, _):
                if let image = NSImage(data: data) { return image }
            case .file(let url, _):
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }
}
