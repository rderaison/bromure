import Testing
import Foundation
import Darwin

// Regression (CWE-200): an upload's staging file (the temp file `rename`
// later puts in place) was created with the default mode (0644 under the
// usual umask) and took the destination's (perhaps 0600) only at the
// rename, so others could read it while a large upload filled it. A
// `staged` first write now creates it owner-only; `rename` gives the final
// mode: the existing file's, or a plain write's for a new one.
@Suite("Staged uploads are owner-only until they're in place")
struct StagedUploadModeTests {
    private static let python = "/usr/bin/python3"
    private static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")

    @Test("bromure-agentd: staged write 0600, final mode at the rename, links refused",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guest() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("stagedmode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let py = Process()
        py.executableURL = URL(fileURLWithPath: Self.python)
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os, stat, base64
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m._current_umask = lambda: 0o022
            os.umask(0o022)
            d = sys.argv[2]
            b = lambda t: base64.b64encode(t).decode()
            mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)
            # Over a private file: 0600 while it fills, 0600 after.
            priv = os.path.join(d, 'secret'); open(priv, 'w').write('old'); os.chmod(priv, 0o640)
            tmp = os.path.join(d, '.secret.part')
            assert m._file_op({'op': 'write', 'path': tmp, 'data': b(b'ne'), 'append': False, 'staged': True})['exit_code'] == 0
            assert mode(tmp) == 0o600, oct(mode(tmp))
            assert m._file_op({'op': 'write', 'path': tmp, 'data': b(b'w'), 'append': True})['exit_code'] == 0
            assert mode(tmp) == 0o600
            assert m._file_op({'op': 'rename', 'path': tmp, 'dest': priv})['exit_code'] == 0
            assert open(priv).read() == 'new' and mode(priv) == 0o640, oct(mode(priv))
            # A new destination: a plain write's mode.
            tmp = os.path.join(d, '.fresh.part'); fresh = os.path.join(d, 'fresh')
            m._file_op({'op': 'write', 'path': tmp, 'data': b(b'x'), 'append': False, 'staged': True})
            assert mode(tmp) == 0o600
            assert m._file_op({'op': 'rename', 'path': tmp, 'dest': fresh})['exit_code'] == 0
            assert mode(fresh) == 0o644, oct(mode(fresh))
            # A plain write is unchanged.
            plain = os.path.join(d, 'plain')
            m._file_op({'op': 'write', 'path': plain, 'data': b(b'x'), 'append': False})
            assert mode(plain) == 0o644
            # A link planted at the staging name is refused, its target untouched.
            target = os.path.join(d, 'target'); open(target, 'w').write('keep')
            link = os.path.join(d, '.planted.part'); os.symlink(target, link)
            r = m._file_op({'op': 'write', 'path': link, 'data': b(b'x'), 'append': False, 'staged': True})
            assert r['exit_code'] == 1 and open(target).read() == 'keep', r
            """, Self.agentd.path, d.path]
        let err = Pipe(); py.standardError = err
        try py.run(); py.waitUntilExit()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(py.terminationStatus == 0, "\(msg)")
    }
}
