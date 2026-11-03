import Foundation
import Testing
@testable import bromure_ac

/// The guest runs the host's commands with `/bin/sh -c`, and an Ubuntu
/// guest's /bin/sh is dash. `TaskLitter.status` began with "(", so every
/// `$(\(TaskLitter.status(…)))` became `$((` -- arithmetic to dash, a syntax
/// error (exit 2) the landing read as "Couldn't reach the workspace — is it
/// running?". bash (the Mac's /bin/sh) guesses a subshell, so the unit tests
/// that run these under bash never saw it; ac-e2e 26.4 did.
@Suite("Guest git commands parse and run under dash (the guest's /bin/sh)")
struct GuestShellDashTests {
    static let dash = "/bin/dash"

    @discardableResult
    static func run(_ shell: String, _ args: [String], in dir: URL? = nil) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return (String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }

    static func parses(_ cmd: String) -> Bool { run(dash, ["-n", "-c", cmd]).status == 0 }

    @Test("every command built around TaskLitter.status parses under dash",
          .enabled(if: FileManager.default.isExecutableFile(atPath: dash)))
    func parse() {
        let wt = "/w/t"
        #expect(Self.parses("s=$(\(TaskLitter.status("'\(wt)'")))"))
        for mode in [TaskLanding.Mode.merge, .squash, .pr] {
            #expect(Self.parses(CodingTaskEngine.landingCheckCommand(root: "/r", branch: "wt/x", target: "main",
                                                                     sourceDir: wt, mode: mode)))
        }
        #expect(Self.parses(CodingTaskEngine.landingVerifyCommand(root: "/r", branch: "wt/x", target: "main", sourceDir: wt)))
        #expect(Self.parses(CodingTaskEngine.landingVerifyCommand(root: "/r", branch: "wt/x", target: "main",
                                                                  sourceDir: wt, remote: "origin")))
        #expect(Self.parses(TaskReviewSummary.command(root: "/r", worktreeDir: wt, branch: "wt/x", target: "main")))
        #expect(Self.parses(CodingTaskEngine.emptyBranchCommand(root: "/r", branch: "wt/x", parent: "main", worktreeDir: wt)))
    }

    @Test("the landing check fast-forwards under dash, the way ac-e2e 26.4 lands a task",
          .enabled(if: FileManager.default.isExecutableFile(atPath: dash)))
    func landsUnderDash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dash-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wt = dir.path + "-wt"
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(atPath: wt) }
        Self.run("/bin/bash", ["-c", "git init -q -b master && git commit -q --allow-empty -m init "
                 + "&& git worktree add -q -b wt/x '\(wt)' && cd '\(wt)' && echo hi > KANBAN.txt "
                 + "&& git add KANBAN.txt && git commit -qm 'add KANBAN.txt'"], in: dir)
        let check = CodingTaskEngine.landingCheckCommand(root: dir.path, branch: "wt/x", target: "master",
                                                         sourceDir: wt, mode: .merge)
        let r = Self.run(Self.dash, ["-c", check], in: dir)
        #expect(r.status == 0)
        #expect(CodingTaskEngine.parseLandingCheck(r.out) == .mergedNow)
        #expect(Self.run("/bin/bash", ["-c", "git log --oneline master"], in: dir).out.contains("add KANBAN.txt"))
    }
}
