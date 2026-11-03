import Foundation

/// The streams the Sidecar's delegation hub answers locally (no Bromure AC
/// relay parked), and which one a newly parked relay is for. Shared with
/// Bromure AC's tests (the Sidecar target has none).
///
/// One park is one offer — the relay client dials its next slot only once
/// that one is taken — so it's reserved for the one stream it kicks: a
/// stream holding a call first (the oldest), else the oldest. The others
/// keep their place and their wait. Before, every stream holding a call took
/// any offer as its own and closed: all their shims reconnected at once, one
/// got the relay, the rest landed back here and were refused 20 s later
/// while a relay was up.
struct DelegationFallbacks {
    /// Oldest first.
    private(set) var streams: [Int32] = []
    /// Streams holding a call for a relay, in the order they started.
    private var holding: [Int32] = []

    mutating func add(_ fd: Int32) { streams.append(fd) }

    /// The stream ended (its fd is closed right after: the number may come
    /// back for another stream).
    mutating func remove(_ fd: Int32) {
        streams.removeAll { $0 == fd }
        holding.removeAll { $0 == fd }
    }

    mutating func hold(_ fd: Int32) {
        guard streams.contains(fd), !holding.contains(fd) else { return }
        holding.append(fd)
    }

    mutating func release(_ fd: Int32) { holding.removeAll { $0 == fd } }

    /// A relay parked: the stream it's for, taken off the list (its shim
    /// reconnects onto it). nil: nobody's here.
    mutating func kick() -> Int32? {
        guard let fd = holding.first ?? streams.first else { return nil }
        remove(fd)
        return fd
    }

    /// Whether a park picked `fd` (it's no longer listed, though its stream
    /// is still open — its number can't have been reused).
    func kicked(_ fd: Int32) -> Bool { !streams.contains(fd) }
}
