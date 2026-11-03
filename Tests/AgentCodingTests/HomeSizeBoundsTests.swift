import Foundation
import Testing
@testable import bromure_ac

/// PR #59 (#57): a workspace's home can start below the 64 GB default. Before
/// its image exists (a new workspace, or one whose home was erased) the size
/// field floors at 8 GB, what SessionDisk creates an image at; once it
/// exists, at the image's size (grow-only).
@Suite("Home folder size: 8 GB until the image exists, grow-only after")
struct HomeSizeBoundsTests {
    typealias B = ProfileEditorView.HomeSizeBounds

    @Test("no image yet: from 8 GB, shown at the default until set")
    func beforeImage() {
        let b = B(existingGB: nil, defaultGB: 64)
        #expect(b.floor == 8 && b.current == 64)
        #expect(b.shown(nil) == 64)
        #expect(b.setting(for: 8, saved: nil) == 8)
        #expect(b.setting(for: 4, saved: nil) == 8)          // clamped to the floor
        #expect(b.setting(for: 64, saved: nil) == nil)       // the default: keeps following it
        #expect(b.setting(for: 64, saved: 16) == 64)         // explicitly back to 64
        #expect(b.setting(for: 4096, saved: nil) == 1024)
        #expect(b.shown(16) == 16)
    }

    @Test("an image exists: its size is the floor (a home can't shrink)")
    func afterImage() {
        let b = B(existingGB: 64, defaultGB: 64)
        #expect(b.floor == 64 && b.current == 64)
        #expect(b.setting(for: 16, saved: nil) == nil)       // clamped up to 64 = no change
        #expect(b.shown(16) == 64)                           // an older smaller setting shows the real size
        #expect(b.setting(for: 128, saved: nil) == 128)
        let small = B(existingGB: 16, defaultGB: 64)
        #expect(small.floor == 16 && small.shown(nil) == 16)
    }

    @Test("SessionDisk creates what the field allows")
    func matchesSessionDisk() {
        var p = Profile(name: "h", tool: .claude, authMode: .token)
        p.homeImageGB = ProfileEditorView.minHomeGB
        let store = ProfileStore(rootDir: FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)"))
        let disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        #expect(disk.homeImageTargetBytes == 8 << 30)
    }

    @Test("a new home is 16 GB by default; a legacy home's migration still gets 64 GB")
    func defaultSize() {
        #expect(SessionDisk.defaultHomeImageGB == 16)
        let store = ProfileStore(rootDir: FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)"))
        var p = Profile(name: "h", tool: .claude, authMode: .token)
        var disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        #expect(disk.homeImageTargetBytes == UInt64(SessionDisk.resolvedHomeImageGB()) << 30)
        disk.migrateHomeThisBoot = true
        #expect(disk.homeImageTargetBytes >= 64 << 30)
        p.homeImageGB = 24                                   // its own size wins, migrating or not
        disk = SessionDisk(profile: p, store: store, baseDiskURL: URL(fileURLWithPath: "/dev/null"))
        disk.migrateHomeThisBoot = true
        #expect(disk.homeImageTargetBytes == 24 << 30)
    }

    @Test("an erase or reset redraws the size field")
    func refreshAfterErase() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/ProfileViews.swift"), encoding: .utf8)
        #expect(src.contains("handler: changing(context.onResetHome)"))
        #expect(src.contains("onStorageChanged: { storageRevision += 1 }"))
        #expect(src.contains("_ = storageRevision"))
    }
}
