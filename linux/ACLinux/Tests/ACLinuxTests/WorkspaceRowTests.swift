import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// /state's workspace rows carry what macOS's do: a fat client of a Linux
    /// server shows each workspace's color, agent, notes, storage, shield and
    /// credentials, and offers only the agents it can run.
    @Suite("Workspace rows as macOS's", .serialized)
    struct WorkspaceRowTests {
        @Test func aRowCarriesTheWorkspacesFields() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = ProfileStore()
            var p = Profile(name: "rows-\(UUID().uuidString.prefix(6))", tool: .claude, authMode: .token)
            p.comments = "my notes"
            p.color = .green
            p.customFontSize = 13
            p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .subscription)]
            p = try store.save(p)
            defer { try? FileManager.default.removeItem(at: store.profileDirectory(for: p)) }
            var rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            rec.name = p.name
            try await d.registerForTesting(rec)
            let rows = await d.workspaceRows([rec])
            guard case .object(let o)? = rows.first else { Issue.record("no row"); return }
            #expect(o["tool"]?.stringValue == "claude" && o["authMode"]?.stringValue == "token")
            #expect(o["color"]?.stringValue == "green" && o["accentHex"]?.stringValue?.isEmpty == false)
            #expect(o["comments"]?.stringValue == "my notes")
            #expect(o["fontSize"]?.numberValue == 13)
            #expect(o["hasGitHubToken"] == .bool(false) && o["hasLinearToken"] == .bool(false))
            guard case .array(let extra)? = o["additionalTools"], case .array(_)? = o["readyTools"] else {
                Issue.record("tools"); return
            }
            #expect(extra.count == 1 && extra.first?["tool"]?.stringValue == "codex")
            #expect(o["homeImageBytes"] == .null, "no home image yet")
            #expect(o["sandboxed"] != nil && o["diskCapacityBytes"] != nil)
            await d.shutdown()
        }
    }
}
