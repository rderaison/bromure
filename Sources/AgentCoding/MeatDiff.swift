import Foundation

// MARK: - Unified-diff model for the reading-diff review UI
//
// meat prints an abridged unified diff plus a one-line summary. To render it
// the way a review tool does — per-file cards, ± counts, two line-number
// gutters — we parse that diff, and we parse the FULL `git diff` alongside it
// so the header can say how much was dropped ("kept 59/106 changed lines in
// 2/3 files"). That ratio is the whole point of meat, so it's worth computing
// rather than just showing the abridged text.

struct MeatDiff: Equatable {
    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case context, added, removed, hunk, meta }
        let id = UUID()
        let kind: Kind
        /// Line numbers in the old / new file. nil on the side a line doesn't
        /// exist in (an addition has no old number, and vice versa).
        let oldNumber: Int?
        let newNumber: Int?
        let text: String

        static func == (a: Line, b: Line) -> Bool {
            a.kind == b.kind && a.oldNumber == b.oldNumber
                && a.newNumber == b.newNumber && a.text == b.text
        }
    }

    struct File: Equatable, Identifiable {
        var id: String { path }
        var path: String
        var lines: [Line]
        var added: Int
        var removed: Int

        /// Split for display: dimmed directory, bold basename.
        var directory: String {
            guard let i = path.lastIndex(of: "/") else { return "" }
            return String(path[..<path.index(after: i)])
        }
        var basename: String {
            guard let i = path.lastIndex(of: "/") else { return path }
            return String(path[path.index(after: i)...])
        }
    }

    var files: [File]
    /// meat's prose summary — the non-diff text it prints alongside.
    var summary: String

    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }
    var changedLines: Int { totalAdded + totalRemoved }

    static let empty = MeatDiff(files: [], summary: "")

    // MARK: Parse

    /// Parse a unified diff. Anything before the first `diff --git` / `---`
    /// header is treated as prose (meat prints its summary there).
    static func parse(_ text: String) -> MeatDiff {
        var files: [File] = []
        var preamble: [String] = []
        var current: File?
        var oldNo = 0, newNo = 0
        var sawFirstFile = false

        func flush() {
            if let c = current, !c.lines.isEmpty { files.append(c) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            // New file section. `diff --git a/x b/x` is authoritative; a bare
            // `+++ b/x` also starts one for diffs without the git header.
            if line.hasPrefix("diff --git ") {
                flush()
                sawFirstFile = true
                current = File(path: pathFromGitHeader(line), lines: [], added: 0, removed: 0)
                continue
            }
            if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4))
                    .replacingOccurrences(of: "b/", with: "", options: .anchored)
                if current == nil {
                    flush()
                    sawFirstFile = true
                    current = File(path: p, lines: [], added: 0, removed: 0)
                } else if current?.path.isEmpty ?? false {
                    current?.path = p
                }
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename ") {
                continue                                     // header noise
            }

            if line.hasPrefix("@@") {
                guard current != nil else { continue }
                let (o, n) = hunkStarts(line)
                oldNo = o; newNo = n
                current?.lines.append(Line(kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
                continue
            }

            guard current != nil else {
                if !sawFirstFile { preamble.append(line) }
                continue
            }

            if line.hasPrefix("+") {
                current?.lines.append(Line(kind: .added, oldNumber: nil, newNumber: newNo,
                                           text: String(line.dropFirst())))
                current?.added += 1
                newNo += 1
            } else if line.hasPrefix("-") {
                current?.lines.append(Line(kind: .removed, oldNumber: oldNo, newNumber: nil,
                                           text: String(line.dropFirst())))
                current?.removed += 1
                oldNo += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                current?.lines.append(Line(kind: .meta, oldNumber: nil, newNumber: nil, text: line))
            } else {
                let body = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                current?.lines.append(Line(kind: .context, oldNumber: oldNo, newNumber: newNo,
                                           text: body))
                oldNo += 1
                newNo += 1
            }
        }
        flush()

        let summary = preamble.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MeatDiff(files: files, summary: summary)
    }

    /// `diff --git a/path b/path` → path. Handles paths with spaces by taking
    /// the `b/` half, which is what the file is called after the change.
    private static func pathFromGitHeader(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        if let r = rest.range(of: " b/") {
            return String(rest[r.upperBound...])
        }
        return rest.split(separator: " ").last.map {
            String($0).replacingOccurrences(of: "b/", with: "", options: .anchored)
        } ?? rest
    }

    /// `@@ -36,6 +36,11 @@ ctx` → (36, 36).
    private static func hunkStarts(_ line: String) -> (Int, Int) {
        var old = 0, new = 0
        let parts = line.split(separator: " ")
        for p in parts {
            if p.hasPrefix("-"), let v = Int(p.dropFirst().split(separator: ",")[0]) { old = v }
            if p.hasPrefix("+"), let v = Int(p.dropFirst().split(separator: ",")[0]) { new = v }
        }
        return (old, new)
    }
}

/// How much meat dropped — the headline stat on the review pane.
struct MeatReduction: Equatable {
    let keptLines: Int
    let totalLines: Int
    let keptFiles: Int
    let totalFiles: Int

    /// "kept 59/106 changed lines in 2/3 files"
    var caption: String {
        guard totalLines > 0 else { return "no changes" }
        return "kept \(keptLines)/\(totalLines) changed lines in \(keptFiles)/\(totalFiles) files"
    }

    static func between(abridged: MeatDiff, full: MeatDiff) -> MeatReduction {
        MeatReduction(keptLines: abridged.changedLines,
                      totalLines: max(full.changedLines, abridged.changedLines),
                      keptFiles: abridged.files.count,
                      totalFiles: max(full.files.count, abridged.files.count))
    }
}
