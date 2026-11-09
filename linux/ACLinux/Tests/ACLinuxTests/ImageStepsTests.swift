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

    /// A configured image someone else could have planted isn't booted:
    /// only root's or this user's, nothing group- or world-writable, no
    /// link to a file that isn't; this user's own image always is.
    @Test func anImageOthersMayWriteIsntBooted() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        let img = dir + "/shared"
        try fm.createDirectory(atPath: img, withIntermediateDirectories: true)
        for f in ["base.img", "vmlinuz", "initrd.img", "cmdline", "base.version"] { fm.createFile(atPath: img + "/" + f, contents: Data("x".utf8)) }
        chmod(img, 0o755)
        for f in ["base.img", "vmlinuz", "initrd.img", "cmdline"] { chmod(img + "/" + f, 0o644) }
        #expect(DaemonConfig.imageTrustProblem(img) == nil, "this user's, not writable by others")
        #expect(DaemonConfig.imageTrustProblem(img, uid: getuid() &+ 1) != nil, "another user's dir")
        chmod(img + "/vmlinuz", 0o666)
        #expect(DaemonConfig.imageTrustProblem(img)?.contains("vmlinuz") == true, "a world-writable kernel")
        chmod(img + "/vmlinuz", 0o644)
        chmod(img, 0o777)
        #expect(DaemonConfig.imageTrustProblem(img) != nil, "a world-writable dir")
        chmod(img, 0o775)
        var st = stat()
        #expect(stat(img, &st) == 0)
        #expect((DaemonConfig.imageTrustProblem(img) == nil) == DaemonConfig.privateGroup(gid: st.st_gid, owner: getuid()),
                "group-writable: only for the owner's private group")
        chmod(img, 0o755)
        // A link is judged by what it points to.
        try fm.removeItem(atPath: img + "/initrd.img")
        fm.createFile(atPath: dir + "/elsewhere", contents: Data("x".utf8))
        chmod(dir + "/elsewhere", 0o644)
        try fm.createSymbolicLink(atPath: img + "/initrd.img", withDestinationPath: dir + "/elsewhere")
        #expect(DaemonConfig.imageTrustProblem(img) == nil, "a link to a trusted file")
        chmod(dir + "/elsewhere", 0o666)
        #expect(DaemonConfig.imageTrustProblem(img)?.contains("initrd.img") == true, "a link to a world-writable file")
        let c = DaemonConfig(stateDir: dir + "/state", runtimeDir: dir + "/run", imageDir: img, agentdPath: "")
        #expect(throws: (any Error).self) { _ = try c.bootableImageDir() }
        if let e = try? { () throws -> Error? in do { _ = try c.bootableImageDir(); return nil } catch { return error } }() {
            #expect("\(e)".contains("bromure-ac image install"))
        }
    }
}
