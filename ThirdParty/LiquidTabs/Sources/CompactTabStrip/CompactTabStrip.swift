import AppKit
import SwiftUI
import CoreImage

public struct CompactTabItem: Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var address: String
    public var searchPrompt: String
    public var symbol: String
    public var faviconLetter: String?
    public var iconImage: NSImage?
    public var isBusy: Bool
    public var isTrusted: Bool
    public var isPinned: Bool
    public var hoverContent: CompactTabHoverContent?

    public init(
        id: UUID = UUID(),
        title: String,
        address: String = "",
        searchPrompt: String = "Search sessions or commands",
        symbol: String = "doc.text",
        faviconLetter: String? = nil,
        iconImage: NSImage? = nil,
        isBusy: Bool = false,
        isTrusted: Bool = false,
        isPinned: Bool = false,
        hoverContent: CompactTabHoverContent? = nil
    ) {
        self.id = id
        self.title = title
        self.address = address
        self.searchPrompt = searchPrompt
        self.symbol = symbol
        self.faviconLetter = faviconLetter
        self.iconImage = iconImage
        self.isBusy = isBusy
        self.isTrusted = isTrusted
        self.isPinned = isPinned
        self.hoverContent = hoverContent
    }
}

public struct CompactTabStrip: NSViewRepresentable {
    public var items: [CompactTabItem]
    public var selection: UUID
    public var onSelect: (UUID) -> Void
    public var onClose: (UUID) -> Void
    public var onInsert: () -> Void
    public var onMove: (UUID, Int) -> Void
    public var onDetach: (UUID, NSPoint) -> Void
    public var onSearch: (String) -> Void
    public var onReload: () -> Void
    public var onSetPinned: (UUID, Bool) -> Void
    public var allowsPinning: Bool
    public var labelMode: CompactTabLabelMode
    public var hoverPreview: CompactTabHoverConfiguration?
    public var previewImage: (() -> NSImage?)?
    public var previewSourceView: NSView?
    public var transferOwner: AnyObject?
    public var onTransfer: (UUID, AnyObject, Int) -> Bool

    public init(
        items: [CompactTabItem],
        selection: UUID,
        onSelect: @escaping (UUID) -> Void,
        onClose: @escaping (UUID) -> Void,
        onInsert: @escaping () -> Void,
        onMove: @escaping (UUID, Int) -> Void,
        onDetach: @escaping (UUID, NSPoint) -> Void,
        onSearch: @escaping (String) -> Void = { _ in },
        onReload: @escaping () -> Void = {},
        onSetPinned: @escaping (UUID, Bool) -> Void = { _, _ in },
        allowsPinning: Bool = true,
        labelMode: CompactTabLabelMode = .fixed,
        hoverPreview: CompactTabHoverConfiguration? = .init(),
        previewSourceView: NSView? = nil,
        previewImage: (() -> NSImage?)? = nil,
        transferOwner: AnyObject? = nil,
        onTransfer: @escaping (UUID, AnyObject, Int) -> Bool = { _, _, _ in false }
    ) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
        self.onClose = onClose
        self.onInsert = onInsert
        self.onMove = onMove
        self.onDetach = onDetach
        self.onSearch = onSearch
        self.onReload = onReload
        self.onSetPinned = onSetPinned
        self.allowsPinning = allowsPinning
        self.labelMode = labelMode
        self.hoverPreview = hoverPreview
        self.previewImage = previewImage
        self.previewSourceView = previewSourceView
        self.transferOwner = transferOwner
        self.onTransfer = onTransfer
    }

    public func makeNSView(context: Context) -> NSView { CompactTabStripView() }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: 36)
    }
    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CompactTabStripView else { return }
        view.onSelect = onSelect; view.onClose = onClose; view.onInsert = onInsert
        view.onMove = onMove; view.onDetach = onDetach; view.onSearch = onSearch; view.onReload = onReload
        view.onSetPinned = onSetPinned
        view.allowsPinning = allowsPinning
        view.labelMode = labelMode
        view.hoverPreview = hoverPreview
        view.previewImage = previewImage
        view.previewSourceView = previewSourceView
        view.transferOwner = transferOwner
        view.onTransfer = { [onTransfer] id, strip, slot in onTransfer(id, strip, slot) }
        view.configure(items: items, selection: selection)
    }
}

