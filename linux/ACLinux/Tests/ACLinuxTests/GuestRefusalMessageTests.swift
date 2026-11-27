import Foundation
import Testing
@testable import ACLinux

/// A guest's refusal must reach whoever reads it as the guest said it, from
/// its first character: an upload falls back to a direct write only when the
/// error starts `[Errno 13] …` or `[Errno 1] …` (FolderUpload.
/// refusedByFilesystem; the web client's permissionDenied reads `POST
/// /vms/<id>/file`'s `error` the same way). The daemon's own error put
/// "exit 1: " before it, so neither ever matched on a Linux server.
@Suite("Guest refusal messages")
struct GuestRefusalMessageTests {
    typealias E = Daemon.GuestCommandError

    @Test func theGuestsMessageIsTheErrorsDescription() {
        let refused = E.failed(exitCode: 1, stderr: "[Errno 13] Permission denied: '/srv/app/.x.bromure-upload-1'\n")
        #expect(refused.errorDescription == "[Errno 13] Permission denied: '/srv/app/.x.bromure-upload-1'")
        #expect(refused.localizedDescription == "[Errno 13] Permission denied: '/srv/app/.x.bromure-upload-1'")
        #expect(E.failed(exitCode: 3, stderr: "  \n").errorDescription == "Command failed (exit 3)")
        #expect(E.unavailable("the workspace isn't running").errorDescription == "the workspace isn't running")
        // What logs and command output print is unchanged.
        #expect("\(refused)" == "exit 1: [Errno 13] Permission denied: '/srv/app/.x.bromure-upload-1'")
    }

    @Test func anUploadReadsAFilesystemRefusalOffIt() {
        #expect(FolderUpload.refusedByFilesystem(E.failed(exitCode: 1, stderr: "[Errno 13] Permission denied: '/srv/x'")))
        #expect(FolderUpload.refusedByFilesystem(E.failed(exitCode: 1, stderr: "[Errno 1] Operation not permitted: '/srv/x'")))
        #expect(!FolderUpload.refusedByFilesystem(E.failed(exitCode: 1, stderr: "[Errno 28] No space left on device")))
        #expect(!FolderUpload.refusedByFilesystem(E.failed(exitCode: 1, stderr: "unknown file op: rename")))
        #expect(!FolderUpload.refusedByFilesystem(E.unavailable("the workspace isn't running")))
    }

    /// An upload into a folder that refuses a new file, through the guest
    /// file operations as the daemon reports them: the temp-file write is
    /// refused, and the file is then written straight to its place.
    @Test func aFolderThatTakesNoNewFileGetsTheDirectWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.txt")
        try Data("hello".utf8).write(to: src)
        let dest = "/srv/app/config.txt"
        final class Guest: @unchecked Sendable {
            var writes: [String] = []
            var content = Data()
        }
        let guest = Guest()
        let op: FolderUpload.FileOp = { o in
            let path = o["path"] as? String ?? ""
            switch o["op"] as? String {
            case "write":
                guest.writes.append(path)
                // Only the destination itself may be written: no new name beside it.
                guard path == dest else { throw E.failed(exitCode: 1, stderr: "[Errno 13] Permission denied: '\(path)'") }
                let data = Data(base64Encoded: o["data"] as? String ?? "") ?? Data()
                if o["append"] as? Bool == true { guest.content.append(data) } else { guest.content = data }
                return [:]
            case "stat":
                return ["exists": true, "size": guest.content.count]
            default:
                return [:]
            }
        }
        try await FolderUpload.write(src, to: dest, label: "config.txt", op: op, progress: nil)
        #expect(guest.content == Data("hello".utf8))
        #expect(guest.writes.count == 2 && guest.writes.last == dest, "\(guest.writes)")
        #expect(guest.writes.first?.hasPrefix("/srv/app/.") == true, "the temp name beside it was tried first: \(guest.writes)")
    }

    // The staged first write (CWE-200), as macOS's GuestDropTests has it.
    @Test func onlyAStagedFilesFirstWriteSaysSo() {
        let data = Data(count: 6 * 1024 * 1024 * 2 + 1)   // writeChunk (6 MB) × 2, plus one
        let ops = GuestDrop.writeOps(guestPath: "/tmp/a.tgz", data: data, staged: true)
        #expect(ops.count == 3)
        #expect(ops[0]["staged"] as? Bool == true)
        #expect(ops.dropFirst().allSatisfy { $0["staged"] == nil })
        #expect(GuestDrop.writeOps(guestPath: "/tmp/a", data: data).allSatisfy { $0["staged"] == nil })
    }
}
