import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Native-machine session cards time idle from creation,
/// not the last turn". Cards count from `activeAt`, which only `noteReply`
/// stamped: a Bromure Agent Host's sessions (mirrored from its /state) never
/// had it, so a chat that had just finished read "5d".
@Suite("Attached-machine session activity")
@MainActor
struct HostSessionActivityTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("a host session's activeAt survives the /state hop and is what the card counts from")
    func decodedFromHost() throws {
        let now = Date()
        let created = now.addingTimeInterval(-5 * 86400), active = now.addingTimeInterval(-120)
        let iso = ISO8601DateFormatter()
        // MachineLinks' decode of a host session, as /state sends it.
        let d: [String: Any] = ["id": UUID().uuidString, "profileID": UUID().uuidString, "tool": "claude",
                                "title": "Lux", "cwd": "/Users/x/lux", "createdAt": iso.string(from: created),
                                "windowIndex": 3, "lastSeenAt": iso.string(from: now),
                                "activeAt": iso.string(from: active), "agentAlive": true]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: d))
        #expect(s.activeAt.map { abs($0.timeIntervalSince(active)) < 1 } == true)
        #expect(SessionHome.elapsedCompact(since: SessionHome.lastActivity(s), now: now) == "2m")
    }

    @Test("a hook-less agent's ended turn stamps the session; a mirror never does")
    func noteActive() throws {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let s = AgentSession(profileID: UUID(), tool: .claude, title: "t",
                             createdAt: Date().addingTimeInterval(-86400), windowIndex: 1)
        store.upsert(s)
        let t = Date()
        store.noteActive(s.id, at: t)
        #expect(store.session(s.id)?.activeAt == t)
        #expect(store.session(s.id)?.replies == nil)            // not a reply to read
        let mirror = AgentSessionStore(mirror: true)
        mirror.applyMirror([s])
        mirror.noteActive(s.id, at: t)
        #expect(mirror.session(s.id)?.activeAt == nil)
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let fn = try #require(ac.range(of: "private func setNonClaudeAgentTabs("))
        #expect(ac[fn.upperBound...].prefix(900).contains("agentSessionStore.noteActive(s.id)"))
    }

    @Test("the host stamps a window when its status turns done or asks, and sends it in /state")
    func hostWiring() throws {
        let hooks = try Self.src("Sources/AgentHost/ClaudeHooks.swift")
        #expect(hooks.contains(#"(state == "done" || state == "needsInput") && current != state"#))
        #expect(hooks.contains(#""@bromure_active_at""#))
        let tmux = try Self.src("Sources/AgentHost/Tmux.swift")
        #expect(tmux.contains(#""@bromure_active_at","#))
        #expect(tmux.contains("activeAt: TimeInterval(f[15]).map(Date.init(timeIntervalSince1970:))"))
        let sessions = try Self.src("Sources/AgentHost/Sessions.swift")
        let host = try #require(sessions.range(of: "struct HostSession: Codable, Equatable {"))
        #expect(sessions[host.upperBound...].prefix(1200).contains("var activeAt: Date?"))
        #expect(sessions.contains("if let a = w.activeAt, a > (s.activeAt ?? .distantPast) { s.activeAt = a }"))
        // Never seeded from lastSeenAt: that moves on every pass.
        #expect(!sessions.contains("activeAt = s.lastSeenAt") && !sessions.contains("activeAt = now"))
    }
}