/// AppKit owns pointer tracking; model order changes only after a validated drop.
final class CompactTabStripView: NSView {
    var items: [CompactTabItem] = []
    var selection = UUID()
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onInsert: () -> Void = {}
    var onMove: (UUID, Int) -> Void = { _, _ in }
    var onDetach: (UUID, NSPoint) -> Void = { _, _ in }
    var onSearch: (String) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onSetPinned: (UUID, Bool) -> Void = { _, _ in }
    var allowsPinning = true
    var labelMode: CompactTabLabelMode = .fixed {
        didSet {
            guard oldValue != labelMode else { return }
            hoverPreviewController?.dismiss()
            clearDrag()
            configure(items: items, selection: selection)
        }
    }
    var hoverPreview: CompactTabHoverConfiguration? = .init() {
        didSet { if oldValue != hoverPreview { hoverPreviewController?.dismiss() } }
    }
    private var hoverPreviewController: CompactTabHoverPreview?
    var visibleHoverPreview: NSPanel? { hoverPreviewController?.visiblePanel }
    func beginHoverPreview(over cell: CompactTabCell) {
        guard hoverPreview != nil else { return }
        if hoverPreviewController == nil { hoverPreviewController = CompactTabHoverPreview() }
        hoverPreviewController?.begin(over: cell)
    }
    func endHoverPreview(over cell: CompactTabCell) { hoverPreviewController?.leave(cell) }
    func refreshHoverPreview(over cell: CompactTabCell) { hoverPreviewController?.refresh(cell) }
    weak var transferOwner: AnyObject?
    var onTransfer: (UUID, CompactTabStripView, Int) -> Bool = { _, _, _ in false }
    private let scroll = NSScrollView()
    private let document = TabStripDocumentView()
    private let pinnedHost = TabStripDocumentView()
    private var glassTrack: NSView?
    private let add = NSButton()
    private var cells: [UUID: CompactTabCell] = [:]
    private var dragPanel: NSPanel?
    private var dragID: UUID?
    private var dragOrigin: NSPoint = .zero
    private var grabOffset: NSPoint = .zero
    private var grabbedWidth: CGFloat = 0
    private var tabImage: NSImage?
    private var windowImage: NSImage?
    private var previewAnimation: Timer?
    private var liftAnimation: Timer?
    private var settlingAnimation: Timer?
    private let dragBackdrop = TabDragBackdrop()
    private var grabRecenteringBegan: TimeInterval?
    private var previewBlend: CGFloat = 0
    private var previewTarget: CGFloat = 0
    private var previewBaseline: CGFloat = 0
    private var locksDragToStrip = true
    private var hasTornOff = false
    private var lastDragPoint: NSPoint = .zero
    private var eventMonitor: Any?
    private var focusDismissMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var windowDragGuard: TabStripWindowDragGuard?
    private weak var dropTarget: CompactTabStripView?
    private var isSettling = false
    private var dragWidths: [UUID: CGFloat]?
    private var layoutWidths: [UUID: CGFloat] = [:]
    private(set) var slotFrames: [NSRect] = []
    private var trackFrame: NSRect = .zero
    private var reservedID: UUID?
    private var settlingSelectionID: UUID?
    private var reservedIsEmpty = true
    private var reservedIsPinned = false
    private var pinnedExtent: CGFloat = 0
    private var slotIDs: [UUID] = []
    private var pinnedIDs: Set<UUID> = []
    private(set) var insertionIndex: Int?
    private(set) var tabWidth: CGFloat = TabStripGeometry.maximumWidth
    private var frozenCloseWidth: CGFloat?
    private var frozenCloseWidths: [UUID: CGFloat]?
    private var frozenCloseOrigin: CGFloat?
    private var frozenCloseGap: CGFloat?
    private var frozenCloseDocumentWidth: CGFloat?
    private var pointerInside = false
    private var lastLayoutWidth: CGFloat = -1
    private var revealSelection = false
    private var animatesInsertion = false
    private var clickEditsAddress = false
    private var layoutOrigin: CGFloat = 0
    // Optional preview override for an embedded strip. Workspaces capture their
    // complete visible surface so split panes cannot produce a portrait thumbnail.
    var previewImage: (() -> NSImage?)?
    weak var previewSourceView: NSView?
    private final class WeakStrip { weak var value: CompactTabStripView?; init(_ value: CompactTabStripView) { self.value = value } }
    private static var strips: [WeakStrip] = []
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var canDragTabs: Bool { items.count > 1 }
    var isDragging: Bool { dragPanel != nil && !isSettling }
    var visibleDragPanel: NSPanel? { dragPanel }
    var viewportWidth: CGFloat { max(0, bounds.width - 30) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.horizontalScrollElasticity = .none; scroll.documentView = document
        scroll.clipsToBounds = false; scroll.contentView.clipsToBounds = false
        document.clipsToBounds = false
        if #available(macOS 26.0, *) {
            let glass = TabGlassTrack()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.contentView = NSView()
            addSubview(glass)
            glassTrack = glass
        }
        addSubview(scroll)
        // Pins stay in the leading toolbar while the ordinary tabs scroll.
        addSubview(pinnedHost)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        add.isBordered = false; add.target = self; add.action = #selector(insert)
        add.toolTip = "New Tab (⌘T)"; add.setAccessibilityLabel("New tab")
        addSubview(add)
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func insert() { releaseCloseWidths(); onInsert() }
    private func releaseCloseWidths() {
        frozenCloseWidth = nil; frozenCloseWidths = nil; frozenCloseOrigin = nil
        frozenCloseGap = nil
        frozenCloseDocumentWidth = nil
    }
    private func lockCloseWidths() {
        frozenCloseWidth = tabWidth; frozenCloseWidths = layoutWidths; frozenCloseOrigin = layoutOrigin
        let normalFrames = zip(slotIDs, slotFrames).filter { !pinnedIDs.contains($0.0) }.map(\.1)
        frozenCloseGap = normalFrames.count > 1 ? normalFrames[1].minX - normalFrames[0].maxX : 0
        // Keep the clip view's scroll offset fixed too. Shrinking an overflowing
        // document clamps that offset and moves every close target under the
        // pointer even if all individual tab widths stay frozen.
        frozenCloseDocumentWidth = document.frame.width
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverPreviewController?.dismiss()
        windowDragGuard?.detach(self)
        windowDragGuard = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let focusDismissMonitor { NSEvent.removeMonitor(focusDismissMonitor) }
        focusDismissMonitor = nil
        Self.strips.removeAll { $0.value == nil || $0.value === self }
        if let window {
            windowDragGuard = TabStripWindowDragGuard.attach(self, to: window)
            Self.strips.append(WeakStrip(self))
            // Buttons and ordinary content do not necessarily take first
            // responder. End address editing before forwarding their click so
            // focus decoration cannot remain on the selected tab afterward.
            focusDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.hoverPreviewController?.dismiss()
                self.cells[self.selection]?.dismissAddressForOutsideClick(event)
                return event
            }
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                // A window may close independently while a drop is settling.
                // Keep that panel alive until the destination handoff finishes.
                guard let self else { return }
                MainActor.assumeIsolated { self.hoverPreviewController?.dismiss() }
                guard !self.isSettling else { return }
                self.clearDrag()
            }
        } else if !isSettling { clearDrag() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true; needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false; releaseCloseWidths()
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func requestClose(_ id: UUID) {
        if items.first(where: { $0.id == id })?.isPinned == true { releaseCloseWidths() }
        else if pointerInside { lockCloseWidths() }
        onClose(id)
    }
    func requestPin(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        releaseCloseWidths()
        onSetPinned(id, !item.isPinned)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty, glassTrack != nil || items.count > 1 || reservedID != nil else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.058) : NSColor.black.withAlphaComponent(0.08)).setFill()
        let visibleTrack = trackFrame.intersection(scroll.frame)
        if !visibleTrack.isEmpty { NSBezierPath(roundedRect: visibleTrack, xRadius: 18, yRadius: 18).fill() }
        for (index, id) in slotIDs.enumerated() where pinnedIDs.contains(id) {
            NSBezierPath(roundedRect: slotFrames[index], xRadius: 18, yRadius: 18).fill()
        }
    }
    func configure(items: [CompactTabItem], selection: UUID) {
        let pinsChanged = Set(items.filter(\.isPinned).map(\.id)) != Set(self.items.filter(\.isPinned).map(\.id))
        if pinsChanged {
            releaseCloseWidths()
        }
        let focusesInsertedTab = labelMode == .address && !self.items.isEmpty && !self.items.contains { $0.id == selection }
            && items.contains { $0.id == selection && $0.address.isEmpty && !$0.isPinned }
            && insertionIndex == nil && dragID == nil
        if items.count < self.items.count, !pinsChanged, pointerInside, dragPanel == nil, frozenCloseWidths == nil { lockCloseWidths() }
        let insertionFrame = focusesInsertedTab ? cells[self.selection].map { document.convert($0.bounds, from: $0) } : nil
        if items.count > self.items.count { releaseCloseWidths(); animatesInsertion = insertionFrame != nil }
        revealSelection = revealSelection || (selection != self.selection && frozenCloseWidth == nil)
        self.items = items; self.selection = selection
        for id in Array(cells.keys) where !items.contains(where: { $0.id == id }) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            let cell = cells[item.id] ?? CompactTabCell(owner: self, item: item)
            if cell.superview == nil {
                // A new tab grows into the row from the previous selection's
                // trailing edge. Existing and inserted cells share the same
                // spring so their boundary remains joined throughout entry.
                if item.id == selection, let insertionFrame {
                    cell.frame = NSRect(x: insertionFrame.maxX, y: insertionFrame.minY,
                                        width: 0.001, height: insertionFrame.height)
                    cell.clipDuringInsertion()
                }
                document.addSubview(cell); cells[item.id] = cell
            }
            cell.configure(item: item, selected: item.id == selection)
        }
        if let dragID, (!canDragTabs || !items.contains(where: { $0.id == dragID })), !isSettling { clearDrag() }
        needsDisplay = true; needsLayout = true; layoutSubtreeIfNeeded()
        if focusesInsertedTab {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selection == selection, self.window?.isKeyWindow == true else { return }
                self.cells[selection]?.focusAddress(haloDelay: 0.6)
            }
        }
    }
    override func layout() {
        super.layout()
        let previousFrames = cells.mapValues { cell in
            cell.superview?.convert(cell.layer?.presentation()?.frame ?? cell.frame, to: self) ?? cell.frame
        }
        let previousModelFrames = cells.mapValues { cell in cell.superview?.convert(cell.frame, to: self) ?? cell.frame }
        let resized = lastLayoutWidth != bounds.width
        lastLayoutWidth = bounds.width
        add.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 26) / 2, width: 26, height: 26)
        pinnedIDs = Set(items.filter(\.isPinned).map(\.id))
        if let reservedID {
            if reservedIsPinned { pinnedIDs.insert(reservedID) } else { pinnedIDs.remove(reservedID) }
        }
        let excluded = reservedID ?? (dragPanel != nil ? dragID : nil)
        let remaining = items.filter { $0.id != excluded }
        // Visual order matches Safari: pinned run first, then regular tabs.
        // slotFrames / natural widths are also pin-first, so slotIDs must be too.
        var order = remaining.filter { pinnedIDs.contains($0.id) }.map(\.id)
            + remaining.filter { !pinnedIDs.contains($0.id) }.map(\.id)
        if let insertionIndex, let excluded { order.insert(excluded, at: min(insertionIndex, order.count)) }
        slotIDs = order
        let count = order.count
        // Entering a different window reserves space without deselecting its
        // current tab. The incoming pill becomes active only when released.
        let visualSelection = settlingSelectionID ?? selection
        let activeIsEmpty = labelMode == .address && (visualSelection == reservedID ? reservedIsEmpty : (items.first { $0.id == visualSelection }?.address.isEmpty ?? true))
        let pinOrder = order.filter { pinnedIDs.contains($0) }
        let normalOrder = order.filter { !pinnedIDs.contains($0) }
        let activePinWidth = TabStripGeometry.restingWidths(available: viewportWidth, count: count,
            selectedIndex: order.firstIndex(of: visualSelection) ?? 0, activeIsEmpty: activeIsEmpty)
            .enumerated().first { order[$0.offset] == visualSelection }?.element ?? 240
        let pinWidths = pinOrder.map { id in id == visualSelection ? activePinWidth : TabStripGeometry.pinnedWidth }
        let pinTotal = pinWidths.reduce(0, +) + CGFloat(max(0, pinWidths.count - 1))
        pinnedExtent = pinTotal + (pinOrder.isEmpty || normalOrder.isEmpty ? 0 : 4)
        let normalViewport = max(0, viewportWidth - pinnedExtent)
        let normalNatural = pinnedIDs.contains(visualSelection)
            ? Array(repeating: TabStripGeometry.width(available: normalViewport, count: normalOrder.count), count: normalOrder.count)
            : TabStripGeometry.restingWidths(available: normalViewport, count: normalOrder.count,
                selectedIndex: normalOrder.firstIndex(of: visualSelection) ?? 0, activeIsEmpty: activeIsEmpty)
        let natural = pinWidths + normalNatural
        let widths = order.enumerated().map { index, id in
            pinnedIDs.contains(id) ? natural[index]
                : ((reservedID != nil ? dragWidths?[id] : nil) ?? frozenCloseWidths?[id] ?? natural[index])
        }
        let gap: CGFloat = frozenCloseGap ?? (normalOrder.count <= 2 ? 0 : TabStripGeometry.gap)
        let normalWidths = Array(widths.dropFirst(pinOrder.count))
        let total = normalWidths.reduce(0, +) + CGFloat(max(0, normalWidths.count - 1)) * gap
        layoutOrigin = frozenCloseOrigin ?? (normalOrder.count <= 2 && !pinnedIDs.contains(visualSelection) ? max(0, (normalViewport - total) / 2) : 0)
        layoutWidths = Dictionary(uniqueKeysWithValues: zip(order, widths))
        tabWidth = layoutWidths[visualSelection] ?? widths.first ?? TabStripGeometry.maximumWidth
        var pinX: CGFloat = 0
        slotFrames = pinWidths.map { width in
            defer { pinX += width + 1 }
            return NSRect(x: pinX, y: (bounds.height - 36) / 2, width: width, height: 36)
        }
        var x = pinnedExtent + layoutOrigin
        slotFrames += normalWidths.map { width in
            defer { x += width + gap }
            return NSRect(x: x, y: (bounds.height - 36) / 2, width: width, height: 36)
        }
        pinnedHost.frame = NSRect(x: 0, y: 0, width: pinnedExtent, height: bounds.height)
        scroll.frame = NSRect(x: pinnedExtent, y: 0, width: normalViewport, height: bounds.height)
        document.frame = NSRect(x: 0, y: 0, width: max(normalViewport, total, frozenCloseDocumentWidth ?? 0), height: bounds.height)
        trackFrame = NSRect(x: pinnedExtent + layoutOrigin - scroll.contentView.bounds.minX, y: (bounds.height - 36) / 2, width: total, height: 36)
        glassTrack?.frame = trackFrame.intersection(scroll.frame)
        // Safari's light track is a subdued dark rim, not a white glass pill
        // casting a second shadow over the page. Keep native glass in dark mode.
        glassTrack?.isHidden = normalOrder.count != 1 || !normalOrder.contains(visualSelection)
            || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
        let overflow = document.frame.width > normalViewport || !pinOrder.isEmpty
        scroll.clipsToBounds = overflow; scroll.contentView.clipsToBounds = overflow
        for item in items {
            guard let cell = cells[item.id] else { continue }
            let parent = pinnedIDs.contains(item.id) ? pinnedHost : document
            if cell.superview !== parent {
                let old = parent.convert(previousFrames[item.id] ?? .zero, from: self)
                parent.addSubview(cell); cell.frame = old
            }
            cell.isHidden = item.id == excluded
        }
        if let excluded, let slot = order.firstIndex(of: excluded), let cell = cells[excluded] {
            // The overlay owns visible motion. Keep its hidden replacement in
            // the reserved slot, so revealing it cannot replay a stale spring
            // from the original tab position (or a new cell's zero frame).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cell.layer?.removeAnimation(forKey: "tab-position")
            cell.layer?.removeAnimation(forKey: "tab-bounds")
            cell.frame = cellFrame(forSlot: slot)
            cell.needsLayout = true; cell.layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
        for item in remaining {
            guard let slot = order.firstIndex(of: item.id) else { continue }
            let rect = cellFrame(forSlot: slot)
            guard let cell = cells[item.id], let parent = cell.superview else { continue }
            let visuallySelected = item.id == visualSelection
            if cell.selected != visuallySelected { cell.configure(item: item, selected: visuallySelected) }
            cell.iconsOnly = item.isPinned && !visuallySelected
            if cell.frame != rect || previousModelFrames[item.id] != parent.convert(rect, to: self) {
                let wasLaidOut = cell.frame.width > 0
                let previous = parent.convert(previousFrames[item.id] ?? rect, from: self)
                let anchor = cell.layer?.anchorPoint ?? .zero
                let old = NSPoint(x: previous.minX + previous.width * anchor.x, y: previous.minY + previous.height * anchor.y)
                let oldBounds = cell.layer?.presentation()?.bounds ?? cell.layer?.bounds
                cell.frame = rect; cell.needsLayout = true
                if wasLaidOut, let layer = cell.layer, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let spring = CASpringAnimation(keyPath: "position")
                    spring.mass = 1
                    spring.stiffness = animatesInsertion ? 900 : pow(2 * .pi / 0.25, 2)
                    spring.damping = 2 * (animatesInsertion ? 1 : 0.85) * sqrt(spring.stiffness)
                    spring.fromValue = NSValue(point: old); spring.toValue = NSValue(point: layer.position)
                    spring.duration = spring.settlingDuration
                    spring.beginTime = CACurrentMediaTime()
                    layer.add(spring, forKey: "tab-position")
                    if let oldBounds, oldBounds != layer.bounds, let sizeSpring = spring.copy() as? CASpringAnimation {
                        sizeSpring.keyPath = "bounds"
                        sizeSpring.fromValue = NSValue(rect: oldBounds); sizeSpring.toValue = NSValue(rect: layer.bounds)
                        layer.add(sizeSpring, forKey: "tab-bounds")
                    }
                }
            }
        }
        if (resized || revealSelection), dragID == nil, insertionIndex == nil, let cell = cells[selection] {
            if cell.superview === document { document.scrollToVisible(cell.frame) }
            revealSelection = false
        }
        animatesInsertion = false
        needsDisplay = true
    }
    private func cellFrame(forSlot slot: Int) -> NSRect {
        slotFrames[slot].offsetBy(dx: pinnedIDs.contains(slotIDs[slot]) ? 0 : -pinnedExtent, dy: 0)
    }
    private func screenFrame(forSlot slot: Int) -> NSRect {
        let parent = pinnedIDs.contains(slotIDs[slot]) ? pinnedHost : document
        return window?.convertToScreen(parent.convert(cellFrame(forSlot: slot), to: nil)) ?? .zero
    }
    func beginDrag(_ id: UUID, event: NSEvent) {
        guard !isSettling, let cell = cells[id] else { return }
        hoverPreviewController?.dismiss()
        clearDrag()
        clickEditsAddress = cell.selected && labelMode == .address
        onSelect(id)
        if selection != id { configure(items: items, selection: id) }
        dragID = id; dragOrigin = screenPoint(event)
        grabOffset = cell.convert(event.locationInWindow, from: nil)
        grabbedWidth = cell.bounds.width
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, self.dragID != nil else { return event }
            switch event.type {
            case .leftMouseDragged: self.continueDrag(event: event); return nil
            case .leftMouseUp: self.endDrag(event: event); return event
            case .keyDown where event.keyCode == 53: self.endDrag(event: event, cancelled: true); return nil
            default: return event
            }
        }
        if clickEditsAddress && cell.item.address.isEmpty { cell.focusAddress() }
    }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    private func snapshot(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size); image.addRepresentation(rep); return image
    }
    private func snapshotWindow() -> NSImage? {
        if let image = previewImage?() { return image }
        if let previewSourceView { return snapshot(previewSourceView) }
        guard let content = window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        // Only this process's own source window is captured. WindowServer keeps
        // native glass/sidebar materials intact; cacheDisplay turns those into
        // blank blocks. No display or other application's window is requested.
        return snapshot(content)
    }
    private var screenFrame: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    private func target(at point: NSPoint) -> CompactTabStripView? {
        Self.strips.removeAll { $0.value == nil }
        let escapeRect = !hasTornOff && locksDragToStrip
            ? screenFrame.insetBy(dx: 0, dy: -100) : screenFrame
        // Window order matters where two application windows overlap.
        for candidateWindow in NSApp.orderedWindows where candidateWindow.isVisible && !(candidateWindow is NSPanel) {
            for weakStrip in Self.strips {
                guard let strip = weakStrip.value, strip.window === candidateWindow,
                      strip === self || (transferOwner != nil && strip.transferOwner != nil) else { continue }
                // The empty-tab recording keeps a horizontally initiated drag
                // on its baseline until about 100pt beyond the strip. A vertical
                // lift escapes earlier. Once detached, re-entry requires the
                // actual strip rather than its enlarged escape region.
                let rect = strip.screenFrame
                if rect.contains(point), point.x <= rect.maxX - 30 { return strip }
            }
            if candidateWindow.frame.contains(point) {
                return candidateWindow === window && escapeRect.contains(point)
                    && point.x <= escapeRect.maxX - 30 ? self : nil
            }
        }
        // The source's generous escape band must not cover a visible tab bar
        // belonging to another window above or beside the source window.
        return escapeRect.contains(point) && point.x <= escapeRect.maxX - 30 ? self : nil
    }
    func reserve(_ id: UUID, at point: NSPoint, source: CompactTabStripView) {
        let firstEntry = reservedID != id
        reservedID = id
        reservedIsEmpty = source.items.first { $0.id == id }?.address.isEmpty ?? true
        reservedIsPinned = source.items.first { $0.id == id }?.isPinned ?? false
        let remaining = items.filter { $0.id != id }
        let pins = remaining.filter(\.isPinned).count
        let allowed = reservedIsPinned ? 0...pins : pins...remaining.count
        guard let window else { return }
        let localPoint = convert(window.convertPoint(fromScreen: point), from: nil)
        let localX = localPoint.x + (reservedIsPinned ? 0 : scroll.contentView.bounds.minX)
        if firstEntry {
            insertionIndex = self === source ? (items.firstIndex { $0.id == id } ?? 0)
                : (remaining.firstIndex { item in
                    guard let cell = cells[item.id] else { return false }
                    return cell.convert(cell.bounds, to: self).midX > localPoint.x
                } ?? remaining.count)
        }
        insertionIndex = min(allowed.upperBound, max(allowed.lowerBound, insertionIndex ?? allowed.lowerBound))
        needsLayout = true; layoutSubtreeIfNeeded()
        let width = slotFrames[insertionIndex ?? 0].width
        let center = localX + (0.5 - source.previewGrabFractionX) * width
        insertionIndex = allowed.lowerBound + TabStripGeometry.destination(center: center,
            slot: (insertionIndex ?? allowed.lowerBound) - allowed.lowerBound, frames: Array(slotFrames[allowed]))
        needsLayout = true; layoutSubtreeIfNeeded(); needsDisplay = true
    }
    private func clearReservation() {
        reservedID = nil; insertionIndex = nil; settlingSelectionID = nil
        if dragPanel == nil { dragWidths = nil }
        needsLayout = true; layoutSubtreeIfNeeded(); needsDisplay = true
    }
    func continueDrag(event: NSEvent) {
        guard canDragTabs, let id = dragID, !isSettling, let cell = cells[id] else { return }
        let point = screenPoint(event)
        guard hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) >= 4 || dragPanel != nil else { return }
        if dragPanel == nil {
            locksDragToStrip = abs(point.x - dragOrigin.x) >= abs(point.y - dragOrigin.y)
            hasTornOff = false
            grabRecenteringBegan = locksDragToStrip ? nil : ProcessInfo.processInfo.systemUptime
            cell.prepareDragSnapshot()
            tabImage = cell.dragForegroundImage(); windowImage = snapshotWindow()
            previewBaseline = window?.convertToScreen(cell.convert(cell.bounds, to: nil)).minY ?? point.y
            lastDragPoint = point
            dragWidths = layoutWidths; releaseCloseWidths()
            let panel = NSPanel(contentRect: cell.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.appearance = effectiveAppearance
            panel.contentView = TabPagePreview(frame: cell.bounds)
            dragPanel = panel
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.renderDragPreview()
            }
            liftAnimation = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        let destination = target(at: point)
        if destination == nil {
            hasTornOff = true
            if grabRecenteringBegan == nil { grabRecenteringBegan = ProcessInfo.processInfo.systemUptime }
        }
        if destination !== dropTarget { dropTarget?.clearReservation(); dropTarget = destination }
        destination?.reserve(id, at: point, source: self)
        if destination !== self { reservedID = nil; insertionIndex = nil; needsLayout = true; layoutSubtreeIfNeeded() }
        if let destination, !destination.reservedIsPinned, let destinationWindow = destination.window {
            let x = destination.scroll.convert(destinationWindow.convertPoint(fromScreen: point), from: nil).x
            let maxScroll = max(0, destination.document.bounds.width - destination.scroll.bounds.width)
            let delta: CGFloat = x < 20 ? -12 : (x > destination.scroll.bounds.width - 20 ? 12 : 0)
            destination.scroll.contentView.scroll(to: NSPoint(x: min(max(0, destination.scroll.contentView.bounds.minX + delta), maxScroll), y: 0))
        }
        lastDragPoint = point
        if let destination, let slot = destination.insertionIndex {
            previewBaseline = destination.screenFrame(forSlot: slot).minY
        }
        setPreviewDetached(destination == nil)
        renderDragPreview()
        needsDisplay = true
    }
    private func setPreviewDetached(_ detached: Bool) {
        let target: CGFloat = detached ? 1 : 0
        guard target != previewTarget else { return }
        previewTarget = target
        previewAnimation?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            previewBlend = target; renderDragPreview()
            return
        }
        let start = previewBlend
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.25)
            let eased = t * t * (3 - 2 * t)
            self.previewBlend = start + (target - start) * eased
            self.renderDragPreview()
            if t >= 1 {
                timer.invalidate(); self.previewAnimation = nil
            }
        }
        previewAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func renderDragPreview() {
        guard let panel = dragPanel, let preview = panel.contentView as? TabPagePreview else { return }
        preview.tabImage = tabImage; preview.pageImage = windowImage; preview.pageBlend = previewBlend
        if isSettling {
            updateDragBackdrop()
            panel.displayIfNeeded()
            CATransaction.flush()
            return
        }
        let original = windowImage?.size ?? NSSize(width: 800, height: 500)
        // Both supplied tear-off recordings settle at about 110 points wide.
        let scale = min(110 / max(1, original.width), 150 / max(1, original.height))
        let thumbnail = NSSize(width: original.width * scale, height: original.height * scale)
        let inlineWidth = dropTarget.flatMap { target in target.insertionIndex.map { target.slotFrames[$0].width } } ?? grabbedWidth
        let size = NSSize(width: inlineWidth + (thumbnail.width - inlineWidth) * previewBlend,
                          height: 36 + (thumbnail.height - 36) * previewBlend)
        let grabX = previewGrabFractionX
        let grabY = min(1, max(0, grabOffset.y / 36))
        let freeY = lastDragPoint.y - size.height * (1 - grabY)
        // A horizontal reorder stays level. A vertically initiated lift follows
        // the pointer immediately, then preserves its grab point while shrinking.
        let inlineY = locksDragToStrip ? previewBaseline : lastDragPoint.y - 36 * (1 - grabY)
        let origin = NSPoint(x: lastDragPoint.x - size.width * grabX,
                             y: inlineY + (freeY - inlineY) * previewBlend)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        updateDragBackdrop()
        panel.orderFront(nil)
        // Timer-driven frames must reach WindowServer even when the pointer is
        // stationary or mouse-up has ended AppKit's event-driven display pass.
        panel.displayIfNeeded()
        CATransaction.flush()
    }
    private func updateDragBackdrop() {
        guard let panel = dragPanel, let preview = panel.contentView as? TabPagePreview else { return }
        guard let target = dropTarget, previewBlend < 0.95, let targetWindow = target.window else {
            preview.backdropImage = nil; return
        }
        let samples = target.items.compactMap { item -> TabDragBackdrop.Sample? in
            guard item.id != dragID, let cell = target.cells[item.id], !cell.isHidden,
                  let parent = cell.superview else { return nil }
            let frame = cell.layer?.presentation()?.frame ?? cell.frame
            let screen = targetWindow.convertToScreen(parent.convert(frame, to: nil))
            guard screen.intersects(panel.frame) else { return nil }
            return TabDragBackdrop.Sample(cell: cell, screenFrame: screen)
        }
        preview.backdropImage = dragBackdrop.image(samples: samples, frame: panel.frame,
            viewport: targetWindow.convertToScreen(target.convert(NSRect(x: 0, y: 0, width: target.viewportWidth, height: target.bounds.height), to: nil)),
            scale: targetWindow.backingScaleFactor)
    }
    private var previewGrabFractionX: CGFloat {
        let original = min(1, max(0, grabOffset.x / max(1, grabbedWidth)))
        // Horizontal dragging preserves the actual grab point. Only lifting
        // out of the row brings the miniature's center under the pointer.
        guard let began = grabRecenteringBegan else { return original }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - began) / 0.12))
        return original + (0.5 - original) * (1 - pow(1 - progress, 3))
    }
    func endDrag(event: NSEvent, cancelled: Bool = false) {
        guard let id = dragID, !isSettling else { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        guard !cancelled else { onSelect(id); clearDrag(); return }
        guard dragPanel != nil else {
            let edit = clickEditsAddress
            clearDrag(); onSelect(id)
            if edit, let cell = cells[id], cell.address.currentEditor() == nil { cell.focusAddress() }
            return
        }
        continueDrag(event: event)
        let point = screenPoint(event)
        guard let destination = dropTarget, let slot = destination.insertionIndex, let targetWindow = destination.window else {
            clearDrag(); onDetach(id, point); return
        }
        destination.settlingSelectionID = id
        destination.needsLayout = true; destination.layoutSubtreeIfNeeded()
        let targetFrame = destination.screenFrame(forSlot: slot)
        isSettling = true
        previewAnimation?.invalidate(); previewAnimation = nil
        previewTarget = 0
        func commitDrop() -> Bool {
            guard targetWindow.isVisible else { return false }
            if destination === self {
                onSelect(id)
                onMove(id, slot); return true
            }
            return onTransfer(id, destination, slot)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { _ = commitDrop(); clearDrag(); return }
        guard let startFrame = dragPanel?.frame else { clearDrag(); return }
        let startBlend = previewBlend
        let began = ProcessInfo.processInfo.systemUptime
        var committedAt: TimeInterval?
        // One clock owns position, size and the reverse morph. A quick re-entry
        // cannot reveal the resting cell while its thumbnail is still fading.
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed >= 0.3 {
                // Moving an NSHostingView can occupy the main thread.
                // Finish the visible motion first.
                if committedAt == nil {
                    previewBlend = 0
                    dragPanel?.setFrame(targetFrame, display: false)
                    renderDragPreview()
                    guard commitDrop() else { clearDrag(); return }
                    committedAt = ProcessInfo.processInfo.systemUptime
                }
                // This commit runs from a timer, after pointer tracking ended.
                // Give AppKit/NSHostingView an update pass without depending on
                // a subsequent mouse move to paint the transferred page.
                NSApp.updateWindows()
                targetWindow.contentView?.layoutSubtreeIfNeeded()
                targetWindow.displayIfNeeded()
                // SwiftUI installs the transferred model on its next update.
                // Keep the overlay over the reserved slot until that cell exists.
                let installed = destination.cells[id] != nil && destination.selection == id
                    && destination.items.firstIndex(where: { $0.id == id }) == slot
                if installed || ProcessInfo.processInfo.systemUptime - committedAt! > 1 {
                    timer.invalidate(); settlingAnimation = nil
                    clearDrag()
                    targetWindow.displayIfNeeded(); CATransaction.flush()
                }
                return
            }
            let phase = elapsed * 30
            let progress = CGFloat(1 - (1 + phase) * exp(-phase))
            func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
            let rect = NSRect(x: interpolate(startFrame.minX, targetFrame.minX), y: interpolate(startFrame.minY, targetFrame.minY),
                              width: interpolate(startFrame.width, targetFrame.width), height: interpolate(startFrame.height, targetFrame.height))
            previewBlend = startBlend * (1 - progress)
            dragPanel?.setFrame(rect, display: false)
            renderDragPreview()
        }
        settlingAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func clearDrag() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        let destination = dropTarget
        dropTarget = nil
        previewAnimation?.invalidate(); previewAnimation = nil
        liftAnimation?.invalidate(); liftAnimation = nil
        settlingAnimation?.invalidate(); settlingAnimation = nil
        dragBackdrop.clear()
        previewBlend = 0; previewTarget = 0
        let retiringPanel = dragPanel
        dragPanel = nil
        dragID = nil; tabImage = nil; windowImage = nil; isSettling = false
        clickEditsAddress = false
        grabRecenteringBegan = nil
        dragWidths = nil; reservedID = nil; insertionIndex = nil; settlingSelectionID = nil
        if destination !== self { destination?.clearReservation() }
        needsLayout = true; needsDisplay = true; layoutSubtreeIfNeeded()
        if let retiringPanel {
            // Install and paint the resting tab before retiring its overlay.
            // Both representations now occupy exactly the same slot.
            destination?.window?.displayIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            retiringPanel.orderOut(nil)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        clearDrag()
    }
    override func mouseDown(with event: NSEvent) {}
    deinit {
        let hoverPreview = hoverPreviewController
        Task { @MainActor in hoverPreview?.dismiss() }
        let dragGuard = windowDragGuard
        let stripID = ObjectIdentifier(self)
        Task { @MainActor in dragGuard?.detach(stripID) }
        previewAnimation?.invalidate()
        liftAnimation?.invalidate()
        settlingAnimation?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let focusDismissMonitor { NSEvent.removeMonitor(focusDismissMonitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        // Tear-down mid-drag must not leave a floating overlay on screen.
        dragPanel?.orderOut(nil)
    }
}

final class CompactTabCell: NSView, NSTextFieldDelegate {
    weak var owner: CompactTabStripView?
    var item: CompactTabItem
    var selected = false
    private let title = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    let address = CompactAddressField()
    private let icon = NSImageView()
    private let close = NSButton()
    private let reload = NSButton()
    private let actions = NSButton()
    private let progress = NSProgressIndicator()
    private var hovering = false
    private var capturesDragForeground = false
    private var addressDraft: String?
    private var focusAnimation: Timer?
    private let focusPulse = CAShapeLayer()
    private var focusProgress: CGFloat = 1
    private var nextHaloDelay: TimeInterval = 0.045
    private var focusAlignment: CGFloat = 0
    private var focusWindowObservers: [NSObjectProtocol] = []
    func clipDuringInsertion() {
        layer?.masksToBounds = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.layer?.masksToBounds = false
        }
    }
    private var isSingleTab: Bool { owner?.items.count == 1 }
    private var allowsAddressEditing: Bool { owner?.labelMode == .address }
    private var displayValue: String { allowsAddressEditing ? item.address : item.title }
    private var isEmptyAddress: Bool { allowsAddressEditing && item.address.isEmpty }
    var iconsOnly = false { didSet { if oldValue != iconsOnly { needsLayout = true } } }
    private(set) var isEditingAddress = false
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) { fatalError() }
    init(owner: CompactTabStripView, item: CompactTabItem) {
        self.owner = owner; self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        title.font = .systemFont(ofSize: 13, weight: .regular); title.lineBreakMode = .byTruncatingTail
        title.identifier = NSUserInterfaceItemIdentifier("tab-title")
        title.cell?.wraps = false; title.usesSingleLineMode = true
        title.textColor = .labelColor
        address.isBordered = false; address.drawsBackground = false
        address.font = .systemFont(ofSize: 13, weight: .medium); address.focusRingType = .none
        address.textColor = NSColor.labelColor.withAlphaComponent(0.9)
        address.alignment = .left; address.delegate = self
        address.cell?.wraps = false
        address.cell?.isScrollable = true
        address.usesSingleLineMode = true
        address.lineBreakMode = .byClipping
        address.onFocusChange = { [weak self] focused in self?.setAddressFocus(focused) }
        address.onBeginTabDrag = { [weak self] event in
            guard let self else { return }; self.owner?.beginDrag(self.item.id, event: event)
        }
        address.setAccessibilityLabel("Tab address and search")
        placeholder.identifier = NSUserInterfaceItemIdentifier("tab-placeholder")
        placeholder.lineBreakMode = .byClipping; placeholder.usesSingleLineMode = true
        placeholder.setAccessibilityElement(false)
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close tab")
        close.isBordered = false; close.target = self; close.action = #selector(closeTab)
        close.contentTintColor = NSColor.labelColor.withAlphaComponent(0.9)
        close.setAccessibilityLabel("Close tab")
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload tab")
        reload.isBordered = false; reload.target = self; reload.action = #selector(refresh)
        reload.contentTintColor = NSColor.labelColor.withAlphaComponent(0.85)
        let actionsImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let rectangle = NSBezierPath(roundedRect: NSRect(x: 2, y: 8, width: 12, height: 7), xRadius: 1, yRadius: 1)
            rectangle.lineWidth = 1; rectangle.stroke()
            let lines = NSBezierPath(); lines.lineWidth = 1
            lines.move(to: NSPoint(x: 2, y: 5)); lines.line(to: NSPoint(x: 14, y: 5))
            lines.move(to: NSPoint(x: 2, y: 1.5)); lines.line(to: NSPoint(x: 10, y: 1.5)); lines.stroke()
            return true
        }
        actionsImage.isTemplate = true
        actions.image = actionsImage; actions.isBordered = false
        actions.contentTintColor = NSColor.labelColor.withAlphaComponent(0.85)
        actions.target = self; actions.action = #selector(showActions)
        actions.setAccessibilityLabel("Tab actions"); actions.toolTip = "Tab actions"
        progress.style = .spinning; progress.controlSize = .mini; progress.isDisplayedWhenStopped = false
        [title, address, placeholder, icon, close, reload, actions, progress].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.radioButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWindowObservers.forEach(NotificationCenter.default.removeObserver)
        focusWindowObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                focusWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.updateFocusPulse(1)
                    self?.needsLayout = true
                    self?.layoutSubtreeIfNeeded()
                    self?.needsDisplay = true
                })
            }
        }
        updateFocusPulse(1)
    }
    deinit {
        focusAnimation?.invalidate()
        focusWindowObservers.forEach(NotificationCenter.default.removeObserver)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Alpha-adjusted semantic colors in attributed strings can retain the
        // appearance in which they were created. Rebuild under this window's
        // appearance when it changes, including while the app stays dark.
        if window != nil { configure(item: item, selected: selected) }
    }
    func configure(item: CompactTabItem, selected: Bool) {
        if !allowsAddressEditing {
            if isEditingAddress { window?.makeFirstResponder(nil); setAddressFocus(false) }
            addressDraft = nil
        }
        if self.selected && !selected && isEditingAddress { window?.makeFirstResponder(nil) }
        if item.address != self.item.address { addressDraft = nil }
        self.item = item; self.selected = selected
        address.isEditable = allowsAddressEditing
        address.isSelectable = allowsAddressEditing
        address.setAccessibilityLabel(allowsAddressEditing ? "Tab address and search" : "Tab label")
        address.lineBreakMode = allowsAddressEditing ? .byClipping : .byTruncatingTail
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            address.textColor = NSColor.labelColor.withAlphaComponent(0.9)
            address.font = .systemFont(ofSize: 13, weight: isEmptyAddress ? .medium : .regular)
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.lineBreakMode = .byTruncatingTail
            let titleColor = dark ? NSColor(srgbRed: 220/255, green: 220/255, blue: 222/255, alpha: 1) : NSColor.labelColor
            title.attributedStringValue = NSAttributedString(string: item.title, attributes: [.font: title.font!, .kern: -0.2, .foregroundColor: titleColor, .paragraphStyle: titleStyle])
            if address.currentEditor() == nil { address.stringValue = addressDraft ?? displayValue }
            let placeholderStyle = NSMutableParagraphStyle()
            placeholderStyle.lineBreakMode = .byClipping
            let hintColor = dark ? NSColor(srgbRed: 150/255, green: 152/255, blue: 155/255, alpha: 1) : NSColor.secondaryLabelColor
            let hint = NSAttributedString(string: item.searchPrompt, attributes: [.font: address.font!, .foregroundColor: hintColor, .paragraphStyle: placeholderStyle])
            address.placeholderAttributedString = nil
            placeholder.attributedStringValue = hint
            placeholder.textColor = hintColor
            if !isEditingAddress { address.alignment = isEmptyAddress ? .left : .center }
            let showsIdentity = !allowsAddressEditing || item.isPinned || !selected || (!isEditingAddress && !item.address.isEmpty)
            if showsIdentity, let image = item.iconImage {
                icon.image = image; icon.contentTintColor = nil
            } else if showsIdentity, let letter = item.faviconLetter {
                icon.image = Self.letterIcon(letter)
                icon.contentTintColor = nil
            } else {
                let symbol = NSImage(systemSymbolName: selected && allowsAddressEditing ? (item.isTrusted ? "lock" : "magnifyingglass") : item.symbol, accessibilityDescription: nil)
                icon.image = symbol?.withSymbolConfiguration(.init(pointSize: selected && allowsAddressEditing ? 12 : 15, weight: .regular))
                icon.contentTintColor = NSColor.labelColor.withAlphaComponent(selected ? 0.5 : 0.64)
            }
        }
        setAccessibilityIdentifier(item.id.uuidString)
        setAccessibilityLabel(item.title); setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityHelp(item.isPinned ? "Pinned tab. Use the context menu to unpin." : nil)
        toolTip = nil
        owner?.refreshHoverPreview(over: self)
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        if let inside = pointerIsInside { hovering = inside }
        let w = bounds.width
        if item.isPinned && !selected {
            [title, address, placeholder, close, reload, actions].forEach { $0.isHidden = true }
            icon.frame = NSRect(x: (w - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            icon.isHidden = item.isBusy
            progress.frame = icon.frame; progress.isHidden = !item.isBusy
            if item.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            updateFocusPulse(1)
            return
        }
        let dy: CGFloat = selected ? (bounds.height - 30) / 2 : 0
        close.frame = NSRect(x: 8, y: 10, width: 16, height: 16)
        let measuredTitle = ceil(title.attributedStringValue.size().width) + 4
        let titleWidth = min(measuredTitle, max(0, w - 57))
        let contentWidth = 16 + 5 + titleWidth
        let contentX = max(24, (w - contentWidth) / 2 + 2.5)
        icon.frame = selected ? NSRect(x: 10, y: 7 + dy, width: 16, height: 16)
            : NSRect(x: iconsOnly ? (w - 16) / 2 : contentX + 2, y: item.faviconLetter == nil ? 11 : 10, width: 16, height: 16)
        title.frame = NSRect(x: contentX + 21, y: 6, width: titleWidth, height: 20)
        let searching = selected && allowsAddressEditing && (isEditingAddress || item.address.isEmpty)
        address.displaysTabAddress = selected && allowsAddressEditing && !searching
        address.cell?.isScrollable = searching
        address.frame = NSRect(x: 30, y: 4 + dy, width: max(0, w - (searching ? 36 : (hovering ? 85 : 63))), height: 19)
        placeholder.isHidden = !selected || !isEmptyAddress || !address.stringValue.isEmpty
        placeholder.frame = address.frame
        if selected && !searching {
            icon.frame.origin.x = 30
            address.frame = NSRect(x: 51, y: 4 + dy, width: max(0, w - 108), height: 19)
            address.alignment = .right
        }
        if selected && isEmptyAddress && address.stringValue.isEmpty {
            let placeholderWidth = (item.searchPrompt as NSString).size(withAttributes: [.font: address.font!]).width + 4
            if placeholderWidth + 24 < w - 20 {
                let start = (w - placeholderWidth - 24) / 2
                let x = start + (10 - start) * focusAlignment
                icon.frame.origin.x = x
                // The native editor and caret stay fixed while the hint moves.
                placeholder.frame = NSRect(x: x + 21, y: 4 + dy, width: max(0, w - x - 27), height: 19)
            }
        }
        if selected && !searching {
            let textWidth = ceil((displayValue as NSString).size(withAttributes: [.font: address.font!]).width)
                + (allowsAddressEditing ? 4 : 12) // The static NSTextField includes its native text inset.
            if textWidth + 21 < w - 100 {
                let start = (w - textWidth - 21) / 2 - 2
                icon.frame.origin.x = start
                address.frame = NSRect(x: start + 21, y: 4 + dy, width: textWidth, height: 19)
                address.alignment = .center
            }
        }
        if selected && !isEditingAddress && !displayValue.isEmpty && address.currentEditor() == nil {
            let style = NSMutableParagraphStyle()
            style.alignment = address.alignment; style.lineBreakMode = allowsAddressEditing ? .byClipping : .byTruncatingTail
            let value = NSAttributedString(string: displayValue, attributes: [.font: address.font!, .foregroundColor: address.textColor!, .paragraphStyle: style])
            if address.attributedStringValue != value { address.attributedStringValue = value }
        }
        actions.frame = NSRect(x: w - 27, y: 6 + dy, width: 18, height: 18)
        reload.frame = NSRect(x: w - 49, y: 6 + dy, width: 18, height: 18)
        progress.frame = reload.frame
        title.isHidden = selected || iconsOnly; address.isHidden = !selected
        close.isHidden = item.isPinned || isSingleTab || (!hovering && !capturesDragForeground) || isEditingAddress
        icon.isHidden = false
        actions.isHidden = !selected || searching
        reload.isHidden = !selected || item.isBusy || searching || (!hovering && !capturesDragForeground)
        progress.isHidden = !selected || !item.isBusy
        if selected && item.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        address.updateFocusRingMask()
        updateFocusPulse(focusProgress)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !capturesDragForeground else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if selected {
            if isSingleTab, #unavailable(macOS 26.0) {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
                let rim = NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18)
                rim.append(NSBezierPath(roundedRect: bounds.insetBy(dx: 3.5, dy: 3.5), xRadius: 15, yRadius: 15))
                rim.windingRule = .evenOdd; rim.fill()
            }
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3.5, dy: 3.5), xRadius: 15, yRadius: 15)
            let alpha: CGFloat = isSingleTab ? (hovering || isEditingAddress ? 0.19 : 0.16)
                : (isEmptyAddress ? (hovering || isEditingAddress ? 0.15 : 0.13) : (hovering ? 0.16 : 0.14))
            let lightAlpha: CGFloat = isSingleTab && isEditingAddress ? 0.5 : 0.7
            NSColor.white.withAlphaComponent(dark ? alpha : lightAlpha).setFill(); path.fill()
            (dark ? NSColor.labelColor.withAlphaComponent(0.27) : NSColor.white.withAlphaComponent(0.85)).setStroke()
            path.lineWidth = 0.75; path.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.055).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3.5, dy: 3.5), xRadius: 15, yRadius: 15).fill()
        } else if !item.isPinned {
            if let owner, let index = owner.items.firstIndex(where: { $0.id == item.id }),
               index + 1 < owner.items.count, owner.items[index + 1].id != owner.selection {
                NSColor.separatorColor.setFill(); NSRect(x: bounds.maxX - 0.5, y: 8, width: 0.5, height: 20).fill()
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        // The unclipped halo can make visibleRect larger than the tab. Track
        // the cell itself, intersected with the scroll viewport, not that halo.
        addTrackingArea(NSTrackingArea(rect: bounds.intersection(visibleRect), options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self))
        if let inside = pointerIsInside {
            if hovering != inside { hovering = inside; needsLayout = true; needsDisplay = true }
        }
    }
    private var pointerIsInside: Bool? {
        guard let window, window.isVisible else { return nil }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return window.isKeyWindow && !isHidden && owner?.isDragging != true
            && bounds.contains(point) && visibleRect.contains(point)
    }
    private static func letterIcon(_ letter: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.15, dy: 0.15), xRadius: 3, yRadius: 3)
            NSColor(srgbRed: 0.56, green: 0.58, blue: 0.62, alpha: 1).setFill(); path.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke(); path.lineWidth = 0.4; path.stroke()
            let text = String(letter.prefix(1)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (rect.width-size.width)/2, y: (rect.height-size.height)/2), withAttributes: attributes)
            return true
        }
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = pointerIsInside ?? (owner?.isDragging != true)
        if hovering { owner?.beginHoverPreview(over: self) }
        needsLayout = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovering = pointerIsInside ?? false
        owner?.endHoverPreview(over: self)
        needsLayout = true; needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Labels and icons must forward drags to the tab; controls keep native events.
        // Keep the initial press on the tab until it is known to be an edit or
        // a drag. Handing an unfocused address to NSTextField immediately lets
        // its field editor consume the drag as text selection.
        if hit === placeholder || (hit === address && address.currentEditor() == nil) { return self }
        return hit === title || hit === icon ? self : hit
    }
    override func mouseDown(with event: NSEvent) { owner?.beginDrag(item.id, event: event) }
    override func mouseDragged(with event: NSEvent) { owner?.continueDrag(event: event) }
    override func mouseUp(with event: NSEvent) { owner?.endDrag(event: event) }
    override func accessibilityPerformPress() -> Bool { owner?.onSelect(item.id); return true }
    override func menu(for event: NSEvent) -> NSMenu? { tabMenu() }
    override func accessibilityPerformShowMenu() -> Bool {
        showActions(); return true
    }
    @objc private func closeTab() { owner?.requestClose(item.id) }
    @objc private func pinTab() { owner?.requestPin(item.id) }
    @objc private func refresh() { owner?.onSelect(item.id); owner?.onReload() }
    private func tabMenu() -> NSMenu {
        let menu = NSMenu()
        let pin = NSMenuItem(title: item.isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(pinTab), keyEquivalent: "")
        pin.image = NSImage(systemSymbolName: item.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        if owner?.allowsPinning == true {
            pin.target = self; menu.addItem(pin)
            menu.addItem(.separator())
        }
        for (title, selector) in [("Reload Tab", #selector(refresh)), ("Move Tab to New Window", #selector(detachTab)), ("Close Tab", #selector(closeTab))] {
            if selector == #selector(detachTab), owner?.canDragTabs != true { continue }
            let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            action.target = self; menu.addItem(action)
        }
        return menu
    }
    @objc private func showActions() {
        let menu = tabMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 24, y: 0), in: self)
    }
    @objc private func detachTab() {
        guard owner?.canDragTabs == true, let window else { return }
        owner?.onDetach(item.id, window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: 0), to: nil)))
    }
    private func setAddressFocus(_ focused: Bool) {
        guard isEditingAddress != focused else { return }
        isEditingAddress = focused
        focusAnimation?.invalidate(); focusAnimation = nil
        updateFocusPulse(focused ? 0 : 1)
        let target: CGFloat = focused ? 1 : 0
        let haloDelay = nextHaloDelay
        nextHaloDelay = 0.045
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let start = focusAlignment
            let began = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                // Fit to the original, timestamped Safari activation frames:
                // critically damped response, natural frequency 23 rad/s.
                // Unlike a cubic ease-out this starts with zero velocity.
                let phase = elapsed * 23
                let remaining = (1 + phase) * exp(-phase)
                self.focusAlignment = start + (target - start) * (1 - remaining)
                // Safari's halo follows the initial hint movement. Its
                // 45ms delay and 240ms contraction are measured separately
                // from the text response in the timestamped source frames.
                self.updateFocusPulse(min(1, max(0, (elapsed - haloDelay) / 0.24)))
                self.needsLayout = true; self.layoutSubtreeIfNeeded()
                if elapsed >= max(0.45, focused ? haloDelay + 0.24 : 0) {
                    self.focusAlignment = target
                    self.needsLayout = true
                    timer.invalidate(); self.focusAnimation = nil
                }
            }
            focusAnimation = timer; RunLoop.main.add(timer, forMode: .common)
        } else { focusAlignment = target; updateFocusPulse(1) }
        address.alignment = focused || item.address.isEmpty ? .left : .center
        if let editor = address.currentEditor() as? NSTextView {
            editor.alignment = address.alignment
            editor.insertionPointColor = .systemPink
        }
        needsLayout = true; needsDisplay = true
    }
    private func updateFocusPulse(_ progress: CGFloat) {
        focusProgress = progress
        guard selected && isEditingAddress && window?.isKeyWindow == true else {
            focusPulse.removeFromSuperlayer(); return
        }
        if focusPulse.superlayer == nil { layer?.addSublayer(focusPulse) }
        let outset = 24 * pow(1 - progress, 2)
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds.insetBy(dx: -outset, dy: -outset), cornerWidth: 18 + outset, cornerHeight: 18 + outset)
        path.addRoundedRect(in: bounds.insetBy(dx: 3.5, dy: 3.5), cornerWidth: 15, cornerHeight: 15)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            focusPulse.fillColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
        focusPulse.fillRule = .evenOdd
        focusPulse.path = path
        focusPulse.opacity = Float(0.9 * progress * progress)
        CATransaction.commit()
    }
    func prepareDragSnapshot() {
        if isEditingAddress { window?.makeFirstResponder(nil) }
        focusAnimation?.invalidate(); focusAnimation = nil
        focusAlignment = 0
        needsLayout = true; needsDisplay = true
        layoutSubtreeIfNeeded()
    }
    func dragForegroundImage() -> NSImage? {
        // The floating host supplies the live material. Capturing the selected
        // fill here would flatten it and hide the sibling sliding underneath.
        capturesDragForeground = true
        needsLayout = true; needsDisplay = true; layoutSubtreeIfNeeded()
        displayIfNeeded()
        defer {
            capturesDragForeground = false
            needsLayout = true; needsDisplay = true
        }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size); image.addRepresentation(rep)
        return image
    }
    func focusAddress(haloDelay: TimeInterval = 0.045) {
        guard allowsAddressEditing else { return }
        nextHaloDelay = haloDelay
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectedRange = NSRange(location: address.stringValue.utf16.count, length: 0)
    }
    fileprivate func dismissAddressForOutsideClick(_ event: NSEvent) {
        guard isEditingAddress, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hitsTabAction = [close, reload, actions].contains { !$0.isHidden && $0.frame.contains(point) }
        guard !bounds.contains(point) || hitsTabAction else { return }
        window.makeFirstResponder(nil)
    }
    func controlTextDidChange(_ notification: Notification) {
        addressDraft = address.stringValue; needsLayout = true
    }
    func controlTextDidBeginEditing(_ notification: Notification) { setAddressFocus(true) }
    func controlTextDidEndEditing(_ notification: Notification) {
        addressDraft = address.stringValue == item.address ? nil : address.stringValue
        setAddressFocus(false)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard allowsAddressEditing else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            owner?.onSearch(address.stringValue); window?.makeFirstResponder(nil); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil); addressDraft = nil; address.stringValue = item.address
            needsLayout = true; return true
        }
        return false
    }
}

