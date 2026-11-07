import Foundation
import Testing
@testable import bromure_ac

/// Board report: resuming a suspended workspace on Ark came back "off",
/// the next start shut down too, the third stayed up. A failed restore's
/// VM, and each VM torn down after it, reported its stop late — and the
/// stop handler ended whatever session the workspace had by then, keyed by
/// the workspace, not by the VM that stopped. Each one killed the next boot.
@Suite("A VM's stop ends only its own session")
struct StaleVMStopTests {
    private final class Box {}

    @Test("an earlier sandbox's late stop leaves the running one alone")
    func earlierStopIgnored() {
        let first = Box(), second = Box()
        // The boot that's running stops: its session ends.
        #expect(ACAppDelegate.stopEndsSession(of: second, current: second))
        // The one it replaced stops late: the running boot stays.
        #expect(!ACAppDelegate.stopEndsSession(of: first, current: second))
        // A boot still on its way (no session yet) stopping: it ends.
        #expect(ACAppDelegate.stopEndsSession(of: first, current: nil))
    }

    /// The finding (CWE-367): a poll a relaunch stopped still applies the
    /// one-shots it had taken from the outbox, and the callbacks are keyed by
    /// the workspace: the old guest's reboot intent marked the replacement
    /// session rebooting (its saved state cleared, its shutdown taken for a
    /// reboot). A sandbox's one-shots reach the session only while it runs on
    /// that sandbox.
    @Test("an old sandbox's one-shots never reach the session that replaced it")
    func oldOneShotsIgnored() throws {
        let old = Box(), new = Box()
        #expect(ACAppDelegate.eventIsForCurrent(new, current: new))
        #expect(!ACAppDelegate.eventIsForCurrent(old, current: new))
        #expect(ACAppDelegate.eventIsForCurrent(old, current: nil))     // no session registered
        #expect(!ACAppDelegate.eventIsForCurrent(nil, current: new))    // the sandbox is gone

        // Wired: every one-shot the cancelled poll still applies checks it.
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        for cb in ["onGuestReboot = { [weak self, weak sandbox] in",
                   "onURLOpen = { [weak self, weak sandbox] url in",
                   "onDockerError = { [weak self, weak sandbox] message in",
                   "onWorktreeError = { [weak self, weak sandbox] raw in",
                   "onAgentStatus = { [weak self, weak sandbox] index, signal in"] {
            let r = try #require(src.range(of: "sandbox." + cb), "\(cb)")
            #expect(src[r.upperBound...].prefix(700).contains("Self.eventIsForCurrent(sandbox, current: "), "\(cb)")
        }
        // The reboot's check comes before it marks anything.
        let reboot = try #require(src.range(of: "sandbox.onGuestReboot = { [weak self, weak sandbox] in"))
        let body = src[reboot.upperBound...].prefix(1200)
        let check = try #require(body.range(of: "guard Self.eventIsForCurrent(sandbox, current: session.sandbox)"))
        let mark = try #require(body.range(of: "session.rebootRequested = true"))
        #expect(check.lowerBound < mark.lowerBound)
    }
}
