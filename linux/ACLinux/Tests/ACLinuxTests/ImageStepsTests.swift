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
}
