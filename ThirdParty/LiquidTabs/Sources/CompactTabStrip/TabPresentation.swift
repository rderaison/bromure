import AppKit

public enum CompactTabLabelMode: Equatable {
    case fixed
    case address
}

public struct CompactTabHoverContent: Equatable {
    public var title: String
    public var subtitle: String?
    public var detail: String?

    public init(title: String, subtitle: String? = nil, detail: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
    }
}

public struct CompactTabHoverConfiguration: Equatable {
    public var delay: TimeInterval
    public var maximumWidth: CGFloat

    public init(delay: TimeInterval = 0.65, maximumWidth: CGFloat = 280) {
        self.delay = delay
        self.maximumWidth = maximumWidth
    }
}

// MARK: - Convenience factories & collection helpers

public extension CompactTabItem {
    /// Standard page tab with title, address, and SF Symbol.
    static func page(
        title: String,
        address: String = "",
        symbol: String = "doc.text",
        isPinned: Bool = false
    ) -> CompactTabItem {
        CompactTabItem(title: title, address: address, symbol: symbol, isPinned: isPinned)
    }

    /// Pinned launcher-style tab (icon glyph, no address chrome).
    static func pinned(
        title: String,
        symbol: String = "pin.fill",
        address: String = ""
    ) -> CompactTabItem {
        CompactTabItem(title: title, address: address, symbol: symbol, isPinned: true)
    }

    /// Blank tab ready for the user's next destination.
    static var newTab: CompactTabItem {
        CompactTabItem(title: "New Tab", address: "")
    }
}

public extension Array where Element == CompactTabItem {
    /// Safari grouping: pinned run first, then regular tabs (stable within each group).
    var pinsFirst: [CompactTabItem] {
        filter(\.isPinned) + filter { !$0.isPinned }
    }

    /// Toggle pin state and move the item into the pinned run (web `pin()` parity).
    mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = firstIndex(where: { $0.id == id }), self[index].isPinned != pinned else { return }
        self[index].isPinned = pinned
        let item = remove(at: index)
        let pinCount = filter(\.isPinned).count
        insert(item, at: pinned ? pinCount : Swift.min(pinCount, count))
    }

    /// Reorder by id into a visual slot index (pins stay grouped).
    mutating func move(id: UUID, to index: Int) {
        guard let from = firstIndex(where: { $0.id == id }) else { return }
        let item = remove(at: from)
        let pins = filter(\.isPinned).count
        let clamped = Swift.max(0, Swift.min(index, count))
        let destination = item.isPinned ? Swift.min(clamped, pins) : Swift.max(clamped, pins)
        insert(item, at: Swift.min(destination, count))
    }

    /// Remove a tab and return the id that should become selected next (or nil).
    @discardableResult
    mutating func close(id: UUID) -> UUID? {
        guard let index = firstIndex(where: { $0.id == id }) else { return nil }
        remove(at: index)
        guard !isEmpty else { return nil }
        return self[Swift.min(index, count - 1)].id
    }
}
