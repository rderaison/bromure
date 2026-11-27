import Testing
import Foundation
import Darwin
@testable import bromure_ac

// Regression (CWE-459): an upload whose rename fell back to writing the
// destination in place (a symlink's target on another filesystem, a busy or
// hard-linked file) left it half new, half old when the copy failed part-way
// — a full disk, a read error — while the upload reported the error.
@Suite("A failed in-place upload leaves the destination as it was", .serialized)
struct UploadFailedCopyTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("failcopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Runs `body` with bromure-agentd loaded as `m`, `d` a scratch folder,
    /// and `fail_after(path, n)`: copies out of `path` stop with ENOSPC once
    /// `n` bytes went (a disk that fills up part-way).
    private func agentd(_ body: String, in d: URL) throws -> (Int32, String) {
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, errno, shutil
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            real_copy = shutil.copyfileobj
            def fail_after(path, n):
                def copy(src, dst, length=0):
                    if getattr(src, 'name', None) == path:
                        dst.write(src.read(n))
                        raise OSError(errno.ENOSPC, 'No space left on device')
                    return real_copy(src, dst, length)
                m.shutil.copyfileobj = copy
            def stage(name, data):
                p = os.path.join(d, name); open(p, 'w').write(data); return p
            def leftovers():
                return sorted(f for f in os.listdir(d) if f.startswith('.bromure-'))

            """ + body, Self.agentd.path, d.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        return (py.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test("A hard-linked file whose in-place copy fails part-way keeps its old bytes",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func hardLinkedFullDisk() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            dest = stage('f', 'old data, the original'); os.link(dest, os.path.join(d, 'other'))
            staged = stage('.f.part', 'NEW DATA, the replacement, longer')
            fail_after(staged, 4)
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1 and 'No space' in r['error'], r
            assert open(dest).read() == 'old data, the original', open(dest).read()
            assert open(os.path.join(d, 'other')).read() == 'old data, the original'
            assert leftovers() == [], leftovers()
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }

    @Test("Across filesystems the upload is staged beside the target and renamed: a failed copy touches nothing",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func crossDevice() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            real_replace = os.replace
            def xdev_from_staged(a, b):
                # Only the staged file is "on another filesystem".
                if os.path.basename(a).startswith('.up'):
                    raise OSError(errno.EXDEV, 'Invalid cross-device link')
                return real_replace(a, b)
            m.os.replace = xdev_from_staged
            dest = stage('f', 'old data, the original')
            ino = os.stat(dest).st_ino
            staged = stage('.up1.part', 'NEW DATA, the replacement')
            fail_after(staged, 4)
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1, r
            assert open(dest).read() == 'old data, the original'
            assert leftovers() == [], leftovers()
            m.shutil.copyfileobj = real_copy
            # And when it goes: one rename from beside the target.
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r == {'exit_code': 0}, r
            assert open(dest).read() == 'NEW DATA, the replacement'
            assert os.stat(dest).st_ino != ino
            assert not os.path.exists(staged) and leftovers() == [], leftovers()
            # A new file the same way.
            staged = stage('.up2.part', 'fresh')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'new')})
            assert r == {'exit_code': 0}, r
            assert open(os.path.join(d, 'new')).read() == 'fresh' and leftovers() == []
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }

    @Test("A new file that can't be staged beside its target and fails part-way is removed again",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func newFileFails() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            dest = os.path.join(d, 'new')
            staged = stage('.f.part', 'NEW DATA')
            fail_after(staged, 3)
            try:
                m._write_in_place(staged, dest, create=True)
                assert False, 'no error'
            except OSError as e:
                assert e.errno == errno.ENOSPC
            assert not os.path.exists(dest)
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }

    @Test("Mac: a hard-linked file whose new bytes can't be read keeps its old ones, no copy left behind")
    func macReadErrorRestores() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let dest = d.appendingPathComponent("f"), other = d.appendingPathComponent("other")
        try "old data".write(to: dest, atomically: false, encoding: .utf8)
        #expect(link(dest.path, other.path) == 0)
        // A folder where the staged file should be: it opens, but reads fail.
        let staged = d.appendingPathComponent(".f.part")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) != nil)
        #expect((try? String(contentsOf: dest, encoding: .utf8)) == "old data")
        let left = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasPrefix(".bromure-") }
        #expect(left.isEmpty)
    }

    // Regression (CWE-459): a write the volume deferred (a full or remote
    // one) is only reported at the flush or the close; the copy's close
    // error was dropped and the target replaced by an incomplete file.
    @Test("Across filesystems: a copy whose flush to disk fails leaves the target untouched",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func crossDeviceFlushFails() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            real_replace = os.replace
            def xdev_from_staged(a, b):
                if os.path.basename(a).startswith('.up'):
                    raise OSError(errno.EXDEV, 'Invalid cross-device link')
                return real_replace(a, b)
            m.os.replace = xdev_from_staged
            def no_room(fd): raise OSError(errno.EIO, 'Input/output error')
            m.os.fsync = no_room
            dest = stage('f', 'old data, the original')
            staged = stage('.up1.part', 'NEW DATA, the replacement')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1 and 'Input/output' in r['error'], r
            assert open(dest).read() == 'old data, the original'
            assert leftovers() == [], leftovers()
            # A new file the same way: none left behind.
            staged = stage('.up2.part', 'fresh')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'new')})
            assert r['exit_code'] == 1, r
            assert not os.path.exists(os.path.join(d, 'new')) and leftovers() == [], leftovers()
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }

    @Test("In place: a backup whose flush to disk fails stops the upload before the target is touched",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func backupFlushFails() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            dest = stage('f', 'old data, the original'); os.link(dest, os.path.join(d, 'other'))
            def no_room(fd): raise OSError(errno.EIO, 'Input/output error')
            m.os.fsync = no_room
            staged = stage('.f.part', 'NEW DATA')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1, r
            assert open(dest).read() == 'old data, the original'
            assert leftovers() == [], leftovers()
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }

    @Test("Mac: a copy isn't complete until its flush and close say so")
    func macFinishReportsFailure() throws {
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

    @Test("In place: a write whose flush to disk fails gets the old bytes back",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func inPlaceFlushFails() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let (status, err) = try agentd("""
            dest = stage('f', 'old data, the original'); os.link(dest, os.path.join(d, 'other'))
            real_fsync = os.fsync
            def fail_on_dest(fd):
                if os.fstat(fd).st_ino == os.stat(dest).st_ino:
                    raise OSError(errno.EIO, 'Input/output error')
                return real_fsync(fd)
            m.os.fsync = fail_on_dest
            staged = stage('.f.part', 'NEW DATA, longer than before')
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': dest})
            assert r['exit_code'] == 1, r
            assert open(dest).read() == 'old data, the original', open(dest).read()
            assert leftovers() == [], leftovers()
            """, in: d)
        #expect(status == 0, Comment(rawValue: err))
    }
}
