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
        #expect(lines.withLockedValue { $0 } == ["[guest w] [  1.0] Kernel panic - not syncing"])
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
}