/// NSTextField hands first-responder status to the shared field editor. The
/// begin-editing notification alone is too late: it arrives on the first typed
/// character, while the empty focused field already needs its ring and inset.
final class CompactAddressField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { isEditable && super.acceptsFirstResponder }
    var displaysTabAddress = false { didSet { if oldValue != displaysTabAddress { needsDisplay = true } } }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onBeginTabDrag: (NSEvent) -> Void = { _ in }
    private var lastFocusMaskBounds: NSRect = .zero
    func updateFocusRingMask() {
        let rect = focusRingMaskBounds
        if rect != lastFocusMaskBounds { lastFocusMaskBounds = rect; noteFocusRingMaskChanged() }
    }
    override var focusRingMaskBounds: NSRect {
        guard let cell = superview as? CompactTabCell else { return super.focusRingMaskBounds }
        return convert(cell.bounds.insetBy(dx: 3.5, dy: 3.5), from: cell)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 15, yRadius: 15).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard displaysTabAddress, currentEditor() == nil, !stringValue.isEmpty else { super.draw(dirtyRect); return }
        // NSTextFieldCell clips long editable values at their trailing edge even
        // while idle. Preserve the useful path suffix and fade its leading edge;
        // actual editing continues to use AppKit's shared native field editor.
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: textColor ?? NSColor.labelColor]
        let text = stringValue as NSString
        let size = text.size(withAttributes: attributes)
        let clipped = size.width > bounds.width - 4
        let x = clipped ? bounds.width - size.width - 2 : (bounds.width - size.width) / 2
        guard let context = NSGraphicsContext.current?.cgContext else { super.draw(dirtyRect); return }
        context.saveGState(); context.clip(to: bounds); context.beginTransparencyLayer(auxiliaryInfo: nil)
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2 + (isFlipped ? -1.5 : 1.5)), withAttributes: attributes)
        if clipped, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.clear.cgColor, NSColor.white.cgColor] as CFArray, locations: [0, 1]) {
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: min(28, bounds.width * 0.7), y: 0), options: [.drawsAfterEndLocation])
        }
        context.endTransparencyLayer(); context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEditable else { onBeginTabDrag(event); return }
        // An unfocused address is also the tab's drag surface. Once editing,
        // AppKit retains normal text selection, IME and text-drag behavior.
        guard currentEditor() == nil, let window else { super.mouseDown(with: event); return }
        // Focus belongs to the press, not the release. The strip's event
        // monitor retains the original press and applies its 4pt drag threshold
        // while the field editor and focus animation can run normally.
        onBeginTabDrag(event)
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: stringValue.utf16.count)
    }
    override func becomeFirstResponder() -> Bool {
        guard isEditable else { return false }
        alignment = .left
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange(false)
    }
}

