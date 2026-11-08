import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// /state/subscribe's one producer (macOS: the push feed): one build every
/// 0.5 s however many subscribe; a change is one numbered delta of the
/// sections that changed; a subscriber behind what's kept gets nil (a
/// whole frame); the whole frame is the latest build; the producer stops
/// with its last subscriber.
@Suite("State feed: one producer")
struct StateFeedTests {
    final class Source: @unchecked Sendable {
        let value = NIOLockedValueBox<JSONValue>(["vms": .array([]), "tasks": .array([]), "generation": 1])
        let builds = NIOLockedValueBox(0)
        func build() -> JSONValue {
            builds.withLockedValue { $0 += 1 }
            return value.withLockedValue { $0 }
        }
        func set(_ k: String, _ v: JSONValue) {
            value.withLockedValue { if case .object(var o) = $0 { o[k] = v; $0 = .object(o) } }
        }
    }

    /// A frame's JSON: [len:u32be][flag][payload], payload raw DEFLATE when flag bit 0.
    static func decode(_ frame: Data) throws -> (delta: Bool, json: JSONValue) {
        let b = [UInt8](frame)
        let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        #expect(len == b.count - 4)
        var payload = Data(b[5...])
        if b[4] & 1 != 0 { payload = try #require(NPMRegistryTransforms.inflateRaw(payload, limit: 1 << 20)) }
        return (b[4] & 2 != 0, try JSONDecoder().decode(JSONValue.self, from: payload))
    }

    @Test func aChangeIsOneDeltaOfWhatChanged() async throws {
        let feed = StateFeed(), src = Source()
        feed.subscribe { src.build() }
        defer { feed.unsubscribe() }
        let first = await feed.wait(after: 0, timeout: .seconds(5))
        #expect(first == 1)
        let whole = try #require(feed.wholeFrame())
        #expect(whole.seq == 1)
        let w = try Self.decode(whole.frame)
        #expect(!w.delta && w.json["tasks"] == .array([]))

        // Unchanged builds (the stamps don't count): no new change.
        src.set("generation", 2)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await feed.wait(after: 1, timeout: .milliseconds(10)) == 1)

        src.set("tasks", .array(["t1"]))
        #expect(await feed.wait(after: 1, timeout: .seconds(5)) == 2)
        let frames = try #require(feed.deltas(after: 1))
        #expect(frames.count == 1)
        let d = try Self.decode(frames[0])
        guard case .object(let set) = d.json["set"] ?? .null else { Issue.record("\(d.json)"); return }
        #expect(d.delta && Set(set.keys).subtracting(["generation", "epoch"]) == ["tasks"])
        #expect(set["tasks"] == .array(["t1"]) && set["vms"] == nil, "only what changed (and the stamps)")
        #expect(feed.deltas(after: 0)?.count == 2, "from the start: both kept deltas")
        #expect(try Self.decode(try #require(feed.wholeFrame()).frame).json["tasks"] == .array(["t1"]))
    }

    @Test func behindWhatsKeptMeansAWholeFrame() async throws {
        let feed = StateFeed(), src = Source()
        feed.subscribe { src.build() }
        defer { feed.unsubscribe() }
        var seq = await feed.wait(after: 0, timeout: .seconds(5))
        for i in 0...StateFeed.deltasKept {
            src.set("tasks", .array([.string("t\(i)")]))
            seq = await feed.wait(after: seq, timeout: .seconds(5))
        }
        #expect(seq == StateFeed.deltasKept + 2)
        #expect(feed.deltas(after: 1) == nil, "the first deltas are gone")
        #expect(feed.deltas(after: seq - 1)?.count == 1)
    }

    @Test func oneProducerForManySubscribersAndItStopsWithTheLast() async throws {
        let feed = StateFeed(), src = Source()
        for _ in 0..<5 { feed.subscribe { src.build() } }
        try await Task.sleep(for: .milliseconds(1100))
        let builds = src.builds.withLockedValue { $0 }
        #expect(builds >= 2 && builds <= 4, "one build per 0.5 s, not one per subscriber: \(builds)")
        #expect(feed.running == (5, true))
        for _ in 0..<5 { feed.unsubscribe() }
        for _ in 0..<100 where feed.running.running { try await Task.sleep(for: .milliseconds(20)) }
        #expect(feed.running == (0, false))
        let after = src.builds.withLockedValue { $0 }
        try await Task.sleep(for: .milliseconds(700))
        #expect(src.builds.withLockedValue { $0 } == after, "no builds without subscribers")
        // A new subscriber starts it again, numbering on.
        feed.subscribe { src.build() }
        defer { feed.unsubscribe() }
        #expect(await feed.wait(after: 1, timeout: .seconds(5)) == 2)
    }
}

extension DaemonGlobalSuites {
    /// /state's build cache (macOS: stampedStateSnapshot): a build under
    /// 0.4 s old serves while the mutation generation holds; a mutation, or
    /// the TTL, makes the next caller build afresh.
    @Suite("State build cache", .serialized)
    struct StateCacheTests {
        static func names(_ body: JSONValue) -> [String] {
            guard case .array(let ws) = body["workspaces"] ?? .null else { return [] }
            return ws.compactMap { $0["name"]?.stringValue }.sorted()
        }

        @Test func aRecentBuildServesUntilAMutation() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let before = Self.names(await d.cachedStateBody())
            var other = RepairMarksTests.stopped()
            other.name = "cache-probe"
            try await d.registerForTesting(other)
            // No mutation noted: the build of a moment ago still serves.
            #expect(Self.names(await d.cachedStateBody()) == before)
            StateGeneration.noteMutation()
            let after = Self.names(await d.cachedStateBody())
            #expect(after.contains("cache-probe") && after.count == before.count + 1, "\(after)")
            // And past the TTL without one.
            var third = RepairMarksTests.stopped()
            third.name = "cache-probe-2"
            try await d.registerForTesting(third)
            try await Task.sleep(for: .milliseconds(450))
            #expect(Self.names(await d.cachedStateBody()).contains("cache-probe-2"))
            _ = rec
            await d.shutdown()
        }
    }
}
