import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Event automations poll every tick once an early poll
/// has been requested". `repollSoon` (a run finished, a refusal requeued)
/// clears `lastPolledAt` so the next tick polls; that poll saw the nil it
/// started from and saved it back, so every tick after polled GitHub or
/// Linear again -- failed polls included -- and the nil outlived a relaunch.
@Suite("Automations: an early poll resumes the poll interval")
struct AutomationRepollBackoffTests {
    @MainActor private func settle(_ store: ScheduledAutomationStore, _ id: UUID) async throws {
        for _ in 0..<200 where store.pollState(for: id)?.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.pollState(for: id)?.lastError != nil)
    }

    @Test("the poll an early request asked for saves its time; the next ticks wait the interval")
    @MainActor func earlyPollResumesInterval() async throws {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).json"))
        let a = ScheduledAutomation(profileID: UUID(), trigger: .githubPullRequest)
        store.upsert(a)
        // No delegate: each poll fails ("The workspace no longer exists").
        let engine = ScheduledAutomationEngine(store: store, delegate: nil)
        let t0 = Date()
        store.setPollState(.init(lastPolledAt: t0, highWater: t0), for: a.id)

        // A refusal asks for a poll soon.
        engine.requeueRefused(a.id)
        #expect(store.pollState(for: a.id)?.lastPolledAt == nil)
        let t1 = t0.addingTimeInterval(30)
        engine.tick(now: t1)
        try await settle(store, a.id)
        #expect(store.pollState(for: a.id)?.lastPolledAt == t1)

        // A tick inside the interval doesn't poll.
        var state = try #require(store.pollState(for: a.id))
        state.lastError = nil
        store.setPollState(state, for: a.id)
        engine.tick(now: t1.addingTimeInterval(30))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.pollState(for: a.id)?.lastError == nil)
        #expect(store.pollState(for: a.id)?.lastPolledAt == t1)

        // A nil saved by an older build heals on the next poll.
        state.lastPolledAt = nil
        store.setPollState(state, for: a.id)
        let t2 = t1.addingTimeInterval(60)
        engine.tick(now: t2)
        try await settle(store, a.id)
        #expect(store.pollState(for: a.id)?.lastPolledAt == t2)
    }

    @Test("a request made while a poll runs still forces one more")
    func inPollRequestKept() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/ScheduledAutomations.swift"), encoding: .utf8)
        #expect(!src.contains("if current.lastPolledAt == nil { next.lastPolledAt = nil }"))
        let poll = try #require(src.range(of: "private func pollEvents("))
        let body = src[poll.upperBound...].prefix(1500)
        let cleared = try #require(body.range(of: "repollRequested.remove(a.id)"))
        let kept = try #require(body.range(of: "if repollRequested.contains(a.id) { next.lastPolledAt = nil }"))
        #expect(cleared.lowerBound < kept.lowerBound)
        let soon = try #require(src.range(of: "private func repollSoon("))
        #expect(src[soon.upperBound...].prefix(500).contains("repollRequested.insert(automationID)"))
    }
}
