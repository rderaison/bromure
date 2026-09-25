import Foundation
import Testing
@testable import bromure_ac

@Suite("Conductor")
@MainActor
struct ConductorTests {

    @Test("Every tool the brief names exists, and every tool is in the brief")
    func briefMatchesTools() {
        let tools = Set(ConductorMCPServer.toolDefinitions.compactMap { $0["name"] as? String })
        let named = Set(ConductorBrief.text
            .components(separatedBy: "`").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
            .filter { $0.allSatisfy { $0.isLowercase || $0 == "_" } && $0.contains("_") })
            .subtracting(["on_behalf_of", "api_refused", "api_error"])   // a parameter and event fields, not tools
        #expect(named.subtracting(tools).isEmpty, "brief names unknown tools: \(named.subtracting(tools))")
        #expect(tools.subtracting(named).isEmpty, "tools missing from the brief: \(tools.subtracting(named))")
    }

    @Test("Tools that answer for the user require on_behalf_of")
    func provenanceRequired() {
        for name in ["answer_question", "press_keys", "archive_session"] {
            let def = ConductorMCPServer.toolDefinitions.first { $0["name"] as? String == name }
            let schema = def?["inputSchema"] as? [String: Any]
            let required = schema?["required"] as? [String] ?? []
            #expect(required.contains("on_behalf_of"), "\(name) must require on_behalf_of")
        }
    }

    @Test("Quotes match regardless of case, curly quotes and spacing")
    func normalization() {
        #expect(ConductorEngine.normalized("  Yes, on  “staging-2” only ") == "yes, on \"staging-2\" only")
        #expect(ConductorEngine.normalized("don’t\nmerge") == "don't merge")
    }

    @Test("Key allowlist: prompt keys in, arbitrary text out")
    func keys() {
        for k in ["Enter", "Escape", "1", "y", "C-c", "Down"] {
            #expect(ConductorEngine.allowedKeys.contains(k))
        }
        for k in ["rm -rf /", "C-d", "M-x", "hello", "Enter; ls"] {
            #expect(!ConductorEngine.allowedKeys.contains(k))
        }
    }

    @Test("A session's recent turns render as text, oldest first, capped")
    func render() {
        let items: [TranscriptItem] = [
            .init(id: 0, kind: .userText("fix the login bug")),
            .init(id: 1, kind: .assistantText("Looking at auth.swift")),
            .init(id: 2, kind: .toolUse(name: "Edit", summary: "auth.swift", detail: "{}")),
            .init(id: 3, kind: .toolResult(tool: "Bash", content: "boom", isError: true)),
            .init(id: 4, kind: .userText("and run the tests")),
            .init(id: 5, kind: .assistantText("Tests pass.")),
        ]
        let all = ConductorEngine.render(items, turns: 6, maxChars: 10_000)
        #expect(all == """
        USER: fix the login bug
        AGENT: Looking at auth.swift
        [Edit] auth.swift
        [Bash failed] boom
        USER: and run the tests
        AGENT: Tests pass.
        """)
        let last = ConductorEngine.render(items, turns: 1, maxChars: 10_000)
        #expect(last == "USER: and run the tests\nAGENT: Tests pass.")
        #expect(ConductorEngine.render(items, turns: 6, maxChars: 12).hasPrefix("…"))
        #expect(ConductorEngine.lastWords(items) == "Tests pass.")
    }

    @Test("An answered question no longer stands")
    func answeredQuestion() {
        let q = TranscriptQuestion(question: "Tabs or spaces?", header: "", multiSelect: false,
                                   options: [.init(label: "Tabs", description: ""), .init(label: "Spaces", description: "")])
        let asked: [TranscriptItem] = [.init(id: 0, kind: .userText("ask me")), .init(id: 1, kind: .question(q))]
        let answered = asked + [.init(id: 2, kind: .toolResult(tool: "AskUserQuestion", content: "Spaces", isError: false)),
                                .init(id: 3, kind: .assistantText("Spaces"))]
        #expect(ConductorEngine.standingQuestion(asked)?.question == "Tabs or spaces?")
        #expect(ConductorEngine.standingQuestion(answered) == nil)
    }

    @Test("The Conductor is never listed with the sessions it watches")
    func excludedFromLists() {
        var c = AgentSession(profileID: UUID(), tool: .claude, title: "Conductor")
        c.role = AgentSession.conductorRole
        let s = AgentSession(profileID: UUID(), tool: .claude, title: "work")
        let model = SessionListModel()
        let listed = SessionHome.orderedAll([c, s], in: model)
        #expect(listed.map(\.id) == [s.id])
        #expect(ConductorGate.conductor(in: [s, c])?.id == c.id)
    }

    @Test("Role survives a round trip; old records decode without it")
    func roleCodable() throws {
        var c = AgentSession(profileID: UUID(), tool: .claude, title: "Conductor")
        c.role = AgentSession.conductorRole
        let back = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(c))
        #expect(back.isConductor)
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        plain.removeValue(forKey: "role")
        let old = try JSONDecoder().decode(AgentSession.self,
                                           from: JSONSerialization.data(withJSONObject: plain))
        #expect(!old.isConductor)
    }

    @Test("The launch flags point at the staged MCP config")
    func flags() {
        #expect(ConductorEngine.launchFlags.contains(SessionDisk.conductorMCPConfigGuestPath))
        #expect(SessionDisk.conductorMCPShimScript.contains("PORT = \(SessionDisk.conductorMCPVsockPort)"))
        #expect(SessionDisk.conductorMCPConfigJSON.contains("bromure-conductor-mcp.py"))
    }
}
