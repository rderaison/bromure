import Foundation
import Testing
@testable import bromure_ac

/// Regression (CWE-20): a guest's file-op reply is JSON it chose. A size of
/// 1e100 is a valid JSON number, decoded as a Double no Int holds, and
/// `Int(Double)` traps — the host app died on it. Such a size is now no size.
@Suite("A guest's out-of-range numbers never trap")
struct GuestNumberRangeTests {
    /// What JSONSerialization would hand over for each, plus the plain forms.
    static let hostile: [Any] = [1e100, -1e100, Double.infinity, Double.nan, 2.5, -1,
                                 NSNumber(value: 1e100), NSNumber(value: -3)]

    @Test("legacy upload: a hostile size reads as none — the upload fails cleanly, nothing removed")
    func folderUploadLegacy() async throws {
        for size in Self.hostile {
            var removed: [String] = []
            var writes = 0
            let op: FolderUpload.FileOp = { spec in
                switch spec["op"] as? String {
                case "rename": throw E("unknown file op 'rename'")
                case "read": return ["size": size, "exit_code": 0]
                case "write":
                    writes += 1
                    // The temp copy is one write; the direct write's first fails.
                    if writes == 2 { throw E("[Errno 5] Input/output error") }
                    return ["exit_code": 0]
                case "remove": removed.append(spec["path"] as? String ?? ""); return ["exit_code": 0]
                default: return ["exit_code": 0]
                }
            }
            let src = FileManager.default.temporaryDirectory.appendingPathComponent("gn-\(UUID().uuidString)")
            try Data("new".utf8).write(to: src)
            await #expect(throws: (any Error).self) {
                try await FolderUpload.write(src, to: "/d/f", label: "f", op: op, progress: nil)
            }
            // Only the temp file's own cleanup: the destination's size was
            // unreadable, so it's never taken for this copy's.
            #expect(!removed.contains("/d/f"), "size \(size)")
        }
    }

    @Test("a shown file: a hostile size reads as none")
    func displayReader() async {
        for size in Self.hostile {
            let reader = DisplayFileReader(read: { _, _ in nil }, op: { _ in ["size": size, "exit_code": 0] })
            #expect(await reader.size("/f") == nil, "size \(size)")
        }
        let ok = DisplayFileReader(read: { _, _ in nil }, op: { _ in ["size": NSNumber(value: 42), "exit_code": 0] })
        #expect(await ok.size("/f") == 42)
    }

    struct E: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
}
