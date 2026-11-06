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

    /// The finding: a transcript past the cap is read as its start and its end,
    /// each on its own, and the end's generated title won over a /rename in
    /// the start. The resumed read (what came before, then the last turn) did
    /// the same.
    @Test("a /rename in an earlier part of the file wins over a later generated title")
    func renameAcrossParts() throws {
        typealias I = TranscriptSearchIndex
        let rename = #"{"type":"custom-title","customTitle":"Auth work","sessionId":"x"}"#
        let generated = #"{"type":"ai-title","aiTitle":"Login redirect loop fix","sessionId":"x"}"#
        let filler = (0..<400).map { #"{"type":"user","message":{"role":"user","content":"ask \#($0) padding padding padding"}}"# }
        let lines = [#"{"type":"user","message":{"role":"user","content":"fix the login loop"}}"#, rename] + filler + [generated]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        // Read as a start and an end (the cap well under the file's size).
        let cap = 8_192, head = 2_048
        let d0 = Date(timeIntervalSince1970: 0)
        #expect(try I.entry(of: url, modified: d0, cap: cap, head: head)?.agentTitle == "Auth work")
        #expect(try #require(I.read(url, modified: d0, known: nil, cap: cap, head: head)).entry.agentTitle == "Auth work")
        // Read whole, the same answer.
        #expect(I.agentTitle(in: try Data(contentsOf: url)) == "Auth work")

        // Joining parts: a rename anywhere over a generated title; else the later.
        func part(_ t: String?, custom: Bool?) -> I.Entry {
            I.Entry(text: "", lastReply: "", tokens: I.TokenUsage(), agentTitle: t, agentTitleIsCustom: custom, modified: d0)
        }
        #expect(I.joined(part("Auth work", custom: true), part("Generated", custom: false)).agentTitle == "Auth work")
        #expect(I.joined(part("Generated", custom: false), part("Auth work", custom: true)).agentTitle == "Auth work")
        #expect(I.joined(part("Old name", custom: true), part("New name", custom: true)).agentTitle == "New name")
        #expect(I.joined(part("Early", custom: false), part("Later", custom: false)).agentTitle == "Later")
        #expect(I.joined(part("Auth work", custom: true), part(nil, custom: nil)).agentTitle == "Auth work")
        // A record saved before the flag: read as generated.
        #expect(I.joined(part("Saved", custom: nil), part("Later", custom: false)).agentTitle == "Later")
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
