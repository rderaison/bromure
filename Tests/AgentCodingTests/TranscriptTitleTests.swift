import Foundation
import Testing
@testable import bromure_ac

@Suite("Session titles from the conversation")
@MainActor
struct TranscriptTitleAdoptionTests {

    @Test("Claude's own title: the latest ai-title, a /rename (custom-title) over it")
    func agentTitle() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Early guess","sessionId":"x"}"#,
            #"{"type":"user","message":{"role":"user","content":"fix the login loop"}}"#,
            #"{"type":"ai-title","aiTitle":"Login redirect loop fix","sessionId":"x"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(TranscriptSearchIndex.agentTitle(in: data) == "Login redirect loop fix")
        let renamed = Data((lines + [#"{"type":"custom-title","customTitle":"Auth work","sessionId":"x"}"#])
            .joined(separator: "\n").utf8)
        #expect(TranscriptSearchIndex.agentTitle(in: renamed) == "Auth work")
        #expect(TranscriptSearchIndex.agentTitle(in: Data("{}\n".utf8)) == nil)
        #expect(!TranscriptSearchIndex.isOwnWords("[Delegation notice] @x asks: hi"))
        #expect(!TranscriptSearchIndex.isOwnWords("<command-name>/model</command-name>"))
        #expect(TranscriptSearchIndex.isOwnWords("Fix the login loop please"))
    }

    @Test("placeholder names give way; the user's and the agent's never do")
    func adopt() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("titles-\(UUID().uuidString).json"))
        let ws = UUID()
        let generic = AgentSession(profileID: ws, tool: .claude,
                                   title: AgentSession.defaultTitle(tool: .claude, cwd: "/Users/me/bromure"),
                                   cwd: "/Users/me/bromure")
        var mine = AgentSession(profileID: ws, tool: .claude, title: "My name", cwd: "/Users/me/bromure")
        mine.userTitled = true
        let named = AgentSession(profileID: ws, tool: .claude, title: "Terminal topic", cwd: "/Users/me/bromure")
        for s in [generic, mine, named] { store.upsert(s) }

        // No agent title yet: the first request stands in.
        store.adoptTranscriptTitles([generic.id, mine.id, named.id]) { _ in (nil, "please fix the flaky retry test") }
        #expect(store.session(generic.id)?.title == "Fix the flaky retry test")
        #expect(store.session(mine.id)?.title == "My name")
        #expect(store.session(named.id)?.title == "Terminal topic")
        // Claude titles it: that replaces the stand-in.
        store.adoptTranscriptTitles([generic.id]) { _ in ("Flaky retry test fix", "please fix the flaky retry test") }
        #expect(store.session(generic.id)?.title == "Flaky retry test fix")
        // …and is then left alone.
        store.adoptTranscriptTitles([generic.id]) { _ in (nil, "something else") }
        #expect(store.session(generic.id)?.title == "Flaky retry test fix")
    }
}
