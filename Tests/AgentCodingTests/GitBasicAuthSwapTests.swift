import Foundation
import Testing
@testable import bromure_ac

/// git authenticates with `Authorization: Basic base64("<user>:<token>")`,
/// so the fake never appears in clear on the wire: the plan must carry the
/// Basic blob too, or every HTTPS clone of a private repo sends the fake.
@Suite("Git HTTPS Basic-auth swap")
struct GitBasicAuthSwapTests {
    @Test("A git token's plan swaps git's Basic blob, fake → real")
    func basicBlob() throws {
        var p = Profile(name: "git", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [GitHTTPSCredential(
            host: "github.com", username: "octo", token: "ghp_REALrealREALrealREALrealREALreal12")]
        let plan = p.makeTokenPlan(salt: Data("test-salt-32-bytes-of-entropy!!".utf8))
        let fake = try #require(plan.fakeForGitHTTPS(host: "github.com", username: "octo"))
        #expect(fake.hasPrefix("ghp_") && fake != "ghp_REALrealREALrealREALrealREALreal12")
        let fakeB64 = Data("octo:\(fake)".utf8).base64EncodedString()
        let realB64 = Data("octo:ghp_REALrealREALrealREALrealREALreal12".utf8).base64EncodedString()
        #expect(plan.entries.contains { $0.fakeValue == fakeB64 && $0.realValue == realB64 })
    }

    @Test("A blank username uses the forge's token convention in the Basic blob")
    func blankUser() throws {
        var p = Profile(name: "git", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [GitHTTPSCredential(
            host: "github.com", username: "", token: "ghp_REALrealREALrealREALrealREALreal12")]
        let plan = p.makeTokenPlan(salt: Data("test-salt-32-bytes-of-entropy!!".utf8))
        let fake = try #require(plan.fakeForGitHTTPS(host: "github.com", username: "x-access-token"))
        let fakeB64 = Data("x-access-token:\(fake)".utf8).base64EncodedString()
        #expect(plan.entries.contains { $0.fakeValue == fakeB64 })
    }
}
