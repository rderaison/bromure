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
        /// What that refused write says (Python's str(OSError)).
        var failMessage = "[Errno 5] Input/output error"
        var failRename = false
        var writes = 0

        func op(_ spec: [String: Any]) async throws -> [String: Any] {
            let kind = spec["op"] as? String ?? "", path = spec["path"] as? String ?? ""
            ops.append("\(kind) \((path as NSString).lastPathComponent)")
            switch kind {
            case "write":
                writes += 1
                if writes == failWrite { throw E(failMessage.replacingOccurrences(of: "{path}", with: path)) }
                let isTmp = (path as NSString).lastPathComponent.hasPrefix(".")
                if isTmp, let d = lockedDir, (path as NSString).deletingLastPathComponent == d, files[path] == nil {
                    throw E("[Errno 13] Permission denied: '\(path)'")
                }
                let data = Data(base64Encoded: spec["data"] as? String ?? "") ?? Data()
                files[path] = ((spec["append"] as? Bool) == true ? files[path] ?? Data() : Data()) + data
            case "rename":
                if failRename { throw E("[Errno 13] Permission denied") }
                files[spec["dest"] as! String] = files.removeValue(forKey: path)
            case "remove":
                files.removeValue(forKey: path)
            default: break
            }
            return ["ok": true]
        }
    }
    /// Like ACAppDelegate.GuestExecError.commandFailed: a LocalizedError whose
    /// description is the guest's message.
    struct E: LocalizedError, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
        var errorDescription: String? { description }
    }

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

    // Regression (CWE-20): the parser cut the message at `: '`, but Python
    // quotes a path holding an apostrophe with ", so the path stayed in and
    // its words counted. ENOSPC on `permission denied's.txt` read as a
    // refusal, and the direct-write fallback truncated the existing file.
    @Test("a double-quoted path's words never make a refusal")
    func doubleQuotedPath() {
        #expect(!FolderUpload.refusedByFilesystem(E(#"[Errno 28] No space left on device: "/d/.permission denied's.txt.bromure-abc.part""#)))
        #expect(!FolderUpload.refusedByFilesystem(E(#"[Errno 5] Input/output error: "/d/[Errno 13] it's""#)))
        #expect(!FolderUpload.refusedByFilesystem(E("unknown file op: Operation not permitted")))
        #expect(FolderUpload.refusedByFilesystem(E(#"[Errno 13] Permission denied: "/d/.it's.bromure-1.part""#)))
        #expect(FolderUpload.refusedByFilesystem(E("Operation not permitted")))     // a Sidecar Mac (strerror)
        #expect(FolderUpload.refusedByFilesystem(ACAppDelegate.GuestExecError.commandFailed(
            exitCode: 1, stderr: "[Errno 13] Permission denied: '/d/x'\n")))
        #expect(!FolderUpload.refusedByFilesystem(ACAppDelegate.GuestExecError.commandFailed(
            exitCode: 1, stderr: #"[Errno 28] No space left on device: "/d/permission denied's""#)))
    }

    // A fat client gets the remote Mac's error as commandFailed(stderr:); an
    // older Mac sent the guest's own commandFailed as an enum dump there.
    @Test("a guest's error inside an older host's enum dump is read by its start only")
    func olderHostDump() {
        typealias G = ACAppDelegate.GuestExecError
        func viaOldHost(_ guest: String) -> Error {
            G.commandFailed(exitCode: 1, stderr: String(describing: G.commandFailed(exitCode: 1, stderr: guest)))
        }
        #expect(FolderUpload.refusedByFilesystem(viaOldHost("[Errno 13] Permission denied: '/d/.bromure-1.part'")))
        #expect(!FolderUpload.refusedByFilesystem(viaOldHost(#"[Errno 28] No space left on device: "/permission denied's/.bromure-1.part""#)))
        #expect(!FolderUpload.refusedByFilesystem(viaOldHost(#"[Errno 5] Input/output error: "/d/[Errno 13] x""#)))
    }

    @Test("ENOSPC creating the temp in a double-quoted folder leaves the destination untouched")
    func noSpaceKeepsDestination() async throws {
        let g = Guest(); g.files["/permission denied's/f.txt"] = Data("old".utf8)
        g.failWrite = 1
        g.failMessage = #"[Errno 28] No space left on device: "{path}""#
        await #expect(throws: (any Error).self) {
            try await FolderUpload.write(try source("new"), to: "/permission denied's/f.txt", label: "f", op: g.op, progress: nil)
        }
        #expect(g.files["/permission denied's/f.txt"] == Data("old".utf8))
    }
}
