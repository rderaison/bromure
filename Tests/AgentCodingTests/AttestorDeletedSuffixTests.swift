import Foundation
import Testing

/// Finding (CWE-807): "Attestor strips a real ' (deleted)' filename into an
/// allowlisted binary path". `exe_identity` always cut a trailing " (deleted)"
/// off `/proc/<pid>/exe`, but a LIVE file named `curl (deleted)` reads the
/// same: the guest user could exec such a sibling of any allowlisted path it
/// can write and be attested -- and TOFU-pinned -- as that path. Only a raw
/// path that isn't the running image is the kernel's annotation.
@Suite("Attestor: only the kernel's ' (deleted)' is cut, never a real name")
struct AttestorDeletedSuffixTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-attestd.py")

    /// Runs `body` with the attestor module loaded as `a`, in a temp dir `d`; returns stdout.
    static func python(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", "-c", """
            import importlib.util, os, sys
            spec = importlib.util.spec_from_file_location("attestd", sys.argv[1])
            a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
            d = sys.argv[2]
            \(body)
            """, script.path, dir.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("a live file named '<x> (deleted)' keeps its name; an unlinked image loses the annotation")
    func liveVersusUnlinked() throws {
        let out = try Self.python("""
            fixed = lambda text: (lambda: text)
            def opened(name, unlink=False):
                path = os.path.join(d, name)
                open(path, "w").write(name)
                f = open(path, "rb")
                if unlink: os.unlink(path)
                return path, (lambda: os.fstat(f.fileno()).st_nlink), f
            live, live_n, _f1 = opened("curl (deleted)")
            print(a.reported_path(fixed(live), live_n))                       # live: kept
            gone, gone_n, _f2 = opened("old", unlink=True)
            print(a.reported_path(fixed(gone + " (deleted)"), gone_n))        # unlinked: cut
            real, real_n, _f3 = opened("curl")
            print(a.reported_path(fixed(real), real_n))                       # no suffix: as is
            nested, nested_n, _f4 = opened("x (deleted)", unlink=True)
            print(a.reported_path(fixed(nested + " (deleted)"), nested_n))    # unlinked real name: one cut
            # Unlinked here but hard-linked elsewhere: a name still exists, nothing is cut.
            hl, hl_n, _f5 = opened("hl")
            os.link(hl, os.path.join(d, "hl-other")); os.unlink(hl)
            print(a.reported_path(fixed(hl + " (deleted)"), hl_n))
            """)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        #expect(lines[0].hasSuffix("/curl (deleted)"))
        #expect(lines[1].hasSuffix("/old"))
        #expect(lines[2].hasSuffix("/curl"))
        #expect(lines[3].hasSuffix("/x (deleted)"))
        #expect(lines[4].hasSuffix("/hl (deleted)"))
    }

    /// Finding (CWE-367): "Attestor strips a live '(deleted)' binary when its
    /// name is restored around the stat" -- and the earlier unlink race. The
    /// path text is never stat'ed: renaming it aside and back can't matter.
    @Test("a live '<x> (deleted)' renamed aside and back, or unlinked mid-read, is never '<x>'")
    func renameAndUnlinkRaces() throws {
        let out = try Self.python("""
            live = os.path.join(d, "curl (deleted)")
            open(live, "w").write("forged")
            f = open(live, "rb")
            n = lambda: os.fstat(f.fileno()).st_nlink
            # Renamed aside right after one read, back just before the next: every
            # read shows the live name, and anything looking in between finds nothing.
            reads = []
            def read_aside_between():
                reads.append(1)
                if len(reads) % 2: os.rename(live, live + ".aside")
                else: os.rename(live + ".aside", live)
                return live
            print(a.reported_path(read_aside_between, n))
            if os.path.exists(live + ".aside"): os.rename(live + ".aside", live)
            # Unlinked right after the read: the count moved, it's read again.
            calls = []
            def read_then_unlink():
                calls.append(1)
                if len(calls) == 1:
                    os.unlink(live); return live                  # the pre-unlink text
                return live + " (deleted)"                        # the kernel's view now
            print(a.reported_path(read_then_unlink, n))
            # A count that never holds still: no answer at all.
            k = iter(range(100))
            try:
                a.reported_path(lambda: live, lambda: next(k))
                print("answered")
            except OSError:
                print("refused")
            """)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.first?.hasSuffix("/curl (deleted)") == true)
        #expect(lines.dropFirst().first?.hasSuffix("/curl (deleted)") == true)
        #expect(lines.last == "refused")
    }

    @Test("exe_identity decides from the open exe's own link count")
    func wiring() throws {
        let src = try String(contentsOf: Self.script, encoding: .utf8)
        let fn = try #require(src.range(of: "def exe_identity(pid):"))
        let read = try #require(src[fn.upperBound...].range(of: "link = \"/proc/%d/exe\" % pid"))
        let code = src[read.upperBound...].prefix(300)
        #expect(code.contains("path = reported_path(lambda: os.readlink(link), lambda: os.fstat(f.fileno()).st_nlink)"))
        #expect(!code.contains("[: -len(_DELETED)]"))
    }
}
