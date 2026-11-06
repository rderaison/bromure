import Foundation
import Testing
@testable import bromure_ac

@Suite("Old checkpoints are deleted one at a time, in small steps")
struct CheckpointReaperTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func reaper() -> CheckpointReaper { CheckpointReaper(step: 4096, stepPause: 0, filePause: 0) }
    private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    @Test("a retired checkpoint is gone, and an image it was cloned from is untouched")
    func clonedSourceSurvives() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("disk.img"), clone = dir.appendingPathComponent("1.img")
        let bytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: source)
        #expect(clonefile(source.path, clone.path, 0) == 0)
        let r = reaper()
        r.retire(clone)
        r.drain()
        #expect(!exists(clone) && !exists(clone.appendingPathExtension("deleting")))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("a hard link or a symlink is removed, and what it points at isn't shrunk")
    func onlyEverShrinksItsOwnFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 7, count: 32_768)
        let target = dir.appendingPathComponent("target.img"), other = dir.appendingPathComponent("other.img")
        try bytes.write(to: target); try bytes.write(to: other)
        let hard = dir.appendingPathComponent("1.img"), soft = dir.appendingPathComponent("2.img")
        try FileManager.default.linkItem(at: target, to: hard)
        try FileManager.default.createSymbolicLink(at: soft, withDestinationURL: other)
        let r = reaper()
        r.retire(hard); r.retire(soft)
        r.drain()
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: other) == bytes)
        #expect(!exists(hard) && !exists(hard.appendingPathExtension("deleting")))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: soft.appendingPathExtension("deleting").path)) == nil)
    }

    @Test("a sweep finishes what a quit left, and leaves live checkpoints alone")
    func sweepsLeftovers() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let left = dir.appendingPathComponent("1.img.deleting"), live = dir.appendingPathComponent("2.img")
        try Data(repeating: 1, count: 8_192).write(to: left)
        try Data(repeating: 2, count: 8_192).write(to: live)
        let r = reaper()
        r.sweep(dir); r.sweep(dir)   // twice: queued once, and no harm
        r.drain()
        #expect(!exists(left) && exists(live))
    }

    @Test("retiring what isn't there does nothing")
    func missing() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = reaper()
        r.retire(dir.appendingPathComponent("gone.img"))
        r.drain()
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }

    @Test("a store's snapshot hides what it prunes at once, and keeps the rest")
    func storePrunes() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let profile = Profile(name: "reaper", tool: .claude, authMode: .token)
        let disk = store.diskURL(for: profile)
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 16_384).write(to: disk)
        let now = Date()
        // Far older than the weekly ladder, so retention drops them.
        for weeks in 20...24 {
            _ = try store.snapshotDisk(for: profile, at: now.addingTimeInterval(-Double(weeks) * 7 * 86_400))
        }
        _ = try store.snapshotDisk(for: profile, at: now)
        let listed = store.listCheckpoints(for: profile)
        #expect(!listed.isEmpty && listed.count <= 3)
        #expect(listed.allSatisfy { $0.url.pathExtension == "img" })
        #expect(exists(disk))
        // Five beyond the ladder at once: unlinked by the purge, not shrunk.
        for _ in 0..<200 where ProfileStore.isPurgingCheckpoints(profile.id) { Thread.sleep(forTimeInterval: 0.02) }
        CheckpointReaper.shared.drain()
        let files = try FileManager.default.contentsOfDirectory(atPath: store.checkpointsDirectory(for: profile).path)
        #expect(!files.contains { $0.hasSuffix(".deleting") })
        #expect(files.filter { $0.hasSuffix(".img") }.count == listed.count)
    }

    @Test("deletes run on one background queue, never beside each other")
    func oneAtATime() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        #expect(source.contains(#"DispatchQueue(label: "io.bromure.checkpoint-reaper", qos: .background)"#))
        #expect(!source.contains("io.bromure.checkpoint-reaper\", qos: .background, attributes"))
        let prune = try #require(source.range(of: "private func prune(in dir: URL, of profile: Profile, now: Date) {"))
        #expect(source[prune.upperBound...].prefix(1400).contains("for cp in drop { reaper.retire(cp.url) }"))
        #expect(!source[prune.upperBound...].prefix(1400).contains("removeItem"))
    }
}
