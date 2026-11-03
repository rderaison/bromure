import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-362): "A compromise wipe and a clear can undo each other and
/// both report success". Wipe and Restore…, Clear Compromised Mark… and
/// Start's Wipe and Launch can be up at once (a fat-client Start suspends on
/// the broker; a local runModal drains the main queue). A wipe confirmed
/// after a clear found the mark gone, did nothing and said ok -- the next
/// start booted the disk it was meant to destroy; a Wipe and Launch answered
/// after a clear erased the disk the user had just chosen to keep. The mark
/// is checked when the answer comes, and the one that came second hears what
/// the first did.
@Suite("Compromise: a wipe and a clear don't undo each other")
@MainActor
struct CompromiseRaceTests {
    @Test("the mark at answer time decides: do it, already done, or undone the other way")
    func steps() {
        let step = ACAppDelegate.compromiseStep
        #expect(step(.wipe, true, nil) == .perform)
        #expect(step(.clear, true, .wipe) == .perform)
        // Wiped since the mark: a second wipe erased nothing more, but the disk is gone.
        #expect(step(.wipe, false, .wipe) == .already)
        #expect(step(.clear, false, .clear) == .already)
        // Gone the other way: never a success.
        #expect(step(.wipe, false, .clear) == .undone)
        #expect(step(.clear, false, .wipe) == .undone)
        // No record: a wipe can't claim the disk was erased; a clear has nothing to do.
        #expect(step(.wipe, false, nil) == .undone)
        #expect(step(.clear, false, nil) == .already)
    }

    @Test("Wipe and Launch after a clear: nothing wiped, nothing boots")
    func startPromptAfterClear() {
        #expect(ACAppDelegate.compromiseWipe(confirmed: true, wiped: { .markCleared }) == .markCleared)
        #expect(ACAppDelegate.compromiseWipe(confirmed: true, wiped: { .alreadyWiped }) == .wiped)
        let (title, message) = ACAppDelegate.markClearedParts("api")
        #expect(title.contains("api") && message.contains("nothing was wiped"))
    }

    @Test("the disk records how the latest mark went; a new mark forgets it")
    func record() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compromise-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: root.appendingPathComponent("base.img"))
        #expect(disk.lastCompromiseResolution == nil)
        disk.markCompromised()
        disk.clearCompromisedAsFalseAlarm()
        #expect(!disk.isCompromised && disk.lastCompromiseResolution == .clear)
        disk.markCompromised()
        #expect(disk.isCompromised && disk.lastCompromiseResolution == nil)
        try disk.wipeForCompromise()
        #expect(!disk.isCompromised && disk.lastCompromiseResolution == .wipe)
        // Unmarked: whichever came second sees the first.
        #expect(ACAppDelegate.compromiseStep(.clear, marked: disk.isCompromised,
                                             last: disk.lastCompromiseResolution) == .undone)
    }

    @Test("the wipe re-checks; a clear takes an open Wipe and Launch down")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let wipe = try #require(src.range(of: "@MainActor func wipeCompromised(profile: Profile) -> CompromiseWipeStep {"))
        let wipeBody = src[wipe.upperBound...].prefix(1200)
        let check = try #require(wipeBody.range(of: "Self.compromiseStep(.wipe"))
        let erase = try #require(wipeBody.range(of: "session.wipeForCompromise()"))
        #expect(check.lowerBound < erase.lowerBound)
        // No "not marked, so done" shortcut any more.
        let resolve = try #require(src.range(of: "@MainActor func resolveCompromise("))
        let resolveBody = src[resolve.upperBound...].prefix(2500)
        #expect(!resolveBody.contains("guard SessionDisk.isCompromised(profile: profile, store: store) else { return nil }"))
        #expect(resolveBody.contains("compromiseQuestionDismissers.removeValue(forKey: profile.id)?()"))
        // Both Start prompts can be taken down.
        #expect(src.components(separatedBy: "compromiseQuestionDismissers[profile.id] = {").count == 3)
    }
}
