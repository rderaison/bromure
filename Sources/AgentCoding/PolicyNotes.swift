import Foundation

/// PolicySteering's note files: one per note, in `policy-notes/` of a
/// workspace's read-only meta share, which the agents' hook claims and hands
/// to the model (see PolicySteeringDelivery). Where only the host can write:
/// a guest process could otherwise plant one. Shared by the macOS app and the
/// Linux daemon, which write them alike.
enum PolicyNotes {
    /// The notes' folder in the meta share (host side) and as the guest sees it.
    static let shareDir = "policy-notes"
    static let guestDir = "/mnt/bromure-meta/policy-notes"
    /// A note nobody's hook took within this long is dropped on the next write
    /// (a closed tab's index gets reused).
    static let lifetime: TimeInterval = 3600

    /// The non-Claude tabs a note is typed into (as the user's message — the
    /// only way those agents learn of a block). Never broadcast into every
    /// agent's composer: the tab whose process was blocked (`attributed`),
    /// else the only non-Claude agent there is — an L7, guardrails or
    /// unattributed sandbox block has no tab of its own, and that agent was
    /// told nothing (Finding CWE-670, "Unattributed policy notes are never
    /// typed into a non-Claude tab").
    static func typedWindows(targets: [(window: Int, tool: Profile.Tool)], attributed: Bool) -> [Int] {
        let others = targets.filter { $0.tool != .claude }.map(\.window)
        return attributed || others.count == 1 ? others : []
    }

    /// Write `text` as window `window`'s next note under `meta`'s notes
    /// folder, and drop the notes older than `lifetime`.
    @discardableResult
    static func drop(in meta: URL, window: Int, text: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = meta.appendingPathComponent(shareDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".note") {
            let f = dir.appendingPathComponent(name)
            if let at = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(at) > lifetime {
                try? fm.removeItem(at: f)
            }
        }
        let stamp = UInt64(now.timeIntervalSince1970 * 1_000_000_000)
        let name = "w\(window)-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).note"
        let tmp = dir.appendingPathComponent(".\(name).tmp")
        try Data((text + "\n").utf8).write(to: tmp)
        let dest = dir.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}
