import Foundation
import Testing
import SandboxEngine
@testable import ACLinux

/// Catalog steps published since the image was built (macOS: the launch's
/// image check): which are offered, the question's words, and the amend's
/// bookkeeping.
@Suite("Image: newly published catalog steps")
struct ImageStepsTests {
    static func step(_ uuid: String, _ seq: Int, _ what: String) -> PostinstallStep {
        PostinstallStep(uuid: uuid, seq: seq, description: what, command: "true")
    }

    static func catalog(image: String?, _ steps: [PostinstallStep]) throws -> ImageCatalog {
        var c = ImageCatalog(formatVersion: 1, image: nil, postinstall: steps)
        if let image {
            c.image = RemoteBaseImage(uuid: "u", version: image, description: "d", builtAt: nil,
                                      disk: .init(path: "p", sha256: "s", compressedBytes: 1, uncompressedBytes: 1, compression: "gzip"),
                                      boot: nil)
        }
        return c
    }

    @Test func onlyTheNewStepsOfTheSameImageAreOffered() throws {
        let a = Self.step("aaaa", 1, "Claude Code"), b = Self.step("bbbb", 2, "Codex")
        let same = try Self.catalog(image: "201", [b, a])
        #expect(Daemon.postinstallStepsToOffer(same, installedStamp: "201.2", applied: ["aaaa"]) == [b])
        #expect(Daemon.postinstallStepsToOffer(same, installedStamp: "201", applied: ["aaaa", "bbbb"]).isEmpty)
        #expect(Daemon.postinstallStepsToOffer(same, installedStamp: nil, applied: []).isEmpty, "no image")
        // A newer image published: a full update, no steps under it.
        #expect(Daemon.postinstallStepsToOffer(try Self.catalog(image: "202", [a, b]), installedStamp: "201.3", applied: []).isEmpty)
        // An older one (a lagging CDN) doesn't count as an update.
        #expect(Daemon.postinstallStepsToOffer(try Self.catalog(image: "200", [a]), installedStamp: "201", applied: []) == [a])
        #expect(Daemon.postinstallStepsToOffer(try Self.catalog(image: "beta", [a]), installedStamp: "201", applied: []).isEmpty,
                "a non-numeric major counts when it differs")
        #expect(Daemon.postinstallStepsToOffer(try Self.catalog(image: nil, [a]), installedStamp: "201", applied: []) == [a])
    }

    /// macOS's alert, word for word (promptNewPostinstallSteps).
    @Test func theQuestionIsMacOSs() {
        let (title, message) = Daemon.newPostinstallStepsPromptParts([Self.step("a", 1, "Claude Code"), Self.step("b", 2, "Codex")])
        #expect(title == "New recommended packages")
        #expect(message == "New packages are recommended to be installed:\n\n• Claude Code\n• Codex\n\nBromure installs them into the base image (a few minutes, in the background VM). Existing workspaces keep running; each one's drift prompt will offer a reset to pick them up.")
        #expect(Daemon.newPostinstallStepsButtons == ["Install", "Later"])
    }

    @Test func anAmendAddsToTheAppliedSteps() {
        #expect(InterimBake.amendedSteps(prior: ["bbbb", "aaaa"], adding: ["cccc", "aaaa"]) == ["aaaa", "bbbb", "cccc"])
    }

    /// Nothing to amend: refused before anything is fetched or copied.
    @Test func anAmendNeedsAnImageAndSteps() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var o = InterimBake.Options(outputDir: dir + "/out", cacheDir: dir + "/cache", vmSetupDir: dir + "/setup", imageVersion: "201")
        o.amend = true
        o.postinstallSteps = [Self.step("a", 1, "Claude Code")]
        await #expect(throws: BakeError.self) { _ = try await InterimBake.bake(o) }
        o.postinstallSteps = []
        try FileManager.default.createDirectory(atPath: dir + "/out", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/out/base.img", contents: Data())
        try "201\n".write(toFile: dir + "/out/base.version", atomically: true, encoding: .utf8)
        await #expect(throws: BakeError.self) { _ = try await InterimBake.bake(o) }
        #expect(!FileManager.default.fileExists(atPath: dir + "/cache/alpine-vmlinuz-x86_64"), "nothing fetched")
        #expect(!FileManager.default.fileExists(atPath: dir + "/out/base.img.partial"))
    }

    /// An image from before image-state.json has the baseline's steps
    /// (macOS's migration), or what an early Linux bake listed; never written.
    @Test func anOlderImagesStepsAreTheBaselines() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let baseline = try Self.catalog(image: nil, [Self.step("aaaa", 1, "A"), Self.step("bbbb", 2, "B")])
        #expect(Daemon.appliedPostinstallSteps(imageDir: dir, baseline: baseline) == ["aaaa", "bbbb"])
        try "aaaa\n\n".write(toFile: dir + "/postinstall-steps", atomically: true, encoding: .utf8)
        #expect(Daemon.appliedPostinstallSteps(imageDir: dir, baseline: baseline) == ["aaaa"])
        ImageState.write(BaseImageState(imageUUID: nil, version: "201", appliedStepUUIDs: ["cccc"]), imageDir: dir)
        #expect(Daemon.appliedPostinstallSteps(imageDir: dir, baseline: baseline) == ["cccc"])
        try FileManager.default.removeItem(atPath: dir + "/image-state.json")
        _ = Daemon.appliedPostinstallSteps(imageDir: dir, baseline: baseline)
        #expect(!FileManager.default.fileExists(atPath: dir + "/image-state.json"), "not written back")
    }

    /// An amend runs only the accepted steps the image still lacks, read
    /// under the bake's lock: none left is refused before anything is fetched.
    @Test func anAmendSkipsStepsTheImageGotMeanwhile() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/out", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/out/base.img", contents: Data())
        try "201.1\n".write(toFile: dir + "/out/base.version", atomically: true, encoding: .utf8)
        ImageState.write(BaseImageState(imageUUID: nil, version: "201.1", appliedStepUUIDs: ["a"]), imageDir: dir + "/out")
        var o = InterimBake.Options(outputDir: dir + "/out", cacheDir: dir + "/cache", vmSetupDir: dir + "/setup", imageVersion: "201")
        o.amend = true
        o.postinstallSteps = [Self.step("a", 1, "Claude Code")]
        await #expect(throws: BakeError.self) { _ = try await InterimBake.bake(o) }
        #expect(!FileManager.default.fileExists(atPath: dir + "/cache/alpine-vmlinuz-x86_64"), "nothing fetched")
    }

    /// A multi-user daemon's shared image is read-only: this user's image
    /// is theirs, in the state dir, and boots once it's there.
    @Test func aReadOnlySharedImageSendsInstallsToTheUsersOwn() throws {
        let dir = try shortTempDir()
        defer { chmod(dir + "/shared", 0o755); try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/shared", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/shared/base.img", contents: Data())
        fm.createFile(atPath: dir + "/shared/base.version", contents: Data("201\n".utf8))
        let c = DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run", imageDir: dir + "/shared", agentdPath: "")
        let missing = DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run", imageDir: dir + "/nowhere", agentdPath: "")
        #expect(missing.userImageDir == dir + "/state/image", "a configured dir that's missing is never made")
        #expect(Daemon.mayWriteImage(missing.userImageDir))
        var st = stat()
        #expect(stat(dir + "/state/image", &st) == 0 && st.st_mode & 0o777 == 0o700, "the user's own image dir is theirs alone")
        try? fm.removeItem(atPath: dir + "/state/image")
        #expect(c.userImageDir == dir + "/shared" && c.imageDir == dir + "/shared", "writable: the configured one")
        chmod(dir + "/shared", 0o555)
        guard access(dir + "/shared", W_OK) != 0 else { return }   // root writes anyway
        #expect(c.userImageDir == dir + "/state/image")
        #expect(c.imageDir == dir + "/shared", "none of their own yet: the shared one")
        try fm.createDirectory(atPath: dir + "/state/image", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/state/image/base.img", contents: Data())
        fm.createFile(atPath: dir + "/state/image/base.version", contents: Data("201.1\n".utf8))
        #expect(c.imageDir == dir + "/state/image", "their own, once it's there")
        #expect(Daemon.mayWriteImage(c.userImageDir) && !Daemon.mayWriteImage(dir + "/shared"))
    }

    /// What would boot is judged: each file's real path, it and every dir
    /// above it root's or this user's and writable by no one else (a
    /// sticky root dir such as /tmp aside); the boot uses those paths.
    @Test func anImageOthersMayWriteIsntBooted() throws {
        let dir = try shortTempDir()   // 0700, in /tmp (sticky, root's)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        let img = dir + "/shared"
        try fm.createDirectory(atPath: img, withIntermediateDirectories: true)
        for f in ["base.img", "vmlinuz", "initrd.img", "cmdline", "kernel-release"] {
            fm.createFile(atPath: img + "/" + f, contents: Data("x".utf8))
            chmod(img + "/" + f, 0o644)
        }
        chmod(img, 0o755)
        guard case .success(let ok) = ImageTrust.check(img) else { Issue.record("this user's own, not writable by others"); return }
        #expect(ok.kernel == img + "/vmlinuz" && ok.baseImage == img + "/base.img")
        guard case .failure = ImageTrust.check(img, uid: getuid() &+ 1) else { Issue.record("another user's"); return }
        // A world-writable kernel: refused, with the fix (the file is ours).
        chmod(img + "/vmlinuz", 0o666)
        guard case .failure(let p) = ImageTrust.check(img) else { Issue.record("a world-writable kernel"); return }
        #expect(p.path == img + "/vmlinuz" && p.fix == "chmod go-w \(img)/vmlinuz")
        chmod(img + "/vmlinuz", 0o644)
        // A dir above it others may write (not sticky): refused.
        chmod(dir, 0o777)
        guard case .failure(let up) = ImageTrust.check(img) else { Issue.record("a writable dir above it"); return }
        #expect(up.path == dir)
        chmod(dir, 0o700)
        // A link is judged by its target, and booted from it; a dangling one is refused.
        try fm.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        chmod(dir + "/real", 0o755)
        fm.createFile(atPath: dir + "/real/initrd", contents: Data("x".utf8))
        chmod(dir + "/real/initrd", 0o644)
        try fm.removeItem(atPath: img + "/initrd.img")
        try fm.createSymbolicLink(atPath: img + "/initrd.img", withDestinationPath: dir + "/real/initrd")
        guard case .success(let linked) = ImageTrust.check(img) else { Issue.record("a link to a trusted file"); return }
        #expect(linked.initrd == dir + "/real/initrd", "booted from the checked target")
        chmod(dir + "/real", 0o777)
        guard case .failure = ImageTrust.check(img) else { Issue.record("a link into a dir others may write"); return }
        chmod(dir + "/real", 0o755)
        try fm.removeItem(atPath: dir + "/real/initrd")
        guard case .failure(let dangling) = ImageTrust.check(img) else { Issue.record("a dangling link"); return }
        #expect(dangling.why.contains("link to nothing"))
        // Group-writable, the owner's private group or not: refused, and the
        // daemon's error names the fix when it's the user's own.
        try fm.removeItem(atPath: img + "/initrd.img")
        fm.createFile(atPath: img + "/initrd.img", contents: Data("x".utf8))
        chmod(img + "/initrd.img", 0o664)
        let c = DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run", imageDir: img, agentdPath: "")
        #expect(throws: (any Error).self) { _ = try c.checkedImage() }
        do { _ = try c.checkedImage() } catch { #expect("\(error)".contains("fix: chmod go-w \(img)/initrd.img")) }
        // No image dir at all: refused, not passed with unresolved paths.
        guard case .failure(let none) = ImageTrust.check(dir + "/nowhere") else { Issue.record("a missing image dir"); return }
        #expect(none.why.contains("can't be resolved"))
    }

    /// A POSIX ACL (named users or groups, a mask) isn't trusted.
    @Test func anACLIsRefused() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = dir + "/img"
        try FileManager.default.createDirectory(atPath: img, withIntermediateDirectories: true)
        chmod(img, 0o755)
        FileManager.default.createFile(atPath: img + "/base.img", contents: Data("x".utf8))
        chmod(img + "/base.img", 0o644)
        guard case .success = ImageTrust.check(img) else { Issue.record("no ACL"); return }
        // A named-user entry for nobody (setfacl may not be installed: then skip).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/setfacl")
        p.arguments = ["-m", "u:nobody:rw", img + "/base.img"]
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        guard case .failure(let acl) = ImageTrust.check(img) else { Issue.record("an ACL'd disk"); return }
        // Its mask shows as the group's bits: refused for those, or the ACL.
        #expect(acl.path == img + "/base.img" && (acl.why.contains("POSIX ACL") || acl.why.contains("writable by its group")), "\(acl)")
        chmod(img + "/base.img", 0o644)   // the mask cleared, the named entry kept
        guard case .failure(let still) = ImageTrust.check(img) else { Issue.record("an ACL with no write bits"); return }
        #expect(still.why.contains("POSIX ACL") && still.fix == "setfacl -b \(img)/base.img")
    }

    /// An image that isn't safe to boot refuses a suspended workspace's
    /// start without touching its saved state.
    @Test func anUntrustedImageKeepsTheSavedState() async throws {
        let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let img = dir + "/image"
        try FileManager.default.createDirectory(atPath: img, withIntermediateDirectories: true)
        for f in ["base.img", "vmlinuz", "initrd.img", "cmdline", "base.version"] { FileManager.default.createFile(atPath: img + "/" + f, contents: Data("x".utf8)) }
        chmod(img + "/vmlinuz", 0o666)
        var r = rec
        r.state = .suspended
        try await d.registerForTesting(r)
        let snap = await d.snapshotDir(r.id)
        try FileManager.default.createDirectory(atPath: snap, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snap + "/vm.snap", contents: Data([1]))
        FileManager.default.createFile(atPath: snap + "/vm.mem", contents: Data([1]))
        let resp = await d.start(r)
        #expect(resp.status == 409 && (resp.body["error"]?.stringValue ?? "").contains("isn't safe to boot"), "\(resp.status) \(resp.body)")
        #expect(FileManager.default.fileExists(atPath: snap + "/vm.snap"), "the saved state is kept")
        await d.shutdown()
    }

    /// A user's own image (umask 002 made it group-writable) is fixed at the
    /// daemon's start, not refused: only <state>/image, only their files,
    /// never through a link, never a configured dir.
    @Test func theUsersOwnImageIsMadeTheirsAlone() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        let own = dir + "/state/image", shared = dir + "/shared"
        for d in [own, shared] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true); chmod(d, 0o775) }
        chmod(dir + "/state", 0o755)
        for f in ["base.img", "vmlinuz", "initrd.img", "cmdline", "kernel-release", "base.version"] {
            fm.createFile(atPath: own + "/" + f, contents: Data("x".utf8)); chmod(own + "/" + f, 0o664)
        }
        fm.createFile(atPath: shared + "/base.img", contents: Data("x".utf8)); chmod(shared + "/base.img", 0o666)
        fm.createFile(atPath: dir + "/target", contents: Data("x".utf8)); chmod(dir + "/target", 0o666)
        try fm.createSymbolicLink(atPath: own + "/linked", withDestinationPath: dir + "/target")
        let c = DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run", imageDir: shared, agentdPath: "")
        c.secureOwnImageDir()
        func mode(_ p: String) -> mode_t { var st = stat(); _ = lstat(p, &st); return st.st_mode & 0o777 }
        #expect(mode(own) == 0o700)
        #expect(mode(own + "/vmlinuz") == 0o644 && mode(own + "/base.img") == 0o644)
        #expect(mode(dir + "/target") == 0o666, "not through a link")
        #expect(mode(shared) == 0o775 && mode(shared + "/base.img") == 0o666, "a configured dir is left as it is")
        guard case .success = ImageTrust.check(own) else { Issue.record("their own image, fixed, boots"); return }
        // What a bake writes into: this user's, cleared; another's or a link, not.
        chmod(shared, 0o775)
        #expect(InterimBake.clearSharedWrite(shared) && mode(shared) == 0o755)
        #expect(!InterimBake.clearSharedWrite(own + "/linked"))
    }
}
