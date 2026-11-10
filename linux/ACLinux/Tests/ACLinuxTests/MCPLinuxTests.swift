import Foundation
import Testing
@testable import ACLinux

/// `bromure-ac mcp` on Linux: the API is the daemon's control socket, and
/// the profile tools answer as macOS's AppleScript commands do.
@Suite("MCP server on Linux")
struct MCPLinuxTests {
    @Test func theAPIIsTheControlSocket() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let srv = try await ControlServer.start(path: dir + "/control.sock") { req in
            guard req.method == "GET", req.path == "/sessions" else { return .error(404, "Not found") }
            return ControlResponse(200, ["sessions": .array([["profileId": "x", "profileName": "w", "windowId": 0, "visible": false]])])
        }
        defer { Task { await srv.close() } }
        let r = ACMCPServerImpl.rawHTTP(base: "unix:" + dir + "/control.sock", method: "GET", path: "/sessions", bodyData: nil)
        let rows = try #require(r["sessions"] as? [[String: Any]])
        #expect(rows.first?["profileName"] as? String == "w")
        let none = ACMCPServerImpl.rawHTTP(base: "unix:" + dir + "/nothing.sock", method: "GET", path: "/sessions", bodyData: nil)
        #expect((none["error"] as? String)?.contains("No bromure-ac daemon") == true)
        #expect(MCP.defaultAPIURL.hasPrefix("unix:") && MCP.defaultAPIURL.hasSuffix("control.sock"))
    }

    @Test func profileSettingsAsMacOSs() {
        let d: [String: Any] = ["name": "w", "color": "blue", "closeAction": "suspend", "memoryGB": 8,
                                "folderPaths": ["/a", "/b"], "mcpServers": [], "apiKey": ""]
        #expect(ACMCPServerImpl.setting(d, "name") == "w" && ACMCPServerImpl.setting(d, "memoryGB") == "8")
        #expect(ACMCPServerImpl.setting(d, "folderPathsCount") == "2" && ACMCPServerImpl.setting(d, "mcpServerCount") == "0")
        #expect(ACMCPServerImpl.setting(d, "keyRepeatRateHz") == "")
        #expect(ACMCPServerImpl.setting(d, "nope") == "error: unknown key 'nope'")
        guard case .success(let doc) = ACMCPServerImpl.settingDoc("memoryGB", "4") else { Issue.record("memoryGB"); return }
        #expect(doc["memoryGB"] as? Int == 4)
        guard case .failure(let e) = ACMCPServerImpl.settingDoc("memoryGB", "0") else { Issue.record("0 GB"); return }
        #expect(e.message == "memoryGB must be a positive integer")
        guard case .failure(let c) = ACMCPServerImpl.settingDoc("closeAction", "explode") else { Issue.record("closeAction"); return }
        #expect(c.message == "invalid closeAction 'explode'")
        guard case .success(let blank) = ACMCPServerImpl.settingDoc("apiKey", "") else { Issue.record("apiKey"); return }
        #expect(blank["apiKey"] is NSNull)
    }
}
