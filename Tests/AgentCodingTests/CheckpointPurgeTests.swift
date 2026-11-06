import Foundation
import Testing
@testable import bromure_ac

/// A server whose checkpoints kept stalling APFS while the reaper shrank them
/// (a 128 GB home, grown over time, with the full ladder of checkpoints) was
/// cleared by `rm`-ing each one from a shell. ⌥ on the machine menu now does
/// that: every checkpoint unlinked whole, one after another, off the main thread.
@Suite("Delete all checkpoints")
struct CheckpointPurgeTests {
    private static let top = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.top.appendingPathComponent(path), encoding: .utf8)
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func touch(_ url: URL) { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }

    @Test("lists the disk's and the home's checkpoints, kept or retired, and nothing else")
    func lists() throws {
        let cps = try tempDir()
        let home = cps.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ws = cps.deletingLastPathComponent()
        for n in ["1700000000.img", "1700000100.img.deleting"] { touch(cps.appendingPathComponent(n)) }
        touch(home.appendingPathComponent("1700000200.img"))
        // Not checkpoints: other names, a folder, a link to the live image.
        for n in ["disk.img", "notes.txt", "1700000300.img.tmp", "abc.img", "-1.img", ".img"] { touch(cps.appendingPathComponent(n)) }
        try FileManager.default.createDirectory(at: cps.appendingPathComponent("1700000400.img"), withIntermediateDirectories: false)
        let live = ws.appendingPathComponent("live-\(UUID().uuidString).img")
        touch(live)
        try FileManager.default.createSymbolicLink(at: cps.appendingPathComponent("1700000500.img"), withDestinationURL: live)

        let found = ProfileStore.checkpointFiles(in: [cps, home]).map(\.lastPathComponent)
        #expect(Set(found) == ["1700000000.img", "1700000100.img.deleting", "1700000200.img"])
        try? FileManager.default.removeItem(at: live)
    }

    @Test("unlinks each, one by one, and says what took how long")
    func unlinks() async throws {
        let cps = try tempDir()
        let urls = (0..<4).map { cps.appendingPathComponent("17000000\($0)0.img") }
        urls.forEach(touch)
        let gone = urls[2]
        try FileManager.default.removeItem(at: gone)   // already deleted (the reaper got it): not a failure
        let result = await Task.detached {
            var seen: [Int] = []
            let r = ProfileStore.unlinkOneByOne(urls) { i, _, took in seen.append(i); #expect(took >= 0) }
            return (r, seen)
        }.value
        #expect(result.0.deleted == 4 && result.0.failed.isEmpty)
        #expect(result.1 == [0, 1, 2, 3])
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("only with ⌥ held, warns before, runs off main, and no rewind reads a checkpoint meanwhile")
    func wiring() throws {
        let w = try source("Sources/AgentCoding/UnifiedSessionWindow.swift")
        #expect(w.contains("if let onDeleteCheckpoints, NSEvent.modifierFlags.contains(.option) {"))
        #expect(w.contains("self?.acDelegate?.deleteAllCheckpoints(id, from: self)"))
        let ac = try source("Sources/AgentCoding/BromureAC.swift")
        let start = try #require(ac.range(of: "private func purgeCheckpoints("))
        #expect(ac[start.upperBound...].prefix(400).contains("ProfileStore.purgeCheckpointsInBackground(files"))
        #expect(ac.contains("the app and the other machines may stall"))
        // Every revert path refuses while a delete runs, the store's own last.
        #expect(ac.components(separatedBy: "ProfileStore.isPurgingCheckpoints(p.id)").count - 1 >= 3)
        #expect(ac.contains("if ProfileStore.isPurgingCheckpoints(profile.id) {"))
        #expect(ac.contains("guard !ProfileStore.isPurgingCheckpoints(p.id) else { return }   // the modal ran the run loop too"))
        let store = try source("Sources/AgentCoding/Profile.swift")
        let revert = try #require(store.range(of: "private func revertImage("))
        let rb = store[revert.upperBound...].prefix(900)
        let guardAt = try #require(rb.range(of: "guard !Self.isPurgingCheckpoints(profile.id)"))
        let removeAt = try #require(rb.range(of: "try fm.removeItem(at: image)"))
        #expect(guardAt.lowerBound < removeAt.lowerBound)
        let bg = try #require(store.range(of: "static func purgeCheckpointsInBackground("))
        #expect(store[bg.upperBound...].prefix(900).contains("DispatchQueue.global(qos: .utility).async"))
        // No alert goes up as a second sheet: that throws.
        let purge = try #require(ac.range(of: "func deleteAllCheckpoints("))
        let purgeBody = ac[purge.upperBound...].prefix { _ in true }
        let end = try #require(purgeBody.range(of: "private func present("))
        #expect(!purgeBody[..<end.lowerBound].contains("beginSheetModal("))
        #expect(ac.contains("if let window, window.attachedSheet == nil {\n            alert.beginSheetModal(for: window, completionHandler: done)"))
    }

    // MARK: A home resize

    private func waitForPurge(_ id: UUID) async throws {
        for _ in 0..<200 where ProfileStore.isPurgingCheckpoints(id) { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)   // `done` hops to main
    }

    @Test("a save that grows the home past its image deletes the home's checkpoints; one that doesn't keeps them")
    @MainActor func resizeDeletes() async throws {
        let (store, root) = HomeSizeAfterImageTests.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = Profile(name: "grow", tool: .claude, authMode: .token)
        p.homeModel = .ext4
        p.homeImageGB = 16
        try store.save(p)
        try HomeSizeAfterImageTests.makeImage(store, p, gb: 16)
        let home = store.homeCheckpointsDirectory(for: p)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let cps = ["1700000000.img", "1700000100.img.deleting"].map { home.appendingPathComponent($0) }
        cps.forEach(touch)
        let disk = store.checkpointsDirectory(for: p).appendingPathComponent("1700000200.img")
        touch(disk)

        try store.save(p)                       // same size: nothing goes
        try await waitForPurge(p.id)
        #expect(cps.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        p.homeImageGB = 32
        try store.save(p)                       // grows past the 16 GB image
        try await waitForPurge(p.id)
        #expect(cps.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: disk.path))   // the system disk's stay
        #expect(FileManager.default.fileExists(atPath: store.homeImageURL(for: p).path))
    }

    @Test("the grow at boot deletes what's left of the smaller home's checkpoints")
    func growBackstop() throws {
        let d = try source("Sources/AgentCoding/SessionDisk.swift")
        let g = try #require(d.range(of: "public func growHomeImageIfNeeded()"))
        let body = d[g.upperBound...].prefix(2200)
        let grow = try #require(body.range(of: "try handle.truncate(atOffset: target)"))
        let purge = try #require(body.range(of: "ProfileStore.purgeCheckpointsInBackground(stale"))
        #expect(grow.lowerBound < purge.lowerBound)
        #expect(body.contains("store.homeCheckpointsDirectory(for: profile)"))
    }
}
