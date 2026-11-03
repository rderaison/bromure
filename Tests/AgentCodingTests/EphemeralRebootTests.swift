import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Ephemeral reboot is cancelled when launch waits on
/// Kimi or a remote prompt". A reboot tears the session down, then launches
/// the workspace again -- but the teardown deleted a `vm run --rm` workspace
/// as if it had stopped for good, so a launch that waited (Kimi
/// provisioning, a remote drift or compromise prompt) found it gone and never
/// booted, and a direct launch recreated it no longer ephemeral. A reboot now
/// keeps it, still ephemeral, through the teardown.
@Suite("vm run --rm: a reboot isn't the end of the workspace")
struct EphemeralRebootTests {
    private static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/BromureAC.swift")

    /// The body of `func <name>` (up to the next declaration at its indent).
    private func body(_ src: String, _ signature: String) throws -> Substring {
        let start = try #require(src.range(of: signature))
        let rest = src[start.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    private func ") ?? rest.range(of: "\n    @MainActor")
        return rest[..<(end?.lowerBound ?? rest.endIndex)]
    }

    private func before(_ a: String, _ b: String, in s: Substring) -> Bool {
        guard let ra = s.range(of: a), let rb = s.range(of: b) else { return false }
        return ra.lowerBound < rb.lowerBound
    }

    @Test("the --rm delete skips a workspace that is rebooting")
    func teardownKeepsRebooting() throws {
        let src = try String(contentsOf: Self.source, encoding: .utf8)
        let stopped = try body(src, "func handleSessionStopped(profileID: Profile.ID) {")
        #expect(stopped.contains("if !rebootingProfiles.contains(profileID),\n           let p = profiles.first(where: { $0.id == profileID }), takeEphemeral(p) {"))
    }

    @Test("both detached reboot paths mark the workspace across their teardown, and clear it before the launch")
    func rebootPathsMarkIt() throws {
        let src = try String(contentsOf: Self.source, encoding: .utf8)
        let remote = try body(src, "func rebootMachine(_ id: Profile.ID, force: Bool, remoteInitiated: Bool) async")
        #expect(before("rebootingProfiles.insert(id)", "await stopSession(id, action: .shutdown)", in: remote))
        #expect(before("rebootingProfiles.insert(id)", "handleSessionStopped(profileID: id)", in: remote))
        #expect(before("rebootingProfiles.remove(id)", "launch(profile, detached: !wasAttached", in: remote))
        #expect(before("handleSessionStopped(profileID: id)", "rebootingProfiles.remove(id)", in: remote))

        let guest = try body(src, "private func relaunchAfterGuestReboot(_ profileID: Profile.ID) {")
        #expect(before("rebootingProfiles.insert(profileID)", "handleSessionStopped(profileID: profileID)", in: guest))
        #expect(before("handleSessionStopped(profileID: profileID)", "rebootingProfiles.remove(profileID)", in: guest))
        #expect(before("rebootingProfiles.remove(profileID)", "self.launch(profile, detached: true)", in: guest))
    }

    /// Review of the above: kept through the teardown, a workspace whose
    /// relaunch then gave up (a stop while it waited, a prompt cancelled or
    /// skipped) was never booted, so its stop never came and it stayed on
    /// disk for good. Every place a launch gives up drops it.
    @Test("a launch that gives up deletes a --rm workspace that isn't running")
    func abandonedLaunchDeletes() throws {
        let src = try String(contentsOf: Self.source, encoding: .utf8)
        let drop = try body(src, "private func dropAbandonedEphemeral(_ id: Profile.ID) {")
        #expect(drop.contains("guard runningSessions[id] == nil, !diskInUse(id), !rebootingProfiles.contains(id),"))
        #expect(drop.contains("takeEphemeral(p)") && drop.contains("try? store.delete(p)"))
        // Kimi provisioning stopped, the boot remedy stopped, a wipe
        // cancelled (remote and local), a wipe skipped, failed or undone by
        // a clear, or an upgrade skipped (remote).
        #expect(src.contains("""
            guard stop == nil, self.profiles.contains(where: { $0.id == profile.id }) else {
                                self.dropAbandonedEphemeral(profile.id); return
            """))
        #expect(src.contains("guard stop == nil else { self.dropAbandonedEphemeral(profileID); return }"))
        #expect(src.components(separatedBy: "case .cancelled: dropAbandonedEphemeral(profile.id); return").count == 3)
        let prompts = try body(src, "@MainActor private func resolveRemoteLaunchPrompts(")
        #expect(prompts.components(separatedBy: "dropAbandonedEphemeral(profile.id)").count == 6)
    }

    /// Finding (CWE-459): "vm run --rm reboot keeps the workspace only in
    /// memory, so quit during relaunch retains the disk". Between a reboot's
    /// teardown and its relaunch the mark lived only in `ephemeralProfiles`:
    /// a quit, a signal or a crash then (a prompt waiting, a boot that gave
    /// up) left the workspace on disk as an ordinary one.
    @Test("the --rm mark is on disk, with the workspace, and gone with it")
    func markIsDurable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "scratch", tool: .claude, authMode: .token)
        try store.save(p)
        #expect(!store.isEphemeral(p))
        store.markEphemeral(p)
        // Another process (the next launch) reads it from disk.
        let next = ProfileStore(rootDir: root)
        #expect(next.isEphemeral(p))
        let kept = Profile(name: "kept", tool: .claude, authMode: .token)
        try next.save(kept)
        #expect(!next.isEphemeral(kept))
        try next.delete(p)
        #expect(!next.isEphemeral(p))
        #expect(next.loadAll().map(\.id) == [kept.id])
    }

    /// Review: the login agent and the GUI share the store; running
    /// sessions and disk holds are per process, so a sweep must leave
    /// another live process's workspace alone.
    @Test("only the owner sweeps at its quit; at launch, only a workspace whose owner is gone")
    func ownership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let mine = Profile(name: "mine", tool: .claude, authMode: .token)
        let other = Profile(name: "other", tool: .claude, authMode: .token)
        let orphan = Profile(name: "orphan", tool: .claude, authMode: .token)
        for p in [mine, other, orphan] { try store.save(p) }
        store.markEphemeral(mine)
        store.markEphemeral(other, owner: 4242)      // a live process (the login agent)
        store.markEphemeral(orphan, owner: 4343)     // a process that's gone
        let alive: (pid_t) -> Bool = { $0 == 4242 }
        #expect(store.ephemeralOwner(mine) == getpid())
        // At this process's quit: its own only.
        #expect(store.ephemeralSweepable(mine, mine: true, isAlive: alive))
        #expect(!store.ephemeralSweepable(other, mine: true, isAlive: alive))
        #expect(!store.ephemeralSweepable(orphan, mine: true, isAlive: alive))
        // At a launch: only one whose owner is gone -- never a live one's, nor its own.
        #expect(store.ephemeralSweepable(orphan, mine: false, isAlive: alive))
        #expect(!store.ephemeralSweepable(other, mine: false, isAlive: alive))
        #expect(!store.ephemeralSweepable(mine, mine: false, isAlive: alive))
        // Neither a stop here nor a boot here takes a live owner's.
        #expect(!store.mayTakeEphemeral(other, isAlive: alive))
        #expect(!store.claimEphemeral(other, isAlive: alive))
        #expect(store.ephemeralOwner(other) == 4242)
        #expect(!store.ephemeralSweepable(other, mine: true, isAlive: alive))
        // Its own, or one whose owner is gone: taken (and claimed by a boot).
        #expect(store.mayTakeEphemeral(mine, isAlive: alive) && store.mayTakeEphemeral(orphan, isAlive: alive))
        #expect(store.claimEphemeral(orphan, isAlive: alive) && store.ephemeralOwner(orphan) == getpid())
        // An unmarked workspace is never taken; marking one claims it.
        let plain = Profile(name: "plain", tool: .claude, authMode: .token)
        try store.save(plain)
        #expect(!store.mayTakeEphemeral(plain, isAlive: alive))
        #expect(store.claimEphemeral(plain, isAlive: alive) && store.ephemeralOwner(plain) == getpid())
        #expect(ProfileStore.processAlive(getpid()))
    }

    @Test("a quit, a caught signal and the next launch delete every stopped --rm workspace")
    func sweeps() throws {
        let src = try String(contentsOf: Self.source, encoding: .utf8)
        // A refused claim keeps this process from booting it at all.
        #expect(src.contains("guard store.claimEphemeral(saved) else {"))
        let sweep = try body(src, "func sweepStoppedEphemeral(atLaunch: Bool = false) {")
        #expect(sweep.contains("runningSessions[p.id] == nil && !diskInUse(p.id)"))
        #expect(sweep.contains("store.ephemeralSweepable(p, mine: !atLaunch)"))
        #expect(src.contains("if store.isEphemeral(profile), !store.claimEphemeral(profile) {\n            bootsInFlight.end(profile.id)"))
        let launchBody = try body(src, "func launch(_ profile: Profile")
        #expect(before("!store.claimEphemeral(profile)", "let win = SessionPane(profile: profile", in: launchBody))
        #expect(!src.contains("store.markEphemeral("))
        let quit = try body(src, "func applicationWillTerminate(_ notification: Notification) {")
        #expect(quit.contains("sweepStoppedEphemeral()"))
        let signals = try body(src, "private func installCleanupSignalHandlers() {")
        #expect(before("sweepStoppedEphemeral()", "exit(128 + sig)", in: signals))
        let launched = try body(src, "func applicationDidFinishLaunching(_ notification: Notification) {")
        #expect(before("profiles = store.loadAll()", "sweepStoppedEphemeral(atLaunch: true)", in: launched))
        let take = try body(src, "private func takeEphemeral(_ p: Profile) -> Bool {")
        #expect(take.contains("return store.isEphemeral(p) ? store.mayTakeEphemeral(p) : inMemory"))
    }
}
