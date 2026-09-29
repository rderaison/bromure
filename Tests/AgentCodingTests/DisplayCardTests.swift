import Foundation
import Testing
@testable import bromure_ac

@Suite("Display MCP cards")
struct DisplayCardTests {
    @Test("a display call is read whatever the agent calls MCP tools")
    func parsesEveryAgentsNaming() {
        let media = #"{"path":"/tmp/a.png","title":"Dots","caption":"c"}"#
        for name in ["mcp__display__show_media", "display__show_media", "display.show_media", "show_media"] {
            #expect(DisplayRequest.parse(name: name, detail: media)
                    == .media(path: "/tmp/a.png", title: "Dots", caption: "c"), Comment(rawValue: name))
        }
        // A relative path can't be read off the machine: not a card.
        #expect(DisplayRequest.parse(name: "mcp__display__show_media", detail: #"{"path":"a.png"}"#) == nil)
        // Someone else's show_media isn't ours.
        #expect(DisplayRequest.parse(name: "mcp__gallery__show_media", detail: media) == nil)
        // A spec as an object or as a JSON string, normalized the same way.
        let obj = DisplayRequest.parse(name: "mcp__display__show_chart",
                                       detail: #"{"spec":{"mark":"bar","data":{"values":[]}}}"#)
        let str = DisplayRequest.parse(name: "mcp__display__show_chart",
                                       detail: #"{"spec":"{\"mark\":\"bar\",\"data\":{\"values\":[]}}"}"#)
        #expect(obj != nil)
        #expect(obj == str)
    }

    @Test("a display call is shown, never folded into the activity line")
    func notFolded() {
        let show = TranscriptItem(id: 1, kind: .toolUse(name: "mcp__display__show_chart", summary: "",
                                                        detail: #"{"spec":{"mark":"bar"}}"#), timestamp: nil)
        let bash = TranscriptItem(id: 2, kind: .toolUse(name: "Bash", summary: "ls", detail: "{}"), timestamp: nil)
        #expect(!TranscriptRow.isActivity(show))
        #expect(TranscriptRow.isActivity(bash))
    }

    @Test("every agent is given the display server, pre-approved")
    func registered() {
        let claude = SessionDisk.claudeCodeMCPConfig(servers: [])
        #expect(claude.contains("\"display\""))
        #expect(claude.contains("bromure-display-mcp.py"))
        let codex = SessionDisk.codexMCPConfig(servers: [])
        #expect(codex.contains("[mcp_servers.display]"))
        #expect(ProfileStore.claudeAlwaysAllowed.contains("mcp__display"))
    }
}
