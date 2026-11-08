import Foundation

/// An agent-tool-<win>.jsonl (the hooks append one line per tool call),
/// read a window at a time from where the last read stopped. Shared by the
/// macOS sandbox's outbox poll and the Linux daemon's.
struct AgentToolLog {
    var offset = 0
    /// A fully read, large log renamed out of the way: its tail is read
    /// once more (an append in flight when it moved lands there), then
    /// it's deleted.
    var retired: (url: URL, offset: Int)?

    static let window = 64 << 10
    /// Unread backlog past this is skipped, not loaded.
    static let backlogCap = 1 << 20
    static let rotateAt = 256 << 10
    static let maxLine = 8192

    /// The complete new lines (each ≤ maxLine) in `url` since the last call.
    mutating func read(_ url: URL) -> [Data] {
        var lines: [Data] = []
        if let r = retired {
            var o = r.offset
            lines += Self.lines(at: r.url, offset: &o)
            try? FileManager.default.removeItem(at: r.url)
            retired = nil
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        else { return lines }
        if size < offset { offset = 0 }                     // replaced under us
        if size - offset > Self.backlogCap { offset = size } // a flood: skipped, never loaded
        lines += Self.lines(at: url, offset: &offset)
        if offset == size, size > Self.rotateAt {
            // Rename, not truncate: a hook appending right now writes into
            // the renamed file, whose tail the next call reads.
            let moved = url.appendingPathExtension("retired")
            try? FileManager.default.removeItem(at: moved)
            if (try? FileManager.default.moveItem(at: url, to: moved)) != nil {
                retired = (moved, offset)
                offset = 0
            }
        }
        return lines
    }

    /// Up to one window of complete lines from `offset`, advancing it.
    static func lines(at url: URL, offset: inout Int) -> [Data] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil,
              let d = try? h.read(upToCount: window), !d.isEmpty else { return [] }
        guard let lastNL = d.lastIndex(of: 0x0A) else {
            // A full window with no newline is one oversized line: skip it.
            if d.count == window { offset += d.count }
            return []
        }
        offset += lastNL + 1
        return d[...lastNL].split(separator: 0x0A).filter { $0.count <= maxLine }.map { Data($0) }
    }

    /// What the host takes from the outbox's agent/ folder: a hook's tab
    /// status or tool-call log, nothing named like the outbox's own signals.
    static func isAgentHookFile(_ name: String) -> Bool {
        (name.hasPrefix("agent-status-") && name.hasSuffix(".txt"))
            || (name.hasPrefix("agent-tool-") && name.hasSuffix(".jsonl"))
    }
}
