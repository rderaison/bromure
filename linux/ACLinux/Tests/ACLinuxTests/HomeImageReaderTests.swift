import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A stopped workspace's home image read off the host with the shared
    /// Ext4Volume walker (macOS's ext4Folders / ext4Transcript, now
    /// HomeImageReader): the folder browser's folders, a task's newest
    /// Claude transcript. A real image, made with mkfs.ext4 -d.
    @Suite("Home image reader", .serialized,
           .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/mkfs.ext4")))
    struct HomeImageReaderTests {
        /// home.img holding `files` (home-relative path → content, a
        /// trailing "/" for a folder), with the mtimes given.
        static func image(_ files: [(String, String, Date?)], at img: String) throws {
            let src = img + ".src"
            defer { try? FileManager.default.removeItem(atPath: src) }
            for (path, content, mtime) in files {
                let full = src + "/" + path
                if path.hasSuffix("/") {
                    try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                            withIntermediateDirectories: true)
                    try Data(content.utf8).write(to: URL(fileURLWithPath: full))
                }
                if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: full) }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/mkfs.ext4")
            p.arguments = ["-q", "-F", "-d", src, img, "16M"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "mkfs.ext4 -d")
        }

        @Test func foldersAndTranscript() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            let vm = await d.vmDir(rec.id)
            try FileManager.default.createDirectory(atPath: vm, withIntermediateDirectories: true)
            let img = vm + "/home.img"
            let old = Date(timeIntervalSince1970: 1_700_000_000), new = old.addingTimeInterval(3600)
            try Self.image([
                ("proj/src/", "", nil), ("Docs/", "", nil), (".hidden/", "", nil), ("notes.txt", "x", nil),
                (".claude/projects/-home-ubuntu-repo-wt-feat-x/a.jsonl", "{\"old\":1}\n", old),
                (".claude/projects/-home-ubuntu-repo-wt-feat-x/b.jsonl", "{\"new\":2}\n", new),
                (".claude/projects/-home-ubuntu-repo/c.jsonl", "{\"plain\":3}\n", old),
            ], at: img)

            // mkfs's lost+found is listed, as macOS's reader (and the
            // debugfs read this replaces) list it: only dotfolders are left out.
            #expect(HomeImageReader.folders(imagePath: img, path: "/") == ["Docs", "lost+found", "proj"], "dotfolders and files left out")
            #expect(HomeImageReader.folders(imagePath: img, path: "/proj") == ["src"])
            #expect(HomeImageReader.folders(imagePath: img, path: "/nope") == nil)
            // The task's worktree session: the newest .jsonl of a *-<slug> folder.
            #expect(HomeImageReader.claudeTranscript(imagePath: img, slug: "feat-x", guestCwd: "/home/ubuntu/elsewhere")
                    == "{\"new\":2}\n")
            // A plain-tab session: the Claude-encoded cwd.
            #expect(HomeImageReader.claudeTranscript(imagePath: img, slug: "zz", guestCwd: "/home/ubuntu/repo/")
                    == "{\"plain\":3}\n")
            #expect(HomeImageReader.claudeTranscript(imagePath: img, slug: "../x", guestCwd: "/") == nil, "a bad slug")

            // The daemon's folder browser on the stopped VM: off the image.
            let profile = Profile(name: "h", tool: .claude, authMode: .token)
            let pdir = await d.vmDir(profile.id.uuidString.lowercased())
            try FileManager.default.createDirectory(atPath: pdir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: img, toPath: pdir + "/home.img")
            #expect(await d.listGuestFolders(profile, path: "~") == ["Docs", "lost+found", "proj"])
            #expect(await d.listGuestFolders(profile, path: "~/proj") == ["src"])
            await d.shutdown()
        }
    }
}
