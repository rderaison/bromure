import Foundation

/// Window launches whose VM failed to boot for want of a network, each to be
/// reopened once on the next host network change. Keyed per launch (a launch
/// keeps its ID across its own retries): one launch failing or opening never
/// replaces or drops another's retry — and with it the link that launch was
/// opening.
public struct NetworkRetryQueue {
    private var pending: [(id: UUID, retry: () -> Void)] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Registers (or replaces) this launch's retry, keeping launch order.
    public mutating func register(_ id: UUID, _ retry: @escaping () -> Void) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending[index].retry = retry
        } else {
            pending.append((id, retry))
        }
    }

    /// Whether this launch still awaits its retry (nil once a network change
    /// already ran it, or its window opened).
    public func contains(_ id: UUID) -> Bool {
        pending.contains { $0.id == id }
    }

    /// Drops this launch's retry: its window opened, or it is retrying now.
    public mutating func cancel(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// Every pending retry, oldest first, leaving the queue empty. A retry
    /// that fails again re-registers under its own ID.
    public mutating func takeAll() -> [() -> Void] {
        defer { pending.removeAll() }
        return pending.map(\.retry)
    }
}
