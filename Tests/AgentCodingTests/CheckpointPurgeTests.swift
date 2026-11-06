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
        for n in ["disk.img", "notes.txt", "1700000300.img.tmp", "abc.img"] { touch(cps.appendingPathComponent(n)) }
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
        let body = ac[start.upperBound...].prefix(1200)
        #expect(body.contains("Task.detached(priority: .utility)"))
        #expect(body.contains("ProfileStore.unlinkOneByOne(files)"))
        #expect(ac.contains("the app and the other machines may stall"))
        // Every revert path refuses while a purge runs.
        #expect(ac.components(separatedBy: "checkpointPurges.contains(p.id)").count - 1 >= 2)
        #expect(ac.contains("if checkpointPurges.contains(profile.id) {"))
    }
}
