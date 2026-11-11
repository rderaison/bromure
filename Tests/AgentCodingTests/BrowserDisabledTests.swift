import Foundation
import Testing
@testable import bromure_ac

/// A workspace can turn its web browser off. The browser runs in its own VM,
/// outside the workspace's network policy, so a sandboxed workspace's agent
/// could use the `browser` MCP tools to reach any site. Off: the agents get
/// no browser server in their configs, and the host's server lists no tools,
/// refuses every call and the CDP endpoint, and never boots a browser.
@Suite("Workspace browser turned off")
@MainActor
struct BrowserDisabledTests {
    private func call(_ server: BrowserMCPServer, _ line: String) async -> [String: Any] {
        let out = await server.handle(line: line) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
    }

    @Test("the browser MCP server refuses everything and boots nothing while off")
    func serverRefuses() async {
        var off = true
        var boots = 0
        let server = BrowserMCPServer(browser: { nil }, ensureBrowser: { boots += 1 }, disabled: { off })

        let list = await call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(((list["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == true)

        let nav = await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"https://example.com"}}}"#)
        let result = nav["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("turned off"))

        let cdp = await call(server, #"{"jsonrpc":"2.0","id":3,"method":"bromure/cdpEndpoint"}"#)
        #expect(cdp["error"] != nil)
        #expect(boots == 0, "nothing booted a browser")

        // Read live: turned back on, the tools are listed again.
        off = false
        let back = await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        #expect(((back["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == false)
    }

    @Test("the guest's agent configs leave the browser server out while off")
    func configsOmitBrowser() {
        let claudeOn = SessionDisk.claudeCodeMCPConfig(servers: [])
        let claudeOff = SessionDisk.claudeCodeMCPConfig(servers: [], browser: false)
        #expect(claudeOn.contains("bromure-browser-mcp.py"))
        #expect(!claudeOff.contains("bromure-browser-mcp.py"))
        #expect(!claudeOff.contains("\"browser\""))
        #expect(claudeOff.contains("\"display\""), "the other built-in servers stay")

        let codexOn = SessionDisk.codexMCPConfig(servers: [])
        let codexOff = SessionDisk.codexMCPConfig(servers: [], browser: false)
        #expect(codexOn.contains("[mcp_servers.browser]"))
        #expect(!codexOff.contains("[mcp_servers.browser]"))
        #expect(!codexOff.contains("bromure-browser-mcp.py"))
        #expect(codexOff.contains("[mcp_servers.automations]"))
    }

    @Test("the setting round-trips and defaults to on")
    func profileCodable() throws {
        var p = Profile(id: UUID(), name: "W", tool: .claude, authMode: .subscription)
        #expect(!p.browserDisabled)
        let plain = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(!plain.browserDisabled)
        p.browserDisabled = true
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.browserDisabled)
    }
}
