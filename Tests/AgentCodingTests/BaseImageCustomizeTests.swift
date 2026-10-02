import Foundation
import Testing
@testable import bromure_ac

// Issue #34: a script of the user's baked into the base image after
// Bromure's setup, so workspaces created or reset from it have their tools.

@Suite("Base image customize script")
struct BaseImageCustomizeTests {

    @Test("the step is traced, tagged, and named to run last")
    func stepText() {
        let step = UbuntuImageManager.customizeStep("apt-get install -y ripgrep")
        #expect(step.hasPrefix("# Your customize script\n"))   // the name postinstall.sh logs
        #expect(step.contains("set -x\n") && step.contains("PS4='+ [customize] '"))
        #expect(step.hasSuffix("apt-get install -y ripgrep\n"))
        // Lexical order is execution order; catalog steps are NNNN-<uuid8>.
        #expect(UbuntuImageManager.customizeStepName > "0999-ffffffff.sh")
    }

    @Test("off, chosen, or unreadable")
    func loading() throws {
        let d = try #require(UserDefaults(suiteName: "customize-\(UUID().uuidString)"))
        #expect(BaseImageCustomize.load(defaults: d).script == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("customize-\(UUID().uuidString).sh")
        try "echo hi\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        d.set(file.path, forKey: BaseImageCustomize.pathKey)
        #expect(BaseImageCustomize.load(defaults: d).script == nil)       // chosen but off
        d.set(true, forKey: BaseImageCustomize.enabledKey)
        #expect(BaseImageCustomize.load(defaults: d).script == "echo hi\n")
        d.set("/nonexistent/customize.sh", forKey: BaseImageCustomize.pathKey)
        let missing = BaseImageCustomize.load(defaults: d)
        #expect(missing.script == nil && missing.problem?.contains("/nonexistent/customize.sh") == true)
    }

    /// postinstall.sh's `run_step`, run for real against step files.
    private func runSteps(_ files: [String: String]) throws -> (status: Int32, out: String) {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/postinstall.sh"), encoding: .utf8)
        let lines = src.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("run_step() {") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        // `sleep` stubbed so a retried step doesn't slow the test down.
        let script = "set -e\nsleep() { :; }\nlog() { printf '%s\\n' \"$*\"; }\n"
            + lines[start...end].joined(separator: "\n")
            + "\nfor f in \(dir.path)/*.sh; do run_step \"$f\"; done\n"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test("it runs once, traced, after the catalog steps; a failure fails the build")
    func runsOnceTraced() throws {
        let ok = try runSteps([
            "0001-aaaaaaaa.sh": "# Catalog step\nset -e\necho catalog\n",
            UbuntuImageManager.customizeStepName: UbuntuImageManager.customizeStep("echo mine"),
        ])
        #expect(ok.status == 0)
        #expect(ok.out.range(of: "catalog")!.lowerBound < ok.out.range(of: "+ [customize] echo mine")!.lowerBound)
        let failing = try runSteps([UbuntuImageManager.customizeStepName: UbuntuImageManager.customizeStep("false")])
        #expect(failing.status != 0)
        #expect(failing.out.contains("attempt 1/1 failed") && !failing.out.contains("attempt 2/"))
        #expect(failing.out.contains("SANDBOX_POSTINSTALL_FAILED: step failed after 1 attempt(s): Your customize script"))
        // A catalog step still gets its three tries.
        let flaky = try runSteps(["0001-aaaaaaaa.sh": "# Catalog step\nfalse\n"])
        #expect(flaky.out.contains("attempt 3/3 failed"))
    }
}
