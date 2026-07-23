import Foundation
import Testing
@testable import bromure_ac

// Which tmux window labels read as a coding agent. This drives the sidebar's
// agent badge on macOS AND whether the iOS client offers the rich transcript
// reader for a window, so the shapes the guest actually publishes
// (bromure-agentd `_resolve_tab_name`) all have to resolve.

@Suite("Agent label resolution")
struct AgentLabelTests {

    @Test("a bare agent command resolves")
    func bareCommand() {
        #expect(BromureIcons.agentKind(forLabel: "claude") == "claude")
        #expect(BromureIcons.agentKind(forLabel: "codex") == "codex")
        #expect(BromureIcons.agentKind(forLabel: "Claude") == "claude")
    }

    @Test("a renamed agent tab resolves through its trailing marker")
    func sessionTitleMarker() {
        // The guest turns a bare `claude` tab into "<OSC-2 title> (claude)" as
        // soon as the agent names its session. A long title must not cost the
        // tab its agent identity — that's what gates the reader on iOS.
        #expect(BromureIcons.agentKind(
            forLabel: "Fix bromure branding and settings label (claude)") == "claude")
        #expect(BromureIcons.agentKind(forLabel: "Refactor website (codex)") == "codex")
    }

    @Test("the trailing marker wins over a tool named inside the title")
    func markerBeatsTitleText() {
        // A free-text title may itself mention another tool; the marker the
        // guest appended is the authoritative one.
        #expect(BromureIcons.agentKind(forLabel: "Port the codex prompts (claude)") == "claude")
        #expect(BromureIcons.agentKind(forLabel: "Review claude's plan (codex)") == "codex")
    }

    @Test("paths, extensions and interpreter wrappers resolve")
    func pathsAndWrappers() {
        #expect(BromureIcons.agentKind(forLabel: "/usr/local/bin/claude") == "claude")
        #expect(BromureIcons.agentKind(forLabel: "claude.js") == "claude")
        #expect(BromureIcons.agentKind(forLabel: "node /opt/claude.js") == "claude")
    }

    @Test("plain shells and near-misses are not agents")
    func nonAgents() {
        #expect(BromureIcons.agentKind(forLabel: "bash") == nil)
        #expect(BromureIcons.agentKind(forLabel: "shell") == nil)
        #expect(BromureIcons.agentKind(forLabel: "") == nil)
        // Substring matching used to claim these; whole-word matching doesn't.
        #expect(BromureIcons.agentKind(forLabel: "claudette") == nil)
        #expect(BromureIcons.agentKind(forLabel: "amplify") == nil)
    }
}
