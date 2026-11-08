import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `POST /agent-sessions/<id>/read {seen?}` (macOS: markSessionRead): a
    /// session's replies are read up to what the client's screen showed, never
    /// past what it has; an unknown session is a 400.
    @Suite("Agent session read", .serialized)
    struct SessionReadTests {
        @Test func aReadMarksUpToWhatWasSeen() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (prior, sid): (SessionStores?, UUID) = await MainActor.run {
                let prior = SessionStores.shared
                let stores = SessionStores(stateDir: dir + "/stores")
                stores.engine = AgentSessionEngine(store: stores.sessions, delegate: nil)
                SessionStores.shared = stores
                var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "~")
                s.replies = 5
                stores.sessions.upsert(s)
                return (prior, s.id)
            }
            func read() async -> Int? { await MainActor.run { SessionStores.shared?.sessions.session(sid)?.readReplies } }
            #expect(await d.agentSessionCommand(sid, "read", .object(["seen": .number(3)])).status == 200)
            #expect(await read() == 3)
            #expect(await d.agentSessionCommand(sid, "read", .object(["seen": .number(9)])).status == 200)
            #expect(await read() == 5, "never past its replies")
            #expect(await d.agentSessionCommand(UUID(), "read", .object([:])).status == 400)
            await MainActor.run { SessionStores.shared = prior }
            await d.shutdown()
        }
    }
}
