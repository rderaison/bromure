import AppKit
import SwiftUI

/// Safari-style tab tear-off for the compact tab bar: press a tab pill,
/// drag it out of the bar and release to move that tab into a new window.
/// The bar itself is unchanged; a dragged-out tab only dims its pill and
/// shows a page thumbnail under the pointer until it is released.
@MainActor
final class TabTearOff {
    enum Outcome {
        /// The press ended without a tear-off; replay this mouse-up to
        /// deliver the click the press would otherwise have been.
        case click(NSEvent)
        /// The press was consumed (a tear-off, or a cancelled drag).
        case handled
    }

    /// How far the pointer may move before a press stops being a click.
    private static let slop: CGFloat = 4
    /// How far above or below the bar the pointer must go to tear off.
    private static let tearDistance: CGFloat = 24

    private var panel: NSPanel?

    /// Tracks one press on `view` (a pill, or the active tab's address
    /// field) until mouse-up or Escape. Runs its own event loop, like
    /// AppKit's control tracking, so the press can never turn into a
    /// window drag.
    func track(_ down: NSEvent, tabID: String, model: NativeTabBarModel, in view: NSView) -> Outcome {
        guard let window = view.window else { return .handled }
        let start = window.convertPoint(toScreen: down.locationInWindow)
        // The bar's row, across the whole window. Leaving it tears the tab off.
        let row = window.convertToScreen(view.convert(view.bounds, to: nil))
        let band = NSRect(x: window.frame.minX, y: row.minY - Self.tearDistance,
                          width: window.frame.width, height: row.height + 2 * Self.tearDistance)
        var moved = false
        var torn = false
        defer {
            model.tearingTabID = nil
            hidePanel()
        }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            let point = window.convertPoint(toScreen: event.locationInWindow)
            switch event.type {
            case .keyDown:
                // Escape cancels a drag; other keys are ignored while the
                // mouse is down, as in any AppKit tracking loop.
                if event.keyCode == 53 { drainMouseUp(window); return .handled }
            case .leftMouseDragged:
                if !moved, hypot(point.x - start.x, point.y - start.y) < Self.slop { continue }
                moved = true
                // A tab can leave only if another stays behind.
                let canTear = model.liquidTabsEnabled && model.onDetach != nil && model.tabs.count > 1
                    && model.tabs.contains { $0.id == tabID }
                let outside = canTear && !band.contains(point)
                if outside && !torn {
                    torn = true
                    model.tearingTabID = tabID
                    showPanel(model: model, tabID: tabID, appearance: window.effectiveAppearance)
                } else if !outside && torn {
                    torn = false
                    model.tearingTabID = nil
                    hidePanel()
                }
                if torn { movePanel(to: point) }
            case .leftMouseUp:
                if torn {
                    model.onDetach?(tabID, point)
                    return .handled
                }
                return .click(event)
            default:
                break
            }
        }
        return .handled
    }

    /// After Escape, swallow the rest of the press so the release that
    /// eventually comes is not delivered as a click.
    private func drainMouseUp(_ window: NSWindow) {
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              event.type != .leftMouseUp {}
    }

    // MARK: Drag preview

    private func showPanel(model: NativeTabBarModel, tabID: String, appearance: NSAppearance) {
        let image = model.tabs.first(where: { $0.active })?.id == tabID ? model.dragPreview?() : nil
        let content: NSView
        let size: NSSize
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(240 / image.size.width, 180 / image.size.height)
            size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            content = imageView
        } else {
            // Background tabs have no frame to show (only the active tab is
            // on screen); show the tab's title instead.
            let tab = model.tabs.first { $0.id == tabID }
            let title = (tab?.title.isEmpty ?? true) ? (tab?.url ?? "") : tab!.title
            let label = NSTextField(labelWithString: NativeTabBarModel.isNewTabURL(tab?.url ?? "")
                                    ? String(localized: "New Tab") : title)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            size = NSSize(width: 200, height: 32)
            let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            box.material = .popover
            box.state = .active
            label.frame = NSRect(x: 10, y: 8, width: size.width - 20, height: 16)
            box.addSubview(label)
            content = box
        }
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.appearance = appearance
        panel.alphaValue = 0.92
        panel.contentView = content
        self.panel = panel
    }

    private func movePanel(to point: NSPoint) {
        guard let panel else { return }
        // Pointer at the top centre of the thumbnail, as when holding a tab.
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height + 8))
        panel.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Covers an inactive tab pill when tear-off is on: a click activates the
/// tab, a drag out of the bar tears it off.
struct TabDragHandle: NSViewRepresentable {
    let model: NativeTabBarModel
    let tabID: String

    func makeNSView(context: Context) -> TabDragHandleView {
        let view = TabDragHandleView()
        view.model = model
        view.tabID = tabID
        return view
    }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.model = model
        view.tabID = tabID
    }
}

final class TabDragHandleView: NSView {
    weak var model: NativeTabBarModel?
    var tabID = ""

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        if case .click = model.tearOff.track(event, tabID: tabID, model: model, in: self) {
            model.onActivate?(tabID)
        }
    }
}
