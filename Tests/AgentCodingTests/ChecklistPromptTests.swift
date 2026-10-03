import Foundation
import Testing
@testable import bromure_ac

// Claude asks which of a folder's .mcp.json servers to enable with a
// checklist: Enter on a row only ticks it there, the button submits. The
// chat showed it as a one-pick menu whose answer (arrows + Enter) could
// never submit it.

@Suite("Checklist prompts")
struct ChecklistPromptTests {
    // Claude Code 2.1's multi-select MCP dialog, as the pane renders it.
    static let mcpScreen = """
    ╭──────────────────────────────────────────────────╮
    │ 2 new MCP servers found in this project           │
    │ Select any you wish to enable.                    │
    │                                                   │
    │ MCP servers may execute code or access system     │
    │ resources. All tool calls require approval.       │
    │                                                   │
    │ ❯ [✔] playwright                                  │
    │   [✔] github                                      │
    │     Enable selected                               │
    ╰──────────────────────────────────────────────────╯
      Space to select · Esc to reject all
    """

    @Test("the MCP checklist becomes a checklist card, not a one-pick menu")
    func detects() throws {
        let p = try #require(TerminalPrompt.detect(inScreen: Self.mcpScreen, agent: "claude"))
        #expect(p.kind == .checklist)
        #expect(p.title == "2 new MCP servers found in this project")
        #expect(p.options.map(\.label) == ["playwright", "github"])
        let list = try #require(p.checklist)
        #expect(list.checked == [true, true] && list.cursor == 0 && list.submitLabel == "Enable selected")
    }

    @Test("the answer ticks what changes, then reaches the button")
    func keys() throws {
        let list = try #require(AgentScreen.checklist(Self.mcpScreen.components(separatedBy: "\n")))
        // Keep both: straight to the button.
        #expect(AgentScreen.checklistKeys(list, want: [true, true]) == ["Down", "Down", "Enter"])
        // Drop github.
        #expect(AgentScreen.checklistKeys(list, want: [true, false]) == ["Down", "Space", "Down", "Enter"])
        // From the button: back up to the first row, then down again.
        var onButton = list
        onButton.cursor = nil
        #expect(AgentScreen.checklistKeys(onButton, want: [false, true])
                == ["Up", "Up", "Space", "Down", "Down", "Enter"])
        // No button: Enter on a row submits.
        var noButton = list
        noButton.submitLabel = nil
        #expect(AgentScreen.checklistKeys(noButton, want: [false, true]) == ["Space", "Enter"])
    }

    @Test("a task list in the agent's reply is not a dialog")
    func replyIsNotAChecklist() {
        let reply = """
        ⏺ Here's the plan:
          [x] read the config
          [ ] write the migration
          [ ] run the tests

        ╭──────────────────────────────╮
        │ >                            │
        ╰──────────────────────────────╯
        """
        #expect(AgentScreen.checklist(reply.components(separatedBy: "\n")) == nil)
    }

    @Test("the single-server MCP dialog stays a one-pick menu")
    func singleServer() throws {
        let screen = """
        ╭──────────────────────────────────────────────────────────╮
        │ New MCP server found in this project: playwright          │
        │                                                           │
        │ MCP servers may execute code or access system resources.  │
        │                                                           │
        │   Use this MCP server                                     │
        │   Use this and all future MCP servers in this project     │
        │ ❯ Continue without using this MCP server                  │
        ╰──────────────────────────────────────────────────────────╯
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "claude"))
        #expect(p.kind == .picker)
        #expect(p.options.count == 3 && p.selectedOption == 3)
        #expect(p.keys(picking: 1) == ["Up", "Up", "Enter"])
    }
}
