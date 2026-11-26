import Testing
import Foundation

// Regression: an upload staged beside a symlinked destination whose target
// sits on another filesystem failed at the `rename` op (EXDEV): the staged
// file can't be renamed across filesystems, though the direct write the
// upload used before went through the link fine. It's written through now.
@Suite("An upload onto a link to another filesystem is written through")
struct UploadCrossDeviceTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    @Test("bromure-agentd's rename: EXDEV/EBUSY write through, other errors still fail",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guest() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("xdev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, errno
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            d = sys.argv[2]
            real_replace = os.replace
            def cross(err):
                def r(a, b): raise OSError(err, os.strerror(err))
                return r
            # A link to an existing file "on another filesystem".
            target = os.path.join(d, 'target'); open(target, 'w').write('old contents, longer')
            link = os.path.join(d, 'link'); os.symlink(target, link)
            staged = os.path.join(d, '.link.part'); open(staged, 'w').write('new')
            m.os.replace = cross(errno.EXDEV)
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': link})
            assert r == {'exit_code': 0}, r
            assert open(target).read() == 'new' and os.path.islink(link) and not os.path.exists(staged)
            # A link whose target doesn't exist yet: created, as a plain write would.
            missing = os.path.join(d, 'missing'); link2 = os.path.join(d, 'link2'); os.symlink(missing, link2)
            staged = os.path.join(d, '.link2.part'); open(staged, 'w').write('fresh')
            m.os.replace = cross(errno.EBUSY)
            assert m._file_op({'op': 'rename', 'path': staged, 'dest': link2}) == {'exit_code': 0}
            assert open(missing).read() == 'fresh' and not os.path.exists(staged)
            # Any other failure is still an error, the destination untouched.
            staged = os.path.join(d, '.link.part'); open(staged, 'w').write('nope')
            m.os.replace = cross(errno.EIO)
            r = m._file_op({'op': 'rename', 'path': staged, 'dest': link})
            assert r['exit_code'] == 1 and open(target).read() == 'new', r
            """, Self.agentd.path, d.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(py.terminationStatus == 0, "\(msg)")
    }
}
