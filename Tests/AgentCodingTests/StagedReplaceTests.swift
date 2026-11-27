import Testing
import Foundation
import Darwin
@testable import bromure_ac

// Regression: an upload's atomic replace (the file op `rename`, in HostExec
// and bromure-agentd.py) carried only the destination's mode bits over and
// renamed a new inode onto it, dropping its owner, ACL and extended
// attributes, and splitting it from its other hard links.
@Suite("Staged upload replace keeps the file's metadata", .serialized)
struct StagedReplaceTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ s: String, _ u: URL) throws { try s.write(to: u, atomically: false, encoding: .utf8) }
    private func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    private func xattr(_ u: URL, _ name: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = getxattr(u.path, name, &buf, buf.count, 0, 0)
        return n < 0 ? nil : String(decoding: buf[..<n], as: UTF8.self)
    }
    private func setX(_ u: URL, _ name: String, _ v: String) {
        _ = v.withCString { setxattr(u.path, name, $0, strlen($0), 0, 0) }
    }
    private func ino(_ u: URL) -> UInt64 { var st = stat(); stat(u.path, &st); return st.st_ino }
    private func acl(_ u: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ls")
        p.arguments = ["-le", u.path]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("A new destination is the staged file, renamed")
    func newDest() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        #expect(read(dest) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("An existing file keeps its mode, ACL and extended attributes")
    func keepsMetadata() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("old", dest)
        chmod(dest.path, 0o640)
        setX(dest, "com.bromure.test", "tag")
        let chmodACL = Process()
        chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "everyone deny chown", dest.path]
        try chmodACL.run(); chmodACL.waitUntilExit()
        #expect(acl(dest).contains("deny chown"))
        try write("new", staged)
        setX(staged, "com.bromure.stray", "x")
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        #expect(read(dest) == "new")
        var st = stat(); stat(dest.path, &st)
        #expect(st.st_mode & 0o7777 == 0o640)
        #expect(xattr(dest, "com.bromure.test") == "tag")
        #expect(xattr(dest, "com.bromure.stray") == nil)
        #expect(acl(dest).contains("deny chown"))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("A file whose ACL lets it be written, not deleted, is updated in place")
    func aclDeniesDelete() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("old contents", dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "everyone deny delete", dest.path]
        try p.run(); p.waitUntilExit()
        let before = ino(dest)
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        #expect(read(dest) == "new" && ino(dest) == before)
        #expect(acl(dest).contains("deny delete"))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let undo = Process()
        undo.executableURL = URL(fileURLWithPath: "/bin/chmod")
        undo.arguments = ["-N", dest.path]
        try undo.run(); undo.waitUntilExit()
    }

    @Test("A hard-linked file gets the new bytes in place: every link sees them")
    func hardLink() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        let other = d.appendingPathComponent("other")
        try write("old contents, longer", dest)
        #expect(link(dest.path, other.path) == 0)
        let before = ino(dest)
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        #expect(read(dest) == "new" && read(other) == "new")
        #expect(ino(dest) == before)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("bromure-agentd's twin: mode kept, a hard-linked file in place",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestTwin() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let dest = d.appendingPathComponent("f"), other = d.appendingPathComponent("other")
        let plain = d.appendingPathComponent("plain")
        try write("old contents, longer", dest)
        #expect(link(dest.path, other.path) == 0)
        try write("old", plain)
        chmod(plain.path, 0o640)
        let before = ino(dest)
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            for name in ('f', 'plain'):
                staged = os.path.join(d, '.' + name + '.part')
                open(staged, 'w').write('new')
                r = m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, name)})
                assert r == {'exit_code': 0}, r
                assert not os.path.exists(staged)
            """, Self.agentd.path, d.path]
        try py.run(); py.waitUntilExit()
        #expect(py.terminationStatus == 0)
        #expect(read(dest) == "new" && read(other) == "new" && ino(dest) == before)
        var st = stat(); stat(plain.path, &st)
        #expect(read(plain) == "new" && st.st_mode & 0o7777 == 0o640)
    }

    // Regression (CWE-732): a new file from an upload got 0644, the usual
    // umask's mode, whatever the process's own: under umask 077 a plain
    // write gives 0600, the upload a world-readable file.
    private func leftovers(_ d: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix(".bromure-") }
    }

    @Test("A new file gets the mode a plain write would under the process's umask, 077 included")
    func newFileHonorsUmask() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let old = umask(0o077)
        var restored = false
        defer { if !restored { umask(old) } }
        let tight = StagedReplace.newFileMode(in: d.path)
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("new", staged)
        chmod(staged.path, 0o600)
        let r = StagedReplace.replace(staged.path, onto: dest.path)
        umask(old); restored = true
        #expect(tight == 0o600)
        #expect(r == nil)
        var st = stat(); stat(dest.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(leftovers(d).isEmpty)
        // The usual umask: what a plain write gives.
        #expect(StagedReplace.newFileMode(in: d.path) == 0o666 & ~old)
    }

    @Test("bromure-agentd: a new file under umask 077 stays owner-only",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestNewFileHonorsUmask() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            os.umask(0o077)
            staged = os.path.join(d, '.f.part'); open(staged, 'w').write('new'); os.chmod(staged, 0o600)
            assert m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'f')}) == {'exit_code': 0}
            assert os.stat(os.path.join(d, 'f')).st_mode & 0o777 == 0o600, oct(os.stat(os.path.join(d, 'f')).st_mode)
            os.umask(0o022)
            staged = os.path.join(d, '.g.part'); open(staged, 'w').write('new'); os.chmod(staged, 0o600)
            assert m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'g')}) == {'exit_code': 0}
            assert os.stat(os.path.join(d, 'g')).st_mode & 0o777 == 0o644
            assert not [f for f in os.listdir(d) if f.startswith('.bromure-')]
            """, Self.agentd.path, d.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        #expect(py.terminationStatus == 0, Comment(rawValue: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
    }

    // Regression (CWE-732): the in-place fallback read the staged file after
    // the destination's mode had been copied onto it, and opened the
    // destination for reading too — a write-only (0200) file, which a plain
    // upload can replace, failed with "permission denied".
    private func chmodOwnerRead(_ u: URL) { chmod(u.path, 0o600) }

    @Test("A write-only hard-linked file is replaced in place, its mode kept")
    func writeOnlyHardLink() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("old contents, longer", dest)
        #expect(link(dest.path, d.appendingPathComponent("other").path) == 0)
        #expect(chmod(dest.path, 0o200) == 0)
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        var st = stat(); stat(dest.path, &st)
        #expect(st.st_mode & 0o7777 == 0o200)
        chmodOwnerRead(dest)
        #expect(read(dest) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("A write-only file whose rename is refused gets the bytes in place, though its mode went onto the staged file first")
    func writeOnlyRefusedRename() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("old contents", dest)
        #expect(chmod(dest.path, 0o200) == 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "everyone deny delete", dest.path]
        try p.run(); p.waitUntilExit()
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        let undo = Process()
        undo.executableURL = URL(fileURLWithPath: "/bin/chmod")
        undo.arguments = ["-N", dest.path]
        try undo.run(); undo.waitUntilExit()
        var st = stat(); stat(dest.path, &st)
        #expect(st.st_mode & 0o7777 == 0o200)
        chmodOwnerRead(dest)
        #expect(read(dest) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    // Regression (CWE-732): writing a file in place as a user who isn't root
    // makes the kernel clear its set-user-ID / set-group-ID bits (macOS and
    // Linux alike). A hard-linked 04755 file came out 0755 from an upload.
    private func mode(_ u: URL) -> mode_t { var st = stat(); stat(u.path, &st); return st.st_mode & 0o7777 }

    @Test("A hard-linked set-user-ID file keeps its set-id bits through an in-place upload")
    func hardLinkKeepsSetID() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        let other = d.appendingPathComponent("other")
        try write("old contents, longer", dest)
        #expect(chmod(dest.path, 0o4755) == 0)
        #expect(link(dest.path, other.path) == 0)
        try write("new", staged)
        #expect(StagedReplace.replace(staged.path, onto: dest.path) == nil)
        #expect(read(dest) == "new" && read(other) == "new")
        #expect(mode(dest) == 0o4755)
    }

    @Test("bromure-agentd: set-id bits survive an in-place upload and a plain write",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestTwinKeepsSetID() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let linked = d.appendingPathComponent("f"), other = d.appendingPathComponent("other")
        let plain = d.appendingPathComponent("plain"), cross = d.appendingPathComponent("cross")
        for f in [linked, plain, cross] {
            try write("old contents, longer", f)
            #expect(chmod(f.path, 0o4755) == 0)
        }
        #expect(link(linked.path, other.path) == 0)
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, base64, errno
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            # In place: the hard-linked file.
            staged = os.path.join(d, '.f.part'); open(staged, 'w').write('new')
            assert m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'f')}) == {'exit_code': 0}
            # In place: a rename refused across filesystems.
            staged = os.path.join(d, '.c.part'); open(staged, 'w').write('new')
            real = os.replace
            def xdev(a, b): raise OSError(errno.EXDEV, 'xdev')
            m.os.replace = xdev
            assert m._file_op({'op': 'rename', 'path': staged, 'dest': os.path.join(d, 'cross')}) == {'exit_code': 0}
            m.os.replace = real
            # A plain (direct) write: truncating, then appending.
            p = os.path.join(d, 'plain')
            for data, app in ((b'ne', False), (b'w', True)):
                r = m._file_op({'op': 'write', 'path': p, 'data': base64.b64encode(data).decode(), 'append': app})
                assert r == {'exit_code': 0}, r
            """, Self.agentd.path, d.path]
        try py.run(); py.waitUntilExit()
        #expect(py.terminationStatus == 0)
        for f in [linked, plain, cross] {
            #expect(read(f) == "new")
            #expect(mode(f) == 0o4755)
        }
        #expect(read(other) == "new")
    }

    // Regression (CWE-732): a new file the cross-volume fallback created got
    // a fixed 0644, dropping the group write a umask of 002 gives a plain
    // write (0664).
    @Test("A new file written in place gets what a plain write would under the umask")
    func inPlaceCreateHonorsUmask() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let old = umask(0o002)
        var restored = false
        defer { if !restored { umask(old) } }
        let staged = d.appendingPathComponent(".f.part"), dest = d.appendingPathComponent("f")
        try write("new", staged)
        let r = StagedReplace.writeInPlace(staged.path, into: dest.path, create: true)
        let plain = d.appendingPathComponent("plain")
        FileManager.default.createFile(atPath: plain.path, contents: nil)
        umask(old); restored = true
        #expect(r == nil)
        #expect(mode(dest) == 0o664)
        #expect(mode(dest) == mode(plain))
        #expect(read(dest) == "new")
    }
}
