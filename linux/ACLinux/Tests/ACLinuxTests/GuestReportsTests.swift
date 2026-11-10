import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// What a guest reports outside its roster: worktree and docker errors,
/// its console's trouble, and the meta share's per-boot markers.
@Suite("Guest reports: errors, console trouble, boot markers")
struct GuestReportsTests {
    @Test func worktreeErrorsNameTheirRun() {
        #expect(LinuxSessionHost.splitWorktreeError("run-slug: auto-7\nfatal: branch exists") == ("auto-7", "fatal: branch exists"))
        #expect(LinuxSessionHost.splitWorktreeError("fatal: not a git repo") == (nil, "fatal: not a git repo"))
        #expect(LinuxSessionHost.splitWorktreeError("run-slug: \nx").slug == nil)
        #expect(LinuxSessionHost.isOneShot("worktree-error.txt", stem: "worktree-error"))
        #expect(LinuxSessionHost.isOneShot("worktree-error-1712.txt", stem: "worktree-error"))
        #expect(!LinuxSessionHost.isOneShot("worktree-errors.txt", stem: "worktree-error"))
        #expect(!LinuxSessionHost.isOneShot("docker-error.log", stem: "docker-error"))
    }

    @Test func onlyConsoleTroubleReachesTheLog() {
        #expect(BootConsoleScan.consoleLineForAppLog("\u{1B}[0;1;31mFAILED\u{1B}[0m to start foo.service", name: "w")
                == "[guest w] FAILED to start foo.service")
        #expect(BootConsoleScan.consoleLineForAppLog("[ 12.3] Out of memory: Killed process 42", name: "w") != nil)
        #expect(BootConsoleScan.consoleLineForAppLog("You are in emergency mode.", name: "w") != nil)
        #expect(BootConsoleScan.consoleLineForAppLog("Started foo.service", name: "w") == nil)
        #expect(BootConsoleScan.consoleLineForAppLog("   ", name: "w") == nil)
    }

    @Test func theConsoleIsFollowedWhileItsMachineRuns() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        try "Started a\n[  1.0] Kernel panic - not syncing\nhalf".write(toFile: log, atomically: true, encoding: .utf8)
        let lines = NIOLockedValueBox<[String]>([])
        let ticks = NIOLockedValueBox(0)
        await BootConsoleScan.echoTrouble(path: log, name: "w", poll: .milliseconds(5),
                                          alive: { ticks.withLockedValue { $0 += 1; return $0 <= 2 } },
                                          emit: { l in lines.withLockedValue { $0.append(l) } })
        #expect(lines.withLockedValue { $0 } == ["[guest w] [ 1.0] Kernel panic - not syncing"])
    }

    @Test func aFreshBootsTagsAreWrittenAnew() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try Daemon.writeVirtiofsTagMarkers(["bromure-meta", "share-1", "share-2"], in: dir, fresh: true)
        try Daemon.writeVirtiofsTagMarkers(["bromure-meta", "share-1"], in: dir, fresh: true)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir + "/virtiofs-tags")) == ["bromure-meta", "share-1"],
                "a share removed since: no marker left")
        try Daemon.writeVirtiofsTagMarkers(["bromure-meta"], in: dir, fresh: false)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir + "/virtiofs-tags")) == ["bromure-meta", "share-1"],
                "a restore keeps the guest's")
    }

    /// Eight URLs a tick; a backlog over 64 is a flood, its excess dropped.
    @Test func aURLFloodIsShed() {
        let few = (0..<20).map { "u\($0)" }
        #expect(LinuxSessionHost.urlBatch(few) == (Array(few.prefix(8)), []), "the rest wait for the next tick")
        let flood = (0..<65).map { "u\($0)" }
        let (open, shed) = LinuxSessionHost.urlBatch(flood)
        #expect(open == Array(flood.prefix(8)) && shed == Array(flood.dropFirst(8)))
        #expect(LinuxSessionHost.urlBatch((0..<64).map { "u\($0)" }).shed.isEmpty, "64 is no flood yet")
    }

    /// agentd is rewritten only when it changed (an identical rewrite would
    /// bump its mtime and restart it on a resume).
    @Test func agentdIsStagedOnlyWhenItChanged() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "v1".write(toFile: dir + "/src.py", atomically: true, encoding: .utf8)
        try Daemon.stageAgentd(dir + "/src.py", into: dir)
        var st = stat()
        #expect(stat(dir + "/bromure-agentd.py", &st) == 0 && st.st_mode & 0o777 == 0o755)
        let ino = st.st_ino
        try Daemon.stageAgentd(dir + "/src.py", into: dir)
        #expect(stat(dir + "/bromure-agentd.py", &st) == 0 && st.st_ino == ino, "unchanged: not rewritten")
        try "v2".write(toFile: dir + "/src.py", atomically: true, encoding: .utf8)
        try Daemon.stageAgentd(dir + "/src.py", into: dir)
        #expect(FileManager.default.contents(atPath: dir + "/bromure-agentd.py") == Data("v2".utf8))
    }

    @Test func theGraphicsMarkerFollowsTheSetting() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try Daemon.writeTerminalGraphicsMarker(in: dir, allowed: true)
        #expect(FileManager.default.fileExists(atPath: dir + "/terminal-graphics-enabled"))
        try Daemon.writeTerminalGraphicsMarker(in: dir, allowed: false)
        #expect(!FileManager.default.fileExists(atPath: dir + "/terminal-graphics-enabled"))
    }

    /// Escape sequences of every kind, other control characters and long
    /// lines don't reach the daemon's log as the guest wrote them.
    @Test func consoleLinesAreFlattened() {
        #expect(BootConsoleScan.flattened("a\u{1B}]0;title\u{07}b\u{1B}]8;;http://x\u{1B}\\c") == "abc", "OSC, BEL or ST ended")
        #expect(BootConsoleScan.flattened("x\u{1B}[?25lFAILED\u{1B}[0m y") == "xFAILED y")
        #expect(BootConsoleScan.flattened("ab\u{1B}cd\u{1B}") == "abd", "a bare ESC takes its next character")
        #expect(BootConsoleScan.flattened("FAILED\rfake\u{08}\tline\u{00}") == "FAILED fake line")
        let long = BootConsoleScan.flattened("FAILED " + String(repeating: "x", count: 1000))
        #expect(long.count == 301 && long.hasSuffix("…"))
    }

    /// A flood of console trouble: a few lines a poll, the rest counted.
    @Test func consoleTroubleIsRateLimited() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/serial.log"
        try (0..<20).map { "FAILED unit \($0)\n" }.joined().write(toFile: log, atomically: true, encoding: .utf8)
        let lines = NIOLockedValueBox<[String]>([])
        let ticks = NIOLockedValueBox(0)
        await BootConsoleScan.echoTrouble(path: log, name: "w", poll: .milliseconds(5), perPoll: 5,
                                          alive: { ticks.withLockedValue { $0 += 1; return $0 <= 2 } },
                                          emit: { l in lines.withLockedValue { $0.append(l) } })
        let got = lines.withLockedValue { $0 }
        #expect(got.count == 6)
        #expect(got.prefix(5).allSatisfy { $0.hasPrefix("[guest w] FAILED unit ") })
        #expect(got.last == "[guest w] 15 more console line(s) of trouble not shown")
    }
}
