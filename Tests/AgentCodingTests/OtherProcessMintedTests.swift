import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-284): "The other Bromure process's launch rewrites a
/// workspace and drops minted keys". The app and its login agent share one
/// store but each has its own `profiles`. A credential the guest minted is
/// recorded only by the process running the VM; the other one's automation
/// tick saw the live workspace as off and launched it from the copy it
/// loaded at startup -- `store.touch` saved that copy, `mintedCredentials: []`
/// and all, deleting the record and its secret, so the access key the guest
/// still holds was later signed with the workspace's own key.
@Suite("The other process's stale copy keeps minted credentials, and leaves an open workspace alone", .serialized)
struct OtherProcessMintedTests {
    static func tempStore() -> (ProfileStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minted-\(UUID().uuidString)")
        return (ProfileStore(rootDir: root), root)
    }

    static func minted(_ key: String, secret: String, expires: Date? = nil) -> MintedCredential {
        MintedCredential(kind: .sigV4, source: "sts:AssumeRole", accessKeyID: key,
                         secret: secret, createdAt: Date(), expiresAt: expires)
    }

    @Test("a save from a copy that predates a minted credential keeps it, secret included")
    func staleSaveKeepsMinted() throws {
        let (store, root) = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Profile(name: "w", tool: .claude, authMode: .token)
        try store.save(p)
        let stale = p                                   // the other process's copy, loaded at startup

        // The owner's VM mints one (saveMintedCredential).
        var owner = p
        owner.mintedCredentials = [Self.minted("ASIAREAL", secret: "s3cret")]
        try store.update(owner)

        // The other process launches its stale copy: touch must not drop it.
        let written = try store.touch(stale)
        #expect(written.mintedCredentials.map(\.accessKeyID) == ["ASIAREAL"])
        #expect(written.mintedCredentials.first?.secret == "s3cret")
        let loaded = try #require(store.loadAll().first { $0.id == p.id })
        #expect(loaded.mintedCredentials.map(\.accessKeyID) == ["ASIAREAL"])
        #expect(loaded.mintedCredentials.first?.secret == "s3cret")
        #expect(loaded.lastUsedAt != nil)

        // Any other full write from a stale copy (a squelch toggle, an editor).
        var toggled = stale
        toggled.squelch.enabled = true
        try store.update(toggled)
        #expect(store.loadAll().first { $0.id == p.id }?.mintedCredentials.first?.secret == "s3cret")

        // The copy's own version of a credential wins; long-expired ones go.
        var renewed = owner
        renewed.mintedCredentials = [Self.minted("ASIAREAL", secret: "s3cret-2")]
        renewed.mintedCredentials[0].id = owner.mintedCredentials[0].id
        try store.update(renewed)
        #expect(store.loadAll().first { $0.id == p.id }?.mintedCredentials.map(\.secret) == ["s3cret-2"])
        var old = renewed
        old.mintedCredentials.append(Self.minted("ASIAOLD", secret: "x", expires: Date(timeIntervalSinceNow: -365 * 86400)))
        try store.update(old)
        let afterPrune = try store.touch(stale)
        #expect(afterPrune.mintedCredentials.map(\.accessKeyID) == ["ASIAREAL"])
    }

    /// Holds the workspace's lease from another process (perl, flock), until killed.
    static func holdElsewhere(_ dir: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use Fcntl ':flock'; open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print \"held\\n\"; sleep 60",
                       dir.appendingPathComponent(WorkspaceLease.fileName).path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        _ = out.fileHandleForReading.availableData       // "held"
        return p
    }

    @Test("a workspace open in another process is seen as open, and can't be taken until it's gone")
    func lease() throws {
        let (store, root) = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Profile(name: "w", tool: .claude, authMode: .token)
        try store.save(p)
        let dir = store.profileDirectory(for: p)

        #expect(!WorkspaceLease.heldElsewhere(p.id, dir: dir))
        let other = try Self.holdElsewhere(dir)
        #expect(WorkspaceLease.heldElsewhere(p.id, dir: dir))
        #expect(!WorkspaceLease.acquire(p.id, dir: dir))
        other.terminate(); other.waitUntilExit()           // its process ends: the kernel lets go
        #expect(!WorkspaceLease.heldElsewhere(p.id, dir: dir))
        #expect(WorkspaceLease.acquire(p.id, dir: dir))
        #expect(WorkspaceLease.acquire(p.id, dir: dir))    // ours already
        #expect(!WorkspaceLease.heldElsewhere(p.id, dir: dir))
        WorkspaceLease.release(p.id)
        #expect(!WorkspaceLease.isHeld(p.id))
        // A never-saved workspace has nothing open.
        #expect(!WorkspaceLease.heldElsewhere(UUID(), dir: root.appendingPathComponent("nope")))
    }

    @Test("launch takes the lease before it writes, and an automation leaves the other process's workspace alone")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        let launch = try #require(ac.range(of: "    func launch(_ profile: Profile, detached: Bool = false,"))
        let body = ac[launch.upperBound...]
        let elsewhere = try #require(body.range(of: "if workspaceOpenElsewhere(profile.id)"))
        let acquire = try #require(body.range(of: "WorkspaceLease.acquire(profile.id"))
        let touch = try #require(body.range(of: "try store.touch(profile)"))
        #expect(elsewhere.lowerBound < acquire.lowerBound && acquire.lowerBound < touch.lowerBound)
        #expect(ac.contains("runningSessions.removeValue(forKey: id)\n        releaseLeaseIfIdle(id)"))
        // A reboot holds the disk before the old VM leaves the registry, so the
        // lease never lapses while this process rebuilds the VM.
        #expect(ac.contains("let release = holdDiskForRelaunch(profile.id)\n        unregisterSession(profile.id)"))
        // A reboot through a stop (rebootMachine, a detached guest reboot)
        // pins the lease from the stop to the next boot.
        let reboot = try #require(ac.range(of: "func rebootMachine(_ id: Profile.ID"))
        let rb = ac[reboot.upperBound...].prefix(1800)
        let pin = try #require(rb.range(of: "pinLease(id)"))
        let stop = try #require(rb.range(of: "handleSessionStopped(profileID: id)"))
        #expect(pin.lowerBound < stop.lowerBound)
        // Not dropped when rebootMachine returns: launch may still be waiting
        // on a fat client's prompt. The next boot's acquire takes it over.
        #expect(!rb.contains("unpinLease(id)"))
        let launchAcquire = try #require(body.range(of: "WorkspaceLease.acquire(profile.id"))
        #expect(body[launchAcquire.upperBound...].prefix(400).contains("leasePins.clear(profile.id)"))
        let guestReboot = try #require(ac.range(of: "private func relaunchAfterGuestReboot("))
        let gr = ac[guestReboot.upperBound...].prefix(2500)
        let gpin = try #require(gr.range(of: "pinLease(profileID)"))
        let gstop = try #require(gr.range(of: "handleSessionStopped(profileID: profileID)"))
        #expect(gpin.lowerBound < gstop.lowerBound)

        let sa = try src("Sources/AgentCoding/ScheduledAutomations.swift")
        let skip = try #require(sa.range(of: "if delegate.workspaceOpenElsewhere(a.profileID)"))
        let start = try #require(sa.range(of: "delegate.startProfileForAutomation(a.profileID)"))
        #expect(skip.lowerBound < start.lowerBound)
    }
}
