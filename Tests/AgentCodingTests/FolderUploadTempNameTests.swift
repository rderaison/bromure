import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// Regression: FolderUpload.write staged a file at `.<name>.bromure-<UUID>.part`
/// — 51 bytes longer than its name, so a valid name over ~204 bytes made the
/// first write fail with ENAMETOOLONG (255-byte path components). The temp
/// name is now fixed-length, independent of the destination's.
@Suite("FolderUpload temp name")
struct FolderUploadTempNameTests {
    private final class Log: @unchecked Sendable { var paths: [String] = [] }

    @Test("A long valid name gets a temp name within the 255-byte limit")
    func longName() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("tmpname-\(UUID().uuidString)")
        try Data("hi".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let log = Log()
        let dest = "/home/ubuntu/" + String(repeating: "n", count: 250)
        try await FolderUpload.write(src, to: dest, label: "n", op: { op in
            if op["op"] as? String == "write", let p = op["path"] as? String { log.paths.append(p) }
            return [:]
        }, progress: nil)
        let tmp = try #require(log.paths.first)
        #expect((tmp as NSString).deletingLastPathComponent == "/home/ubuntu")
        #expect((tmp as NSString).lastPathComponent.utf8.count <= 255)
        #expect((tmp as NSString).lastPathComponent.hasPrefix(".bromure-"))
    }
}
