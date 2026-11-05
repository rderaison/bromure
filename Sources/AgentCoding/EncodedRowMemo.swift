import Foundation

/// Each item's encoded row, kept while the item stays the same.
///
/// The state snapshot is rebuilt on the main thread twice a second for every
/// connected fat client, and encoding every delegation, session and task, all
/// their messages included, held the main thread near 95% on a busy server.
/// Comparing an item to the one encoded last time is a fraction of encoding it,
/// and almost all of them are unchanged from one snapshot to the next. Lists
/// are kept apart by key; an item no longer listed is forgotten.
final class EncodedRowMemo {
    private var memos: [String: Any] = [:]

    func rows<T: Equatable & Identifiable>(_ items: [T], _ key: String,
                                          encode: (T) -> [String: Any]?) -> [[String: Any]] {
        let old = memos[key] as? [T.ID: (value: T, row: [String: Any])] ?? [:]
        var next: [T.ID: (value: T, row: [String: Any])] = [:]
        next.reserveCapacity(items.count)
        var out: [[String: Any]] = []
        out.reserveCapacity(items.count)
        for item in items {
            if let hit = old[item.id], hit.value == item {
                next[item.id] = hit
                out.append(hit.row)
            } else if let row = encode(item) {
                next[item.id] = (item, row)
                out.append(row)
            }
        }
        memos[key] = next
        return out
    }
}
