import Foundation
import Testing
@testable import ACLinux

/// Pages a guest opened, waiting in /state for the user's clients: bounded,
/// deduplicated, expiring; a local or private page never kept.
@Suite("Guest link relay", .serialized)
@MainActor
struct GuestLinkRelayTests {
    @Test func keptBoundedDedupedAndExpiring() throws {
        let relay = GuestLinkRelay()
        let a = UUID(), b = UUID()
        let t0 = Date()
        #expect(relay.add(URL(string: "https://docs.example.com/page")!, profileID: a, workspace: "w", now: t0))
        #expect(!relay.add(URL(string: "https://docs.example.com/page")!, profileID: a, workspace: "w", now: t0), "already waiting")
        #expect(relay.add(URL(string: "https://docs.example.com/page")!, profileID: b, workspace: "v", now: t0), "another workspace's own")
        #expect(!relay.add(URL(string: "http://192.168.1.10/admin")!, profileID: a, workspace: "w", now: t0), "a private host")
        #expect(!relay.add(URL(string: "http://localhost:8080/")!, profileID: a, workspace: "w", now: t0), "loopback")
        for i in 0..<10 { relay.add(URL(string: "https://example.com/\(i)")!, profileID: a, workspace: "w", now: t0) }
        #expect(relay.links.filter { $0.profileID == a }.count == GuestLinkRelay.maxPerWorkspace)
        #expect(!relay.links.contains { $0.url == "https://docs.example.com/page" && $0.profileID == a }, "the oldest went")
        // /state's rows.
        guard case .array(let rows)? = relay.stateEntries(t0)["guestLinks"] else { Issue.record("no guestLinks"); return }
        #expect(rows.count == GuestLinkRelay.maxPerWorkspace + 1)
        #expect(rows.first?["workspace"]?.stringValue != nil && rows.first?["url"]?.stringValue != nil)
        // Handled by a client, then expiry, then a stopped workspace.
        let id = try #require(relay.links.first { $0.profileID == b }?.id)
        #expect(relay.done(id) && !relay.done(id))
        guard case .array(let later)? = relay.stateEntries(t0.addingTimeInterval(GuestLinkRelay.ttl + 1))["guestLinks"] else { return }
        #expect(later.isEmpty, "expired")
        relay.add(URL(string: "https://example.com/x")!, profileID: a, workspace: "w")
        relay.clear(a)
        #expect(relay.links.isEmpty)
    }

    /// /state carries the waiting links; a client marks one handled.
    @Test func stateAndTheDoneRoute() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        defer { GuestLinkRelay.shared.clear(pid) }
        GuestLinkRelay.shared.add(URL(string: "https://docs.example.com/route")!, profileID: pid, workspace: "w")
        let id = try #require(GuestLinkRelay.shared.links.first { $0.profileID == pid }?.id)
        guard case .object(let o) = await d.state().body, case .array(let rows)? = o["guestLinks"] else {
            Issue.record("no guestLinks in /state"); return
        }
        #expect(rows.contains { $0["id"]?.stringValue == id.uuidString && $0["url"]?.stringValue == "https://docs.example.com/route" })
        let post = { (path: String) in await d.handle(ControlRequest(method: "POST", path: path, body: .object([:]))).status }
        #expect(await post("/guest-links/\(id.uuidString)/done") == 200)
        #expect(await post("/guest-links/\(id.uuidString)/done") == 404, "already handled")
        #expect(await post("/guest-links/nope/done") == 400)
        #expect(!GuestLinkRelay.shared.links.contains { $0.profileID == pid })
    }
}
