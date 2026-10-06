import AppKit

/// A caption card anchored below a tab. It never takes focus or mouse events.
@MainActor
final class CompactTabHoverPreview {
    private weak var cell: CompactTabCell?
    private var timer: Timer?
    private var panel: NSPanel?
    private var restingPoint = NSPoint.zero
    private var restingSince: TimeInterval = 0
    private var renderedContent: CompactTabHoverContent?
    private var renderedFrame = NSRect.zero
    private var renderedConfiguration: CompactTabHoverConfiguration?
    var visiblePanel: NSPanel? { panel?.isVisible == true ? panel : nil }

    func begin(over cell: CompactTabCell) {
        guard self.cell !== cell else { return }
        dismiss()
        self.cell = cell
        restingPoint = NSEvent.mouseLocation
        restingSince = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func leave(_ cell: CompactTabCell) { if self.cell === cell { dismiss() } }
    func refresh(_ cell: CompactTabCell) { if self.cell === cell { update() } }
    func dismiss() {
        timer?.invalidate(); timer = nil
        hide(); cell = nil
    }
    private func hide() {
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        renderedContent = nil
    }

    private func update() {
        guard let cell, let owner = cell.owner, let configuration = owner.hoverPreview,
              let window = cell.window, window.isVisible, window.isKeyWindow,
              !cell.isHiddenOrHasHiddenAncestor, !cell.isEditingAddress,
              !owner.isDragging, NSEvent.pressedMouseButtons == 0 else { dismiss(); return }
        let point = NSEvent.mouseLocation
        let local = cell.convert(window.convertPoint(fromScreen: point), from: nil)
        guard cell.bounds.intersection(cell.visibleRect).contains(local) else { dismiss(); return }
        var hit = cell.hitTest(local)
        while let view = hit, view !== cell {
            if view is NSButton {
                restingPoint = point; restingSince = ProcessInfo.processInfo.systemUptime
                hide(); return
            }
            hit = view.superview
        }
        let now = ProcessInfo.processInfo.systemUptime
        if hypot(point.x - restingPoint.x, point.y - restingPoint.y) > 2 {
            restingPoint = point; restingSince = now; hide()
        }
        let delay = configuration.delay.isFinite ? max(0, configuration.delay) : 0.65
        guard now - restingSince >= delay else { return }
        let content = cell.item.hoverContent ?? CompactTabHoverContent(title: cell.item.title,
            subtitle: cell.item.address.isEmpty || cell.item.address == cell.item.title ? nil : cell.item.address)
        let anchor = window.convertToScreen(cell.convert(cell.bounds, to: nil))
        guard renderedContent != content || renderedFrame != anchor || renderedConfiguration != configuration else { return }
        show(content, below: anchor, in: window, appearance: cell.effectiveAppearance, configuration: configuration)
        renderedContent = content; renderedFrame = anchor; renderedConfiguration = configuration
    }

    private func show(_ content: CompactTabHoverContent, below anchor: NSRect, in window: NSWindow,
                      appearance: NSAppearance, configuration: CompactTabHoverConfiguration) {
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = appearance

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let requestedWidth = configuration.maximumWidth.isFinite ? configuration.maximumWidth : 280
        let width = min(max(140, requestedWidth), max(140, visible.width - 16))
        let background = NSVisualEffectView()
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true; background.layer?.borderWidth = 1
        appearance.performAsCurrentDrawingAppearance {
            background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        func addText(_ text: String, font: NSFont, color: NSColor) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font; label.textColor = color; label.preferredMaxLayoutWidth = width - 30
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: width - 30).isActive = true
        }
        addText(content.title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        if let subtitle = content.subtitle, !subtitle.isEmpty {
            addText(subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        if let detail = content.detail, !detail.isEmpty {
            addText(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10)
        ])
        let height = min(max(36, ceil(background.fittingSize.height)), max(36, visible.height - 16))
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - width - 8)
        let below = anchor.minY - 8 - height
        let y = below >= visible.minY + 8 ? below : min(anchor.maxY + 8, visible.maxY - height - 8)
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = background
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}
