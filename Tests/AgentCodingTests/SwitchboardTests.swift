import Foundation
import Testing
@testable import bromure_ac

@Suite("Switchboard")
@MainActor
struct SwitchboardTests {

    @Test("Every tool the brief names exists, and every tool is in the brief")
    func briefMatchesTools() {
        let tools = Set(SwitchboardMCPServer.toolDefinitions.compactMap { $0["name"] as? String })
        let named = Set(SwitchboardBrief.text
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
            let def = SwitchboardMCPServer.toolDefinitions.first { $0["name"] as? String == name }
            let schema = def?["inputSchema"] as? [String: Any]
            let required = schema?["required"] as? [String] ?? []
            #expect(required.contains("on_behalf_of"), "\(name) must require on_behalf_of")
        }
    }

    @Test("Quotes match regardless of case, curly quotes and spacing")
    func normalization() {
        #expect(SwitchboardEngine.normalized("  Yes, on  “staging-2” only ") == "yes, on \"staging-2\" only")
        #expect(SwitchboardEngine.normalized("don’t\nmerge") == "don't merge")
    }

    @Test("Key allowlist: prompt keys in, arbitrary text out")
    func keys() {
        for k in ["Enter", "Escape", "1", "y", "C-c", "Down"] {
            #expect(SwitchboardEngine.allowedKeys.contains(k))
        }
        for k in ["rm -rf /", "C-d", "M-x", "hello", "Enter; ls"] {
            #expect(!SwitchboardEngine.allowedKeys.contains(k))
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
        let all = SwitchboardEngine.render(items, turns: 6, maxChars: 10_000)
        #expect(all == """
        USER: fix the login bug
        AGENT: Looking at auth.swift
        [Edit] auth.swift
        [Bash failed] boom
        USER: and run the tests
        AGENT: Tests pass.
        """)
        let last = SwitchboardEngine.render(items, turns: 1, maxChars: 10_000)
        #expect(last == "USER: and run the tests\nAGENT: Tests pass.")
        #expect(SwitchboardEngine.render(items, turns: 6, maxChars: 12).hasPrefix("…"))
        #expect(SwitchboardEngine.lastWords(items) == "Tests pass.")
    }

    @Test("An answered question no longer stands")
    func answeredQuestion() {
        let q = TranscriptQuestion(question: "Tabs or spaces?", header: "", multiSelect: false,
                                   options: [.init(label: "Tabs", description: ""), .init(label: "Spaces", description: "")])
        let asked: [TranscriptItem] = [.init(id: 0, kind: .userText("ask me")), .init(id: 1, kind: .question(q))]
        let answered = asked + [.init(id: 2, kind: .toolResult(tool: "AskUserQuestion", content: "Spaces", isError: false)),
                                .init(id: 3, kind: .assistantText("Spaces"))]
        #expect(SwitchboardEngine.standingQuestion(asked)?.question == "Tabs or spaces?")
        #expect(SwitchboardEngine.standingQuestion(answered) == nil)
    }

    @Test("The Switchboard is never listed with the sessions it watches")
    func excludedFromLists() {
        var c = AgentSession(profileID: UUID(), tool: .claude, title: "Switchboard")
        c.role = AgentSession.switchboardRole
        let s = AgentSession(profileID: UUID(), tool: .claude, title: "work")
        let model = SessionListModel()
        let listed = SessionHome.orderedAll([c, s], in: model)
        #expect(listed.map(\.id) == [s.id])
        #expect(SwitchboardGate.switchboard(in: [s, c])?.id == c.id)
    }

    @Test("Role survives a round trip; old records decode without it")
    func roleCodable() throws {
        var c = AgentSession(profileID: UUID(), tool: .claude, title: "Switchboard")
        c.role = AgentSession.switchboardRole
        let back = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(c))
        #expect(back.isSwitchboard)
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        plain.removeValue(forKey: "role")
        let old = try JSONDecoder().decode(AgentSession.self,
                                           from: JSONSerialization.data(withJSONObject: plain))
        #expect(!old.isSwitchboard)
    }

    @Test("Only the user reaches the Switchboard from a phone")
    func phoneSenderFilter() {
        let sigLinked = ConnectorChannel(kind: .signal, mode: .linked, account: "+15550001111",
                                         allowed: ["+15550001111"], connected: true)
        #expect(KubeClusterEngine.isFromUser(["from": "+15550001111", "noteToSelf": true], channel: sigLinked))
        #expect(!KubeClusterEngine.isFromUser(["from": "+15550001111"], channel: sigLinked))       // not Note to Self
        #expect(!KubeClusterEngine.isFromUser(["from": "+15559990000", "noteToSelf": true], channel: sigLinked))

        let sigOwn = ConnectorChannel(kind: .signal, mode: .ownNumber, account: "+15552223333",
                                      allowed: ["+15550001111"], connected: true)
        #expect(KubeClusterEngine.isFromUser(["from": "+15550001111"], channel: sigOwn))
        #expect(!KubeClusterEngine.isFromUser(["from": "+15559990000"], channel: sigOwn))

        let waLinked = ConnectorChannel(kind: .whatsapp, mode: .linked, account: "15550001111@s.whatsapp.net",
                                        allowed: ["15550001111@s.whatsapp.net"], connected: true)
        // "Message yourself" by phone JID (device suffix on the sender)…
        #expect(KubeClusterEngine.isFromUser(["fromMe": true, "from": "15550001111:3@s.whatsapp.net",
                                              "chat": "15550001111@s.whatsapp.net"], channel: waLinked))
        // …and by LID, the way newer WhatsApp addresses the self-chat.
        #expect(KubeClusterEngine.isFromUser(["fromMe": true, "from": "15550001111:3@s.whatsapp.net",
                                              "fromLid": "987654321@lid", "chat": "987654321@lid"], channel: waLinked))
        // The user writing to someone else is "from me" too — never relayed.
        #expect(!KubeClusterEngine.isFromUser(["fromMe": true, "from": "15550001111@s.whatsapp.net",
                                               "fromLid": "987654321@lid", "chat": "15557776666@s.whatsapp.net"], channel: waLinked))
        #expect(!KubeClusterEngine.isFromUser(["fromMe": true, "from": "15550001111@s.whatsapp.net",
                                               "fromLid": "987654321@lid", "chat": "111222333@lid"], channel: waLinked))
        // Someone else writing to the user.
        #expect(!KubeClusterEngine.isFromUser(["fromMe": false, "from": "15557776666@s.whatsapp.net",
                                               "chat": "15557776666@s.whatsapp.net"], channel: waLinked))

        let waOwn = ConnectorChannel(kind: .whatsapp, mode: .ownNumber, account: "15552223333@s.whatsapp.net",
                                     allowed: ["15550001111@s.whatsapp.net"], connected: true)
        #expect(KubeClusterEngine.isFromUser(["fromMe": false, "from": "15550001111@s.whatsapp.net"], channel: waOwn))
        #expect(!KubeClusterEngine.isFromUser(["fromMe": false, "from": "15557776666@s.whatsapp.net"], channel: waOwn))
    }

    @Test("The launch flags point at the staged MCP config")
    func flags() {
        #expect(SwitchboardEngine.launchFlags.contains(SessionDisk.switchboardMCPConfigGuestPath))
        #expect(SessionDisk.switchboardMCPShimScript.contains("PORT = \(SessionDisk.switchboardMCPVsockPort)"))
        #expect(SessionDisk.switchboardMCPConfigJSON.contains("bromure-switchboard-mcp.py"))
    }
}
