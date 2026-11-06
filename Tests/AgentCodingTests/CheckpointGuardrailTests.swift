import Foundation
import Testing
@testable import bromure_ac

/// After a 128 GB home with 14 clones stalled APFS on every delete: fewer
/// checkpoints, one automatic one a day, none of a very large home, none while
/// a delete runs, and a backlog unlinked whole off the main thread.
@Suite("Checkpoint guardrails", .serialized)
struct CheckpointGuardrailTests {
    private func tempRoot() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func makeDisk(_ store: ProfileStore, _ p: Profile) throws {
        let disk = store.diskURL(for: p)
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8192).write(to: disk)
    }
    private func waitForPurge(_ id: UUID) async throws {
        for _ in 0..<250 where ProfileStore.isPurgingCheckpoints(id) { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    private func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test("an automatic checkpoint is taken once a day; one asked for, always")
    func oncePerDay() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "daily", tool: .claude, authMode: .token)
        try makeDisk(store, p)
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        #expect(try store.snapshotDisk(for: p, at: morning, automatic: true) != nil)
        #expect(try store.snapshotDisk(for: p, at: morning.addingTimeInterval(3600), automatic: true) == nil)
        #expect(try store.snapshotDisk(for: p, at: morning.addingTimeInterval(7200)) != nil)
        #expect(try store.snapshotDisk(for: p, at: morning.addingTimeInterval(86_400), automatic: true) != nil)
    }

    @Test("a home over 64 GB gets no automatic checkpoint, its old ones still age out")
    func bigHome() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "big", tool: .claude, authMode: .token)
        let img = store.homeImageURL(for: p)
        try FileManager.default.createDirectory(at: img.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: img.path, contents: nil)
        let h = try FileHandle(forWritingTo: img)
        try h.truncate(atOffset: UInt64(ProfileStore.automaticHomeCheckpointCap) + 1)   // sparse
        try h.close()
        let old = Date().addingTimeInterval(-30 * 86_400)
        #expect(try store.snapshotHomeImage(for: p, at: old) != nil)   // asked for: taken
        #expect(try store.snapshotHomeImage(for: p, at: old.addingTimeInterval(86_400)) != nil)
        #expect(try store.snapshotHomeImage(for: p, at: Date(), automatic: true) == nil)
        CheckpointReaper.shared.drain()
        // The newest stays (the last session's); the older one aged out.
        #expect(store.listHomeCheckpoints(for: p).map(\.createdAt) == [Date(timeIntervalSince1970: floor(old.timeIntervalSince1970 + 86_400))])
    }

    @Test("no checkpoint while the workspace's checkpoints are being deleted")
    func noneWhilePurging() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "busy", tool: .claude, authMode: .token)
        try makeDisk(store, p)
        let gate = DispatchSemaphore(value: 0)
        ProfileStore.purgeQueue.async { gate.wait() }   // the purge below waits its turn, marked as running
        #expect(ProfileStore.purgeCheckpointsInBackground([root.appendingPathComponent("none.img")], of: p.id, name: p.name, why: "test"))
        #expect(try store.snapshotDisk(for: p, at: Date()) == nil)
        #expect(try store.snapshotHomeImage(for: p, at: Date()) == nil)
        #expect(store.listCheckpoints(for: p).isEmpty)
        gate.signal()
        try await waitForPurge(p.id)
        #expect(try store.snapshotDisk(for: p, at: Date()) != nil)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        let snap = try #require(src.range(of: "private func snapshotImage("))
        let body = src[snap.upperBound...].prefix(1400)
        let g = try #require(body.range(of: "guard !Self.isPurgingCheckpoints(profile.id) else {"))
        let clone = try #require(body.range(of: "try Self.cloneItem(at: image, to: dst)"))
        #expect(g.lowerBound < clone.lowerBound)
    }

    @Test("a backlog beyond the ladder is renamed out of the list and unlinked whole")
    func backlogUnlinked() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let off = CheckpointReaper(step: 4096, stepPause: 0, filePause: 0, enabled: false)
        let keepAll = ProfileStore(rootDir: root, reaper: off)
        let p = Profile(name: "backlog", tool: .claude, authMode: .token)
        try makeDisk(keepAll, p)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        for d in 1...13 { _ = try keepAll.snapshotDisk(for: p, at: now.addingTimeInterval(-Double(d) * 86_400)) }
        #expect(keepAll.listCheckpoints(for: p).count == 13)
        // The reaper off: launch marks it so the next run settles the backlog.
        #expect(keepAll.settleCheckpointBacklog([p], now: now) == 0)
        #expect(try String(contentsOf: keepAll.checkpointLadderMark, encoding: .utf8) == "off")

        let dir = keepAll.checkpointsDirectory(for: p)
        let leftover = dir.appendingPathComponent("1600000000.img.deleting")
        try Data("x".utf8).write(to: leftover)
        let store = ProfileStore(rootDir: root)
        let backlog = store.checkpointBacklog(for: p, now: now)
        #expect(backlog.count == 13 - 2 + 1)   // keeps yesterday's and the day before's
        #expect(store.settleCheckpointBacklog([p], now: now) == 1)
        try await waitForPurge(p.id)
        #expect(files(dir).count == 2 && files(dir).allSatisfy { $0.hasSuffix(".img") })
        #expect(try String(contentsOf: store.checkpointLadderMark, encoding: .utf8) == ProfileStore.ladderGeneration)
        #expect(store.settleCheckpointBacklog([p], now: now) == 0)   // done once
    }

    @Test("launch settles the backlog; a session start takes its checkpoints as automatic")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("store.settleCheckpointBacklog(profiles)"))
        #expect(ac.contains("store.snapshotDisk(for: profile, at: now, automatic: true)"))
        #expect(ac.contains("store.snapshotHomeImage(for: profile, at: now, automatic: true)"))
        let store = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        let prune = try #require(store.range(of: "private func prune(in dir: URL, of profile: Profile, now: Date) {"))
        let body = store[prune.upperBound...].prefix(1400)
        let bulk = try #require(body.range(of: "if drop.count > 1 {"))
        let purge = try #require(body.range(of: "Self.purgeCheckpointsInBackground(retired"))
        let reap = try #require(body.range(of: "reaper.retire(cp.url)"))
        #expect(bulk.lowerBound < purge.lowerBound && purge.lowerBound < reap.lowerBound)
        #expect(store.contains("precondition(!Thread.isMainThread"))
    }
}
