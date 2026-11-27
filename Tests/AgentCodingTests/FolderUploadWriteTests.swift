import Foundation
import Testing
@testable import bromure_ac

// FolderUpload.write goes through a temp sibling renamed over the
// destination. A writable file in a directory we may not write can't have a
// sibling created, so the upload failed where the old direct write worked.
// It now falls back to the direct write -- only when the guest refused the
// temp file's creation, never once part of it was written.
@Suite("FolderUpload.write: temp sibling, and its fallback")
struct FolderUploadWriteTests {
    final class Guest {
        var files: [String: Data] = [:]
        var ops: [String] = []
        /// Refuse a write to a path in this directory (no sibling may be made there).
        var lockedDir: String?
        /// Refuse the n-th write (1-based), whatever its path.
        var failWrite: Int?
        var failRename = false
        /// A guest agent from before `rename`.
        var noRename = false
        /// Run once, before the n-th write (1-based): another drop, say.
        var beforeWrite: (Int, (Guest) -> Void)?
        var writes = 0

        func op(_ spec: [String: Any]) async throws -> [String: Any] {
            let kind = spec["op"] as? String ?? "", path = spec["path"] as? String ?? ""
            ops.append("\(kind) \((path as NSString).lastPathComponent)")
            switch kind {
            case "read":
                guard let f = files[path] else { throw E("[Errno 2] No such file or directory: '\(path)'") }
                return ["data": "", "size": f.count, "eof": true, "exit_code": 0]
            case "write":
                writes += 1
                if let (n, act) = beforeWrite, n == writes { act(self) }
                if writes == failWrite { throw E("[Errno 5] Input/output error") }
                let isTmp = (path as NSString).lastPathComponent.hasPrefix(".")
                if isTmp, let d = lockedDir, (path as NSString).deletingLastPathComponent == d, files[path] == nil {
                    throw E("[Errno 13] Permission denied: '\(path)'")
                }
                let data = Data(base64Encoded: spec["data"] as? String ?? "") ?? Data()
                files[path] = ((spec["append"] as? Bool) == true ? files[path] ?? Data() : Data()) + data
            case "rename":
                if noRename { throw E("unknown file op 'rename'") }
                if failRename { throw E("[Errno 13] Permission denied") }
                files[spec["dest"] as! String] = files.removeValue(forKey: path)
            case "remove":
                files.removeValue(forKey: path)
            default: break
            }
            return ["ok": true]
        }
    }
    struct E: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    func source(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fu-\(UUID().uuidString)")
        try Data(s.utf8).write(to: u)
        return u
    }

    @Test("ordinary: through a temp sibling, renamed over")
    func viaTemp() async throws {
        let g = Guest(); g.files["/d/f"] = Data("old".utf8)
        try await FolderUpload.write(try source("new"), to: "/d/f", label: "f", op: g.op, progress: nil)
        #expect(g.files == ["/d/f": Data("new".utf8)])
        #expect(g.ops.contains { $0.hasPrefix("rename ") })
    }

    @Test("a directory we may not write: the file is written straight")
    func lockedDirectory() async throws {
        let g = Guest(); g.lockedDir = "/d"; g.files["/d/f"] = Data("old".utf8)
        try await FolderUpload.write(try source("new"), to: "/d/f", label: "f", op: g.op, progress: nil)
        #expect(g.files == ["/d/f": Data("new".utf8)])
        #expect(!g.ops.contains { $0.hasPrefix("rename ") })
    }

    @Test("a failure once the temp file was written isn't turned into a direct write")
    func partialStaysAFailure() async throws {
        let g = Guest(); g.files["/d/f"] = Data("old".utf8); g.failWrite = 2
        let big = String(repeating: "x", count: 7 << 20)
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source(big), to: "/d/f", label: "f", op: g.op, progress: nil)
        }
        #expect(g.files == ["/d/f": Data("old".utf8)], "the destination is untouched, the temp file gone")
    }

    @Test("a refused rename is a failure, not a fallback")
    func refusedRename() async throws {
        let g = Guest(); g.failRename = true; g.files["/d/f"] = Data("old".utf8)
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source("new"), to: "/d/f", label: "f", op: g.op, progress: nil)
        }
        #expect(g.files == ["/d/f": Data("old".utf8)])
    }

    @Test("a refusal is read from the message, not from the path it names")
    func refusalText() {
        #expect(FolderUpload.refusedByFilesystem(E("[Errno 13] Permission denied: '/d/.f.bromure-1.part'")))
        #expect(FolderUpload.refusedByFilesystem(E("[Errno 1] Operation not permitted: '/d/x'")))
        #expect(FolderUpload.refusedByFilesystem(E("Permission denied")))
        #expect(!FolderUpload.refusedByFilesystem(E("[Errno 28] No space left on device: '/d/permission-denied.txt'")))
        #expect(!FolderUpload.refusedByFilesystem(E("[Errno 130] Owner died: '/d/x'")))
    }

    // Regression (CWE-459): on a guest without `rename` the upload falls back
    // to writing the destination straight; a NEW destination that copy
    // created stayed under its final name, truncated, when it failed part-way.
    // The temp copy is 2 writes (7 MB), so the direct write's 2nd is the 4th.
    @Test("an old guest: a new file the direct write fails to fill is removed again")
    func legacyNewFileRemoved() async throws {
        let g = Guest(); g.noRename = true; g.failWrite = 4
        let big = String(repeating: "x", count: 7 << 20)
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source(big), to: "/d/new", label: "new", op: g.op, progress: nil)
        }
        #expect(g.files.isEmpty, "no truncated file, no temp file")
    }

    @Test("an old guest: a file that was there, or that another drop wrote over meanwhile, stays")
    func legacyOthersKept() async throws {
        let big = String(repeating: "x", count: 7 << 20)
        let g = Guest(); g.noRename = true; g.failWrite = 4; g.files["/d/f"] = Data("old".utf8)
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source(big), to: "/d/f", label: "f", op: g.op, progress: nil)
        }
        #expect(g.files["/d/f"] != nil)
        let h = Guest(); h.noRename = true; h.failWrite = 4
        h.beforeWrite = (4, { $0.files["/d/new"] = Data("someone else's".utf8) })
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source(big), to: "/d/new", label: "new", op: h.op, progress: nil)
        }
        #expect(h.files["/d/new"] == Data("someone else's".utf8))
    }
}