private final class TabPagePreview: NSView {
    private let page = TabPreviewImageView()
    private let foreground = TabPreviewImageView()
    private let glass: NSView
    var tabImage: NSImage? { didSet { foreground.image = tabImage } }
    var backdropImage: NSImage? { didSet { foreground.backdropImage = backdropImage } }
    var pageImage: NSImage? { didSet { page.image = pageImage } }
    var pageBlend: CGFloat = 0 { didSet { needsLayout = true; layoutSubtreeIfNeeded() } }
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .clear
            effect.tintColor = NSColor.white.withAlphaComponent(0.155)
            effect.contentView = foreground
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow; effect.material = .hudWindow; effect.state = .active
            effect.addSubview(foreground)
            glass = effect
        }
        super.init(frame: frame)
        page.fillsBounds = true
        addSubview(page); addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let radius = 15 + (3 - 15) * pageBlend
        page.frame = bounds; page.cornerRadius = radius
        foreground.cornerRadius = radius
        page.alphaValue = pageBlend
        glass.frame = bounds.insetBy(dx: 3.5 * (1 - pageBlend), dy: 3.5 * (1 - pageBlend))
        glass.alphaValue = 1 - pageBlend
        if #available(macOS 26.0, *), let effect = glass as? NSGlassEffectView {
            effect.cornerRadius = radius
        } else {
            glass.wantsLayer = true; glass.layer?.cornerRadius = radius; glass.layer?.masksToBounds = true
            foreground.frame = glass.bounds
        }
    }
}

