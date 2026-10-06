import AppKit

/// A full-size content view can receive tab events while WindowServer also
/// drags its native title bar. Own that decision before the mouse-down: native
/// dragging stays disabled, and only an unprotected background press is handed
/// back to WindowServer with performDrag(with:).
@MainActor
final class TabStripWindowDragGuard {
    private final class WeakStrip {
        weak var view: CompactTabStripView?
        init(_ view: CompactTabStripView) { self.view = view }
    }
    private static var windows: [ObjectIdentifier: TabStripWindowDragGuard] = [:]
    private weak var window: NSWindow?
    private let windowID: ObjectIdentifier
    private let wasMovable: Bool
    private var strips: [ObjectIdentifier: WeakStrip] = [:]
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    static func attach(_ strip: CompactTabStripView, to window: NSWindow) -> TabStripWindowDragGuard {
        let id = ObjectIdentifier(window)
        let guardOwner: TabStripWindowDragGuard
        if let existing = windows[id], existing.window === window { guardOwner = existing }
        else { guardOwner = TabStripWindowDragGuard(window: window) }
        windows[id] = guardOwner
        guardOwner.strips[ObjectIdentifier(strip)] = WeakStrip(strip)
        window.isMovable = false
        return guardOwner
    }

    private init(window: NSWindow) {
        self.window = window
        windowID = ObjectIdentifier(window)
        wasMovable = window.isMovable
        window.isMovable = false
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, self.allowsWindowDrag(event) else { return event }
            window.performDrag(with: event)
            return nil
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // SwiftUI may finish configuring its window after attaching
                    // the representable. The strip owns movability until removal.
                    guard let window = self?.window, window.isMovable else { return }
                    window.isMovable = false
                }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.constrainAfterScreenChange() }
            })
    }

    private func constrainAfterScreenChange() {
        // isMovable=false also disables automatic display-reconfiguration moves.
        // Preserve the host's normal visibility policy through AppKit's constraint.
        guard wasMovable, let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let overlapping = NSScreen.screens.max { first, second in
            let a = first.frame.intersection(window.frame), b = second.frame.intersection(window.frame)
            return a.width * a.height < b.width * b.height
        }
        guard let screen = overlapping.flatMap({ $0.frame.intersects(window.frame) ? $0 : nil }) ?? NSScreen.main else { return }
        let constrained = window.constrainFrameRect(window.frame, to: screen)
        if constrained != window.frame { window.setFrame(constrained, display: true) }
    }

    func detach(_ strip: CompactTabStripView) {
        detach(ObjectIdentifier(strip))
    }

    func detach(_ stripID: ObjectIdentifier) {
        strips.removeValue(forKey: stripID)
        strips = strips.filter { $0.value.view != nil }
        if strips.isEmpty { stop() }
    }

    func allowsWindowDrag(_ event: NSEvent) -> Bool {
        guard wasMovable, let window, event.window === window, event.type == .leftMouseDown else { return false }
        let point = event.locationInWindow
        // Protect the whole strip, including a single tab, gaps, unused track
        // and the add button. Controls and tab drag tracking receive normal events.
        for weakStrip in strips.values {
            guard let strip = weakStrip.view, strip.window === window,
                  !strip.isHiddenOrHasHiddenAncestor else { continue }
            if strip.bounds.intersection(strip.visibleRect).contains(strip.convert(point, from: nil)) { return false }
        }
        let inTitlebar = point.y >= window.contentLayoutRect.maxY
        guard inTitlebar || window.isMovableByWindowBackground else { return false }
        // Leave the native resize borders and title-bar controls to AppKit.
        if window.styleMask.contains(.resizable),
           point.x < 4 || point.x > window.frame.width - 4 || point.y > window.frame.height - 4 { return false }
        guard let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(point, from: nil)),
              hit.mouseDownCanMoveWindow else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSControl || current is NSTextView { return false }
            view = current.superview
        }
        return true
    }

    private func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window?.isMovable = wasMovable
        if Self.windows[windowID] === self { Self.windows.removeValue(forKey: windowID) }
        strips.removeAll()
    }
}
