import Foundation
import Testing
@testable import bromure_ac

// A fat client mirrors workspaces without their credentials, so the
// automation and code-review editors said "no GitHub token" for a workspace
// that has one. The host now says which tokens each workspace holds.

@Suite("Fat-client credential flags")
@MainActor
struct FatClientCredentialFlagsTests {
    @Test("the mirror knows a workspace's tokens without holding them")
    func flagsReachTheMirror() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let id = UUID()
        let row: [String: Any] = ["id": id.uuidString, "name": "codereview", "tool": "claude",
                                  "authMode": "token", "state": "off",
                                  "hasGitHubToken": true, "hasLinearToken": false,
                                  "askBeforeUseLabels": ["Git token (github.com)"]]
        c.applyPushedSnapshot(["workspaces": [row], "vms": []])
        #expect(c.profile(for: id)?.hasGitHubCredential == false)   // no credential travels
        #expect(c.credentials(for: id) == .init(github: true, linear: false,
                                                askBeforeUseLabels: ["Git token (github.com)"]))
        // An older host that doesn't say: unknown, the profile decides.
        var old = row
        old.removeValue(forKey: "hasGitHubToken")
        c.applyPushedSnapshot(["workspaces": [old], "vms": []])
        #expect(c.credentials(for: id) == nil)
    }

    @Test("the host's row says which tokens a workspace holds, never their values")
    func hostRow() throws {
        var p = Profile(name: "codereview", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [GitHTTPSCredential(host: "github.com", username: "me", token: "ghp_secret")]
        #expect(p.hasGitHubCredential)
        let row: [String: Any] = ["hasGitHubToken": p.hasGitHubCredential,
                                  "hasLinearToken": !p.linearToken.isEmpty]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
        #expect(!json.contains("ghp_secret"))
    }
}
