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
    func bigHome() async throws {
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
        #expect(store.pruneCheckpoints(for: p, now: Date()))
        try await waitForPurge(p.id)
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

    @Test("a backlog beyond the ladder is unlinked whole at launch, once")
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
        // The mark is written once `done` reaches the main thread.
        for _ in 0..<250 where (try? String(contentsOf: store.checkpointLadderMark, encoding: .utf8)) != ProfileStore.ladderGeneration {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try String(contentsOf: store.checkpointLadderMark, encoding: .utf8) == ProfileStore.ladderGeneration)
        #expect(store.settleCheckpointBacklog([p], now: now) == 0)   // done once
    }

    @Test("the one a new day ages out is renamed, then unlinked, with the home's")
    func dailyPrune() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "day", tool: .claude, authMode: .token)
        try makeDisk(store, p)
        let img = store.homeImageURL(for: p)
        try Data("home".utf8).write(to: img)
        let now = Date()
        for d in 0...3 {
            let at = now.addingTimeInterval(-Double(d) * 86_400)
            _ = try store.snapshotDisk(for: p, at: at, automatic: true)
            _ = try store.snapshotHomeImage(for: p, at: at, automatic: true)
        }
        #expect(store.listCheckpoints(for: p).count == 4 && store.listHomeCheckpoints(for: p).count == 4)
        #expect(store.pruneCheckpoints(for: p, now: now))
        #expect(store.listCheckpoints(for: p).count == 3 && store.listHomeCheckpoints(for: p).count == 3)   // at once
        try await waitForPurge(p.id)
        #expect(files(store.checkpointsDirectory(for: p)).filter { $0.hasSuffix(".img") }.count == 3)
        #expect(!files(store.checkpointsDirectory(for: p)).contains { $0.hasSuffix(".deleting") })
        #expect(!files(store.homeCheckpointsDirectory(for: p)).contains { $0.hasSuffix(".deleting") })
        #expect(FileManager.default.fileExists(atPath: img.path) && FileManager.default.fileExists(atPath: store.diskURL(for: p).path))
        #expect(!store.pruneCheckpoints(for: p, now: now))   // nothing beyond
    }

    @Test("a checkpoint whose .deleting name is taken isn't renamed over it")
    func renameCollision() throws {
        let dir = try tempRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        let cp = dir.appendingPathComponent("1700000000.img"), left = dir.appendingPathComponent("1700000000.img.deleting")
        let other = dir.appendingPathComponent("1700000100.img")
        for u in [cp, left, other] { try Data(u.lastPathComponent.utf8).write(to: u) }
        let out = ProfileStore.takeOutOfList([cp, left, other])
        #expect(out == [cp, left, other.appendingPathExtension("deleting")])
        #expect(try String(contentsOf: left, encoding: .utf8) == "1700000000.img.deleting")   // not replaced
    }

    @Test("the days are calendar days: the day before yesterday's morning stays")
    func calendarDays() {
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let dayBefore = cal.date(byAdding: .day, value: -2, to: cal.date(bySettingHour: 7, minute: 0, second: 0, of: now)!)!
        let older = cal.date(byAdding: .day, value: -3, to: now)!
        let keep = ProfileStore.checkpointRetention([now, dayBefore, older], now: now)
        #expect(keep == [now, dayBefore])
    }

    /// The finding: a delete under way (the launch clearing a backlog) made
    /// the session start's checkpoints return nil, and the session start
    /// doesn't come again, so that boot had no rollback point.
    @Test("a session start's checkpoints wait for a delete under way, then are taken")
    func sessionStartWaits() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "waits", tool: .claude, authMode: .token)
        try makeDisk(store, p)
        try Data("home".utf8).write(to: store.homeImageURL(for: p))
        let gate = DispatchSemaphore(value: 0)
        ProfileStore.purgeQueue.async { gate.wait() }
        #expect(ProfileStore.purgeCheckpointsInBackground([root.appendingPathComponent("none.img")], of: p.id, name: p.name, why: "test"))
        final class Flag: @unchecked Sendable { let lock = NSLock(); var done = false
            func set() { lock.lock(); done = true; lock.unlock() }
            var value: Bool { lock.lock(); defer { lock.unlock() }; return done } }
        let finished = Flag()
        store.takeSessionStartCheckpoints(for: p) { finished.set() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!finished.value && store.listCheckpoints(for: p).isEmpty)   // held while the delete runs
        gate.signal()
        for _ in 0..<250 where !finished.value { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(finished.value)
        #expect(store.listCheckpoints(for: p).count == 1)
        #expect(store.listHomeCheckpoints(for: p).count == 1)
    }

    @Test("with no delete under way, a session start's checkpoints are taken at once")
    func sessionStartNow() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "now", tool: .claude, authMode: .token)
        try makeDisk(store, p)
        try Data("home".utf8).write(to: store.homeImageURL(for: p))
        final class Flag: @unchecked Sendable { let lock = NSLock(); var done = false
            func set() { lock.lock(); done = true; lock.unlock() }
            var value: Bool { lock.lock(); defer { lock.unlock() }; return done } }
        let finished = Flag()
        store.takeSessionStartCheckpoints(for: p) { finished.set() }
        for _ in 0..<250 where !finished.value { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(store.listCheckpoints(for: p).count == 1 && store.listHomeCheckpoints(for: p).count == 1)
    }

    @Test("launch settles the backlog; a session start takes its checkpoints as automatic")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("store.settleCheckpointBacklog(profiles)"))
        #expect(ac.contains("self.store.takeSessionStartCheckpoints(for: profile)"))
        let store = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        // No checkpoint is shrunk by the reaper any more: every delete is a
        // plain unlink on the purge queue.
        #expect(!store.contains("reaper.retire(") && !store.contains("reaper.sweep("))
        let take = try #require(store.range(of: "func takeSessionStartCheckpoints("))
        let body = store[take.upperBound...].prefix(1800)
        let disk = try #require(body.range(of: "snapshotDisk(for: profile, at: now, automatic: true)"))
        let home = try #require(body.range(of: "snapshotHomeImage(for: profile, at: now, automatic: true)"))
        let prune = try #require(body.range(of: "pruneCheckpoints(for: profile, now: now)"))
        #expect(disk.lowerBound < home.lowerBound && home.lowerBound < prune.lowerBound)
        #expect(store.contains("precondition(!Thread.isMainThread"))
    }
}
