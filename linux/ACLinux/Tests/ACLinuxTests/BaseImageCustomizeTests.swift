import Foundation
import SandboxEngine
import Testing
@testable import ACLinux

@Suite("Base image customize script (Linux bake)")
struct BaseImageCustomizeLinuxTests {
    @Test("the script is the last step: traced, tagged, named zzzz-customize.sh, past any seq (postinstall.sh runs it once)")
    func staging() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let step = PostinstallStep(uuid: "7c9f1a2e-0000-4000-8000-000000000000", seq: 10, description: "A step", command: "true")
        let late = PostinstallStep(uuid: "ffffffff-0000-4000-8000-000000000000", seq: 99999, description: "Late", command: "true")
        _ = try InterimBake.stagePostinstall([step, late], to: dir)
        try InterimBake.stageCustomize("make install", to: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir + "/steps").sorted()
        #expect(files == ["0010-7c9f1a2e.sh", "99999-ffffffff.sh", "zzzz-customize.sh"])
        let body = try String(contentsOfFile: dir + "/steps/zzzz-customize.sh", encoding: .utf8)
        #expect(body == "# Your customize script\nexport PS4='+ [customize] '\nset -x\nmake install\n")
        let postinstall = try String(contentsOf: ImageCatalogACLinuxTests.repo
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/postinstall.sh"), encoding: .utf8)
        #expect(postinstall.contains("*-customize.sh) tries=1"), "postinstall.sh still runs the script once")
    }

    @Test("the script's own failure is said as the user's, with its log; others stay the installer's")
    func failureMapping() {
        var o = InterimBake.Options(outputDir: "/x", cacheDir: "/x", vmSetupDir: "/x", imageVersion: "201")
        let theirs = BakeError.installerReportedFailure("SANDBOX_POSTINSTALL_FAILED: step failed after 1 attempt(s): Your customize script")
        let ours = BakeError.installerReportedFailure("SANDBOX_POSTINSTALL_FAILED: step failed after 3 attempt(s): Claude Code (Anthropic)")
        #expect("\(InterimBake.customizeFailure(theirs, o))".hasPrefix("installer failed"), "no script: as it was")
        o.customizeScript = "false"
        o.customizeLogPath = NSHomeDirectory() + "/.local/state/bromure-ac/base-image-customize.log"
        #expect("\(InterimBake.customizeFailure(theirs, o))"
            == "Your customize script failed — the current image is kept. See ~/.local/state/bromure-ac/base-image-customize.log")
        #expect("\(InterimBake.customizeFailure(ours, o))".hasPrefix("installer failed"))
        #expect("\(InterimBake.customizeFailure(BakeError.noGuestNetwork, o))" == "\(BakeError.noGuestNetwork)")
    }

    @Test("the saved script: off unless enabled with a path; an unreadable or empty one is a problem, not a script")
    func load() throws {
        let (d, done) = try WorkspaceSubnetTests.defaults()
        defer { done() }
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(BaseImageCustomize.load(defaults: d) == (nil, nil))
        d.set(dir + "/c.sh", forKey: BaseImageCustomize.pathKey)
        #expect(BaseImageCustomize.load(defaults: d) == (nil, nil), "not enabled")
        d.set(true, forKey: BaseImageCustomize.enabledKey)
        let missing = BaseImageCustomize.load(defaults: d)
        #expect(missing.script == nil && missing.problem?.contains("can't be read") == true)
        try " \n".write(toFile: dir + "/c.sh", atomically: true, encoding: .utf8)
        #expect(BaseImageCustomize.load(defaults: d).problem != nil, "an empty script isn't run")
        try "apt-get install -y zsh\n".write(toFile: dir + "/c.sh", atomically: true, encoding: .utf8)
        #expect(BaseImageCustomize.load(defaults: d) == ("apt-get install -y zsh\n", nil))
        d.set("  ", forKey: BaseImageCustomize.pathKey)
        #expect(BaseImageCustomize.load(defaults: d) == (nil, nil), "no path")
    }

    @Test("one bake per output dir: a second one is refused while the first holds the lock")
    func oneBakePerDir() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fd = open(dir + "/.bake.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let o = InterimBake.Options(outputDir: dir, cacheDir: dir + "/cache", vmSetupDir: dir, imageVersion: "201")
        await #expect(throws: BakeError.self) { _ = try await InterimBake.bake(o) }
        #expect(!FileManager.default.fileExists(atPath: dir + "/.work"), "refused before touching anything")
    }

    @Test("the customize log keeps the postinstall phase only, under a header")
    func log() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/logs/base-image-customize.log"
        try FileManager.default.createDirectory(atPath: dir + "/logs", withIntermediateDirectories: true)
        try "an older run\n".write(toFile: path, atomically: true, encoding: .utf8)
        let log = CustomizeLog(path: path)
        log.write(Data("setup.sh output\n".utf8))
        log.start()
        log.write(Data("+ [customize] make\n".utf8))
        log.close()
        log.write(Data("after\n".utf8))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix("Base image customize run — "))
        #expect(text.hasSuffix("+ [customize] make\n"))
        #expect(!text.contains("setup.sh output") && !text.contains("an older run") && !text.contains("after"))
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600, "the trace is the owner's alone")
        #expect(stat(dir + "/logs", &st) == 0 && st.st_mode & 0o777 == 0o700)
        let none = CustomizeLog(path: nil)
        none.start(); none.write(Data("x".utf8)); none.close()
    }
}
