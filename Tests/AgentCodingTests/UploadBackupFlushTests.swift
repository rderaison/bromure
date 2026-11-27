import Testing
import Foundation
import Darwin
@testable import bromure_ac

// Regression (CWE-459): the in-place upload's backup of the old bytes was
// marked usable without its close being checked. A write the volume
// deferred (a full or remote one) fails only at the flush or the close: the
// backup could be cut short, and a failed write then "restored" the wrong
// bytes into the target and deleted the backup.
@Suite("An in-place upload's backup is only used once it's complete", .serialized)
struct UploadBackupFlushTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bkflush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("bromure-agentd: a backup whose flush to disk fails stops the upload before the target is touched",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestBackupFlushFails() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, errno
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            dest = os.path.join(d, 'f'); open(dest, 'w').write('old data, the original')
            os.link(dest, os.path.join(d, 'other'))            # hard-linked: written in place
            def no_room(fd): raise OSError(errno.EIO, 'Input/output error')
            m.os.fsync = no_room
            staged = os.path.join(d, '.f.part'); open(staged, 'w').write('NEW DATA')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1, r
            assert open(dest).read() == 'old data, the original', open(dest).read()
            assert not [f for f in os.listdir(d) if f.startswith('.bromure-')]
            """, Self.agentd.path, d.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        #expect(py.terminationStatus == 0,
                Comment(rawValue: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
    }

    @Test("Mac: a copy isn't complete until its flush and close say so")
    func finishReportsFailure() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let path = d.appendingPathComponent("f").path
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try h.write(contentsOf: Data("x".utf8))
        #expect(StagedReplace.finish(h) == nil)
        // A descriptor the flush can't complete on: reported, not dropped.
        let g = FileHandle(fileDescriptor: open(path, O_WRONLY), closeOnDealloc: false)
        close(g.fileDescriptor)
        #expect(StagedReplace.finish(g) != nil)
    }
}
