import Foundation
import NIOConcurrencyHelpers

extension Daemon {
    /// /state as one recent build serves every caller (macOS:
    /// stampedStateSnapshot's cache): a build under 0.4 s old is reused
    /// while the mutation generation holds, and callers arriving during a
    /// build share it instead of each running their own. The generation is
    /// read before building: a mutation landing during the build marks it
    /// stale (conservative), never a stale build fresh. The TTL is under the
    /// feed's 0.5 s wake, so a lone subscriber still sees each change.
    // @port ACAutomationServer.stampedStateSnapshot() h=9092e4ffef3827ea @f127f8ab
    func cachedStateBody() async -> JSONValue {
        let generation = StateGeneration.current
        if let c = stateCache, c.generation == generation, ContinuousClock.now - c.at < .milliseconds(400) {
            return c.body
        }
        if let b = stateBuilding, b.generation == generation { return await b.task.value }
        let task = Task { await self.stateBody() }
        stateBuilding = (task, generation)
        let body = await task.value
        if stateBuilding?.task == task { stateBuilding = nil }
        if (stateCache?.generation ?? .min) <= generation { stateCache = (body, .now, generation) }
        return body
    }
}

/// /state/subscribe's one producer, however many subscribe (macOS:
/// ACAutomationServer's push feed): while anyone is subscribed it builds
/// the state every 0.5 s and compares each section with the last build's;
/// a change is one delta frame of the sections that changed, numbered.
/// Subscribers only send: a whole frame to start from (built once per
/// change, shared), the deltas past what they sent, or a whole frame when
/// they fell behind what's kept (or don't take deltas).
// @port-skip linux-only: the push feed's state across async subscribers (macOS: an NSCondition and a thread)
final class StateFeed: @unchecked Sendable {
    static let deltasKept = 16

    private struct State {
        var seq = 0
        var subscribers = 0
        var running = false
        /// The latest build, the change it's at, and its whole frame once built.
        var snapshot: JSONValue?
        var snapshotSeq = 0
        var whole: (seq: Int, frame: Data, at: ContinuousClock.Instant)?
        /// Each section's comparable bytes in the latest build.
        var sections: [String: Data] = [:]
        /// The last deltas, by the change they make.
        var deltas: [(seq: Int, frame: Data)] = []
    }
    private let state = NIOLockedValueBox(State())

    /// One more subscriber; the first starts the producer, which builds
    /// with `build` (nil: the daemon is gone, and it stops).
    // @port ACAutomationServer.feedSubscribe() h=97d02b6599f5601b @61818379
    func subscribe(build: @escaping @Sendable () async -> JSONValue?) {
        let start = state.withLockedValue { s -> Bool in
            s.subscribers += 1
            defer { s.running = true }
            return !s.running
        }
        if start { Task { await self.produce(build) } }
    }

    // @port ACAutomationServer.feedUnsubscribe() h=0c3fb88f71eb4b87 @61818379
    func unsubscribe() { state.withLockedValue { $0.subscribers -= 1 } }

    // @port ACAutomationServer.feedLoop() h=003e1c58b4116ab2 @61818379
    private func produce(_ build: @Sendable () async -> JSONValue?, pause: Duration = .milliseconds(500)) async {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        while true {
            let previous: [String: Data]? = state.withLockedValue { s in
                guard s.subscribers > 0 else {
                    s = State(seq: s.seq, subscribers: s.subscribers)   // the numbering goes on; the rest goes
                    return nil
                }
                return s.sections
            }
            guard let previous else { return }
            guard let snapshot = await build() else {
                state.withLockedValue { s in s = State(seq: s.seq, subscribers: s.subscribers) }
                return
            }
            let sections = Daemon.comparableSections(snapshot, enc)
            let (set, unset) = Daemon.changedSections(from: previous, to: sections)
            let first = state.withLockedValue { $0.snapshotSeq == 0 }
            let delta = !set.isEmpty || !unset.isEmpty || first
                ? Daemon.deltaFrame(snapshot: snapshot, set: set, unset: unset, enc) : nil
            state.withLockedValue { s in
                s.snapshot = snapshot
                s.sections = sections
                guard !set.isEmpty || !unset.isEmpty || s.snapshotSeq == 0 else { return }
                s.seq += 1
                s.snapshotSeq = s.seq
                s.whole = nil
                if let delta {
                    s.deltas.append((s.seq, delta))
                    if s.deltas.count > Self.deltasKept { s.deltas.removeFirst(s.deltas.count - Self.deltasKept) }
                } else {
                    s.deltas = []                  // a gap: whoever is behind gets a whole frame
                }
            }
            try? await Task.sleep(for: pause)
        }
    }

    /// Waits up to `timeout` for a change past `seq`; the change it's at now.
    // @port ACAutomationServer.waitForFeed(after: Int, timeout: TimeInterval) h=204e4af8fe64765e @61818379
    func wait(after seq: Int, timeout: Duration) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while true {
            let now = state.withLockedValue { $0.seq }
            if now > seq || ContinuousClock.now >= deadline || Task.isCancelled { return now }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The deltas that take a client from `seq` to now, in order; nil when
    /// some are no longer kept (it needs a whole frame).
    // @port ACAutomationServer.feedDeltas(after: Int) h=9b91d8c7722cca35 @61818379
    func deltas(after seq: Int) -> [Data]? {
        state.withLockedValue { s in
            let wanted = s.deltas.filter { $0.seq > seq }
            guard let first = wanted.first, first.seq == seq + 1, wanted.last?.seq == s.seq else { return nil }
            return wanted.map(\.frame)
        }
    }

    /// The whole frame of the latest build, and the change it's at: built
    /// once per change and shared, and again for a keepalive only when
    /// it's older than one (a VM's uptime moves on in it).
    // @port ACAutomationServer.feedWholeFrame() h=f3b514d0a85cf218 @61818379
    func wholeFrame() -> (seq: Int, frame: Data)? {
        let cached: (seq: Int, frame: Data)?? = state.withLockedValue { s in
            if let w = s.whole, w.seq == s.snapshotSeq, ContinuousClock.now - w.at < .seconds(10) { return .some((w.seq, w.frame)) }
            return s.snapshot == nil ? .some(nil) : nil
        }
        if let cached { return cached }
        guard let (snapshot, seq) = state.withLockedValue({ s in s.snapshot.map { ($0, s.snapshotSeq) } }) else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let json = try? enc.encode(snapshot) else { return nil }
        let frame = Daemon.frame(json, delta: false)
        state.withLockedValue { s in if s.snapshotSeq == seq { s.whole = (seq, frame, .now) } }
        return (seq, frame)
    }

    /// Tests: subscribers counted, and whether the producer runs.
    // @port-skip linux-only: tests
    var running: (subscribers: Int, running: Bool) { state.withLockedValue { ($0.subscribers, $0.running) } }
}