private final class TabPreviewImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var backdropImage: NSImage? { didSet { needsDisplay = true } }
    var fillsBounds = false
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        if !fillsBounds {
            if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                // Match the resting selection's luminance without making the
                // material opaque: both its live backdrop and lens remain visible.
                NSColor.white.withAlphaComponent(0.072).setFill()
                bounds.fill()
            }
            // Native glass supplies the continuously sampled backdrop and rim.
            // A shallow lens preserves the recognizable moving sibling inside
            // it; the standard material alone blurs a 16pt favicon to a blob.
            backdropImage?.draw(in: bounds.insetBy(dx: -3.5, dy: -3.5), from: .zero,
                operation: .sourceOver, fraction: 0.72, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high])
            // Keep lettering upright as the host grows from a short pill into
            // a page thumbnail. Stretching the bitmap to the host distorts it.
            // The foreground snapshot includes the cell's 3.5pt clear inset.
            let scale = min(1, (bounds.width + 7) / max(1, image.size.width))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // Reveal the page downward from its top as the clip grows. Its
            // content keeps one uniform scale throughout the morph.
            let scale = max(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
                              width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}

/// Refract only the sibling content, at its current presentation coordinates.
/// The original views continue to animate in their reserved slots. No screen
/// capture permission, page recapture, or model reorder is needed per frame.
private final class TabDragBackdrop {
    struct Sample { let cell: CompactTabCell; let screenFrame: NSRect }
    private struct Cached { let item: CompactTabItem; let size: NSSize; let image: CIImage }
    private var images: [UUID: Cached] = [:]
    private var previousFrames: [NSRect] = []
    private var previousIDs: [UUID] = []
    private var previousScale: CGFloat = 0
    private var previousImage: NSImage?
    private let context = CIContext(options: [.cacheIntermediates: false])
    func clear() { images.removeAll(); previousFrames = []; previousIDs = []; previousImage = nil }
    func image(samples: [Sample], frame: NSRect, viewport: NSRect, scale: CGFloat) -> NSImage? {
        guard !samples.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        let frames = [frame, viewport] + samples.map(\.screenFrame)
        let ids = samples.map { $0.cell.item.id }
        if frames == previousFrames, ids == previousIDs, scale == previousScale,
           samples.allSatisfy({ images[$0.cell.item.id]?.item == $0.cell.item && images[$0.cell.item.id]?.size == $0.cell.bounds.size }) {
            return previousImage
        }
        let extent = CGRect(origin: .zero, size: CGSize(width: frame.width * scale, height: frame.height * scale))
        var scene = CIImage.empty()
        for sample in samples {
            let cell = sample.cell
            if images[cell.item.id]?.item != cell.item || images[cell.item.id]?.size != cell.bounds.size {
                cell.displayIfNeeded()
                guard let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
                cell.cacheDisplay(in: cell.bounds, to: rep)
                guard let cg = rep.cgImage else { continue }
                images[cell.item.id] = Cached(item: cell.item, size: cell.bounds.size, image: CIImage(cgImage: cg))
            }
            guard let cached = images[cell.item.id] else { continue }
            let rect = sample.screenFrame
            let transform = CGAffineTransform(a: rect.width * scale / cached.image.extent.width, b: 0, c: 0,
                d: rect.height * scale / cached.image.extent.height,
                tx: (rect.minX - frame.minX) * scale, ty: (rect.minY - frame.minY) * scale)
            scene = cached.image.transformed(by: transform).composited(over: scene)
        }
        let clip = CGRect(x: (viewport.minX - frame.minX) * scale, y: (viewport.minY - frame.minY) * scale,
                          width: viewport.width * scale, height: viewport.height * scale)
        scene = scene.cropped(to: clip)
        let radius = 14.5 * scale
        let lens = scene.applyingFilter("CIGlassLozenge", parameters: [
            "inputPoint0": CIVector(x: 18 * scale, y: extent.midY),
            "inputPoint1": CIVector(x: extent.width - 18 * scale, y: extent.midY),
            "inputRadius": radius, "inputRefraction": 1.08
        ]).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8 * scale])
        guard let cg = context.createCGImage(lens, from: extent) else { return nil }
        previousFrames = frames; previousIDs = ids; previousScale = scale
        let image = NSImage(cgImage: cg, size: frame.size)
        previousImage = image
        return image
    }
}

private final class TabStripDocumentView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}

@available(macOS 26.0, *)
private final class TabGlassTrack: NSGlassEffectView {
    // The glass is a material behind the strip, never an input surface.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
