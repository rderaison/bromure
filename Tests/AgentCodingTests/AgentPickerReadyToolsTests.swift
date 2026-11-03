import Foundation
import Testing
@testable import bromure_ac

/// Board report: in Automations › On GitHub events, a workspace signed in to
/// Grok (a subscription set up in the Models settings) offered only Claude
/// Code. The automation editor, the task editor and the agents' automation
/// tool listed the workspace's own agent list — a new session (and a
/// repository watch) also counts the agents the Models settings or a
/// shared sign-in make ready.
@Suite("Agent pickers offer every agent a workspace can run")
struct AgentPickerReadyToolsTests {
    @Test("a Grok subscription from the Models settings is offered, signed in by subscription")
    func subscriptionAgentIsOffered() {
        let ws = Profile(name: "codereview", tool: .claude, authMode: .subscription, apiKey: nil)
        #expect(ws.allToolSpecs.map(\.tool) == [.claude])          // what the pickers listed
        let specs = ws.readyToolSpecs(ModelSettings(), subscribed: [.xai])
        #expect(specs.first?.tool == .claude)                       // its own agent first
        #expect(specs.first { $0.tool == .grok }?.authMode == .subscription)
        // Nothing set up for the others: not offered.
        #expect(!specs.contains { $0.tool == .codex || $0.tool == .kimi })
        // The same set a new session counts as ready.
        #expect(Set(specs.map(\.tool)) == ws.agentsReadyToStart(ModelSettings(), subscribed: [.xai]))
    }

    @Test("an API key in the Models settings makes its agent offerable; nothing set up, the workspace's own")
    func keyedAgentIsOffered() {
        let ws = Profile(name: "w", tool: .claude, authMode: .subscription, apiKey: nil)
        var s = ModelSettings()
        s.providers = [ProviderCredential(provider: .openai, apiKey: "sk-oai")]
        #expect(ws.readyToolSpecs(s).contains { $0.tool == .codex && $0.authMode == .token })
        #expect(ws.readyToolSpecs(ModelSettings()).map(\.tool) == [.claude])
    }

    @Test("a fat client offers what the host says is ready; an older host, the workspace's own")
    func mirrorReadsTheHostsList() {
        let row: [String: Any] = ["readyTools": [["tool": "claude", "authMode": "subscription"],
                                                 ["tool": "grok", "authMode": "subscription"],
                                                 ["tool": "nonsense"]]]
        let ready = RemoteHostController.readyTools(from: row)
        #expect(ready?.map(\.tool) == [.claude, .grok])
        #expect(ready?.last?.authMode == .subscription)
        #expect(RemoteHostController.readyTools(from: [:]) == nil)
        // What the editors offer: the host's list; an older host's, every
        // agent (the mirror can't see its Models settings) — never the
        // workspace's own list alone.
        let ws = Profile(name: "codereview", tool: .claude, authMode: .subscription, apiKey: nil)
        #expect(RemoteHostController.offeredTools(ws, hostSays: ready).map(\.tool) == [.claude, .grok])
        let old = RemoteHostController.offeredTools(ws, hostSays: nil)
        #expect(old.first?.tool == .claude && old.first?.authMode == .subscription)
        #expect(Set(old.map(\.tool)) == Set(Profile.Tool.allCases))
    }

    @Test("an agent's automation tool accepts an agent the workspace can run")
    @MainActor func mcpAcceptsReadyAgent() async throws {
        let ws = Profile(name: "codereview", tool: .claude, authMode: .subscription, apiKey: nil)
        var saved: [ScheduledAutomation] = []
        func server(_ ready: @escaping (Profile) -> [Profile.Tool]) -> AutomationMCPServer {
            let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("picker-\(UUID().uuidString).json"))
            return AutomationMCPServer(profileID: ws.id, store: { store }, profile: { ws },
                                save: { saved.append($0) }, remove: { _ in }, runNow: { _ in },
                                readyTools: ready)
        }
        func create(_ s: AutomationMCPServer) async -> String {
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                       "params": ["name": "automation_create",
                                                  "arguments": ["name": "Bugs", "prompt": "Look.",
                                                                "tool": "grok"]]]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: call), as: UTF8.self)
            return await s.handle(line: line, branch: nil) ?? ""
        }
        let refused = await create(server { $0.allToolSpecs.map(\.tool) })
        #expect(refused.contains("isn't set up"))
        #expect(saved.isEmpty)
        _ = await create(server { _ in [.claude, .grok] })
        #expect(saved.last?.tool == .grok)
    }
}
