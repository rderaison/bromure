import Foundation
import Testing

/// Finding: a batch merge left Git conflict markers in all eight Agent
/// Coding Localizable.strings — Foundation kept the entries above the
/// marker and dropped the rest, so those strings showed untranslated, and
/// nothing failed: a marker in Swift breaks the build, in a resource it
/// ships. These check what ships, not one file.
@Suite("Shipped resources: no merge leftovers")
struct ResourceIntegrityTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private static func files(where keep: (URL) -> Bool) -> [URL] {
        guard let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && keep($0)
        }
    }

    /// Foundation's reader is lenient: past a line it can't read it drops
    /// the rest and still hands back a table (the German catalog with the
    /// markers loaded 3838 of its 3846 entries — "Sending…" untranslated).
    /// So "it parses" proves nothing: every entry written must be read.
    @Test("every strings catalog loads whole: each entry written is one read")
    func catalogsParse() throws {
        let catalogs = Self.files { $0.pathExtension == "strings" }
        #expect(catalogs.count >= 16)   // AgentCoding + Browser, 8 locales each
        for url in catalogs {
            let data = try Data(contentsOf: url)
            let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            #expect(table != nil, "\(url.path) doesn't parse")
            // Entries are one per line here: `"key" = "value";`.
            let written = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Substring? in
                guard line.hasPrefix("\""), let r = line.range(of: "\" = \"") else { return nil }
                return line[line.index(after: line.startIndex)..<r.lowerBound]
            })
            #expect(written.count > 0, "\(url.path) is empty")
            #expect(table?.count == written.count,
                    "\(url.path): \(written.count) entries written, \(table?.count ?? 0) read — the rest are dropped")
        }
    }

    @Test("no text file under Sources carries a conflict marker")
    func noConflictMarkers() throws {
        // Only the unambiguous halves: "=======" alone is also a Markdown rule.
        let markers = ["<<<<<<< ", ">>>>>>> "]
        var hits: [String] = []
        for url in Self.files(where: { _ in true }) {
            guard let data = try? Data(contentsOf: url), data.count < 8_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }   // binaries
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where markers.contains(where: { line.hasPrefix($0) }) {
                hits.append("\(url.path):\(i + 1)")
            }
        }
        #expect(hits.isEmpty, "conflict markers: \(hits.prefix(10).joined(separator: ", "))")
    }
}
