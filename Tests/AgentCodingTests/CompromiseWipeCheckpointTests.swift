import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-459): "Compromise wipe leaves boot checkpoints and clears the
/// mark, so Rewind restores the contaminated disk". The wipe erased the live
/// disk and home but not `checkpoints/` (disk) or `checkpoints/home/`, then
/// cleared the mark; Rewind home… / revert put the marked boot's images back
/// and the next start didn't ask. And every delete was `try?`: one that failed
/// left the live image with the mark already gone.
@Suite("Compromise wipe: checkpoints go too, and the mark stays until everything is gone")
struct CompromiseWipeCheckpointTests {
    private func workspace() throws -> (URL, ProfileStore, Profile, SessionDisk) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wipe-\(UUID().uuidString)")
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: root.appendingPathComponent("base.img"))
        let fm = FileManager.default
        try fm.createDirectory(at: store.homeCheckpointsDirectory(for: p), withIntermediateDirectories: true)
        for url in [store.diskURL(for: p), store.homeImageURL(for: p),
                    store.checkpointsDirectory(for: p).appendingPathComponent("1700000000.img"),
                    store.homeCheckpointsDirectory(for: p).appendingPathComponent("1700000000.img"),
                    disk.efiVarsURL, disk.savedStateURL] {
            try Data("contaminated".utf8).write(to: url)
        }
        disk.markCompromised()
        return (root, store, p, disk)
    }

    @Test("disk and home checkpoints are erased with the images; nothing is left to rewind to")
    func checkpointsErased() throws {
        let (root, store, p, disk) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!store.listCheckpoints(for: p).isEmpty && !store.listHomeCheckpoints(for: p).isEmpty)
        try disk.wipeForCompromise()
        #expect(!disk.isCompromised)
        #expect(store.listCheckpoints(for: p).isEmpty)
        #expect(store.listHomeCheckpoints(for: p).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.checkpointsDirectory(for: p).path))
        #expect(!FileManager.default.fileExists(atPath: store.diskURL(for: p).path))
        #expect(!FileManager.default.fileExists(atPath: store.homeImageURL(for: p).path))
        #expect(!FileManager.default.fileExists(atPath: disk.efiVarsURL.path))
        #expect(!disk.hasSavedState)
    }

    @Test("a delete that fails keeps the mark and says what is left")
    func failedDeleteKeepsMark() throws {
        let (root, store, p, disk) = try workspace()
        // A read-only checkpoints folder: its images can't be removed.
        let locked = store.homeCheckpointsDirectory(for: p)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(throws: SessionDisk.WipeIncomplete.self) { try disk.wipeForCompromise() }
        #expect(disk.isCompromised)
        #expect(!store.listHomeCheckpoints(for: p).isEmpty)
        do { try disk.wipeForCompromise() } catch let e as SessionDisk.WipeIncomplete {
            #expect(e.left.map(\.lastPathComponent) == ["checkpoints"])
        }
        // Unlocked: the retry finishes it.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try disk.wipeForCompromise()
        #expect(!disk.isCompromised && store.listHomeCheckpoints(for: p).isEmpty)
    }

    @Test("a wipe that didn't finish is no success: still marked, nothing boots")
    @MainActor func failedIsNotWiped() {
        #expect(ACAppDelegate.compromiseWipe(confirmed: true, wiped: { .failed(["checkpoints"]) }) == .failed(["checkpoints"]))
        #expect(ACAppDelegate.wipeFailedMessage(["checkpoints"]).contains("checkpoints"))
        #expect(ACAppDelegate.wipeFailedMessage(["checkpoints"]).contains("still marked compromised"))
    }
}
