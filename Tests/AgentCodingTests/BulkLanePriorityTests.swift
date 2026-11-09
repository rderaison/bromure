import Foundation
import Testing
@testable import bromure_ac

/// On a thin link the fat client's background transcript reads (preloads,
/// warm chats) shared the bulk lane with the chat on screen, so opening a
/// conversation waited behind other sessions' downloads.
@Suite("Bulk lane: the chat on screen reads first")
@MainActor
struct BulkLanePriorityTests {
    @Test("Busy while a read is in flight, and for the gap between a chat's two requests")
    func busy() {
        let now = Date()
        #expect(BulkLanePriority.busy(inFlight: 1, lastEnd: .distantPast, now: now))
        #expect(BulkLanePriority.busy(inFlight: 0, lastEnd: now.addingTimeInterval(-0.1), now: now))
        #expect(!BulkLanePriority.busy(inFlight: 0, lastEnd: now.addingTimeInterval(-1), now: now))
    }

    @Test("Preloads stop on a link too thin to spare a window")
    func affordable() {
        #expect(BulkLanePriority.preloadAffordable(bytesPerSecond: nil))
        #expect(BulkLanePriority.preloadAffordable(bytesPerSecond: 2_000_000))
        #expect(!BulkLanePriority.preloadAffordable(bytesPerSecond: 100_000))
    }

    @Test("A background read waits until the foreground read is done")
    func backgroundWaits() async {
        let lane = BulkLanePriority()
        var order: [String] = []
        let fg = Task { @MainActor in
            await lane.foreground {
                try? await Task.sleep(nanoseconds: 300_000_000)
                order.append("foreground")
            }
        }
        // Let the foreground read start.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(lane.foregroundBusy)
        try? await lane.waitForQuiet()
        order.append("background")
        await fg.value
        #expect(order == ["foreground", "background"])
        #expect(lane.foregroundInFlight == 0)
    }

    @Test("A quiet lane doesn't hold a background read")
    func quietLane() async {
        let lane = BulkLanePriority()
        let t0 = Date()
        try? await lane.waitForQuiet()
        #expect(Date().timeIntervalSince(t0) < 0.2)
    }

    @Test("A background read cancelled while it waits (its chat reopened or gone) doesn't go out")
    func cancelledWaitThrows() async {
        let lane = BulkLanePriority()
        let fg = Task { @MainActor in
            await lane.foreground { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(lane.foregroundBusy)
        var sent = false
        let bg = Task { @MainActor in
            do {
                try await lane.waitForQuiet()
                sent = true
                return false
            } catch is CancellationError {
                return true
            } catch { return false }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        bg.cancel()
        let t0 = Date()
        #expect(await bg.value)
        // Ends with the cancel, not when the foreground read does.
        #expect(Date().timeIntervalSince(t0) < 1)
        #expect(!sent)
        fg.cancel()
        await fg.value
    }

    @Test("A reader already cancelled doesn't wait or go out, even on a quiet lane")
    func alreadyCancelled() async {
        let lane = BulkLanePriority()
        let t = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await lane.waitForQuiet()) == nil
        }
        #expect(await t.value)
    }

    @Test("Preloads and chats off stage read as background; preloads give way to the chat on screen")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fc = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(fc.contains("sessionID: s.id, accent: .accentColor, background: true)"))
        #expect(fc.contains("guard !controller.bulkPriority.foregroundBusy,"))
        #expect(fc.contains("BulkLanePriority.preloadAffordable(bytesPerSecond: controller.linkStats.snapshot().bytesPerSecond)"))
        #expect(fc.contains("guard (try? await controller.bulkPriority.waitForQuiet()) != nil else { return nil }"))
        let chat = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        #expect(chat.contains("""
                background = on
                provider.noteBackground(on)
        """))
    }
}
