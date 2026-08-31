import Foundation
import Testing
@testable import bromure_ac

// C1 regression: prepareHomeDirectory must never write a REAL credential into
// the (guest-visible, for virtiofs) home. Without a token plan it writes
// nothing for a credential; with a plan it writes only the derived fake.
@Suite("Home credential files carry only fakes")
struct HomeCredentialFakeTests {

    private func makeStore() throws -> (ProfileStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-c1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProfileStore(rootDir: root), root)
    }

    /// A profile carrying a real GitHub PAT, a real GitLab PAT, and a real
    /// docker-registry password — the three writers that used to fall back to
    /// the real value when called without a plan.
    private func credentialProfile() -> Profile {
        var p = Profile(name: "creds", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [
            GitHTTPSCredential(host: "github.com", username: "octo",
                               token: "ghp_REALrealREALrealREALrealREALreal12"),
            GitHTTPSCredential(host: "gitlab.com", username: "octo",
                               token: "glpat-REALREALREALREALreal"),
        ]
        p.dockerRegistries = [
            DockerRegistryCredential(host: "registry.example.com",
                                     username: "robot", password: "s3cr3t-REGISTRY-pw"),
        ]
        p.twilioCredential = TwilioCredential(
            sid: "ACtwilioSIDtwilioSIDtwilioSIDtwil",
            secret: "TWILIOrealTWILIOrealTWILIOreal12")
        return p
    }

    /// The real secret bytes that must never appear anywhere under the home.
    private let realNeedles = [
        "ghp_REALrealREALrealREALrealREALreal12",
        "glpat-REALREALREALREALreal",
        "s3cr3t-REGISTRY-pw",
        // docker stores base64("user:password"); the real blob must be absent too.
        Data("robot:s3cr3t-REGISTRY-pw".utf8).base64EncodedString(),
        // Twilio: the real Auth Token, and the base64("SID:secret") Basic blob.
        "TWILIOrealTWILIOrealTWILIOreal12",
        Data("ACtwilioSIDtwilioSIDtwilioSIDtwil:TWILIOrealTWILIOrealTWILIOreal12".utf8)
            .base64EncodedString(),
    ]

    /// Every regular file under `home`, as one concatenated blob, so a test can
    /// assert on the whole tree at once (git-credentials, docker/config.json,
    /// gh hosts.yml, glab config.yml all live at different depths).
    private func allHomeBytes(_ home: URL) -> String {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: home, includingPropertiesForKeys: nil) else { return "" }
        var blob = ""
        for case let url as URL in en {
            if let s = try? String(contentsOf: url, encoding: .utf8) { blob += s + "\n" }
        }
        return blob
    }

    @Test("Plan-less prepareHomeDirectory writes no real credential bytes")
    func planlessWritesNoReals() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = credentialProfile()

        // The exact call the editor save used to make.
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let blob = allHomeBytes(store.homeDirectory(for: p))
        for needle in realNeedles {
            #expect(!blob.contains(needle), "real secret leaked into the home: \(needle)")
        }
        // No plan → nothing to write with a fake → the credential files are
        // absent entirely (not written with reals).
        let home = store.homeDirectory(for: p)
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".git-credentials").path))
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".docker/config.json").path))
    }

    @Test("With a plan the home carries the fakes, never the reals")
    func planWritesFakesNotReals() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = credentialProfile()
        let plan = p.makeTokenPlan(salt: Data("test-salt-32-bytes-of-entropy!!".utf8))

        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load(),
                                       tokenPlan: plan)

        let home = store.homeDirectory(for: p)
        let blob = allHomeBytes(home)

        // Reals are absent everywhere.
        for needle in realNeedles {
            #expect(!blob.contains(needle), "real secret leaked despite a plan: \(needle)")
        }
        // The files exist and carry the FAKE the plan derived — the exact
        // value the MITM engine will swap back on the wire.
        let gitCreds = try String(
            contentsOf: home.appendingPathComponent(".git-credentials"), encoding: .utf8)
        let ghFake = try #require(plan.fakeForGitHTTPS(host: "github.com", username: "octo"))
        let glFake = try #require(plan.fakeForGitHTTPS(host: "gitlab.com", username: "octo"))
        #expect(gitCreds.contains(ghFake))
        #expect(gitCreds.contains(glFake))
        // Fakes keep the client-validator shape (ghp_/glpat-) but are NOT the
        // real tokens — verify they actually differ.
        #expect(ghFake != "ghp_REALrealREALrealREALrealREALreal12")
        #expect(glFake != "glpat-REALREALREALREALreal")

        let dockerJSON = try String(
            contentsOf: home.appendingPathComponent(".docker/config.json"), encoding: .utf8)
        let regFake = try #require(plan.fakeForDockerRegistry(
            host: "registry.example.com", username: "robot"))
        #expect(dockerJSON.contains(regFake))

        // gh / glab config files exist and carry the fakes, not the reals.
        let ghHosts = try String(
            contentsOf: home.appendingPathComponent(".config/gh/hosts.yml"), encoding: .utf8)
        #expect(ghHosts.contains(ghFake))
        let glabCfg = try String(
            contentsOf: home.appendingPathComponent(".config/glab-cli/config.yml"), encoding: .utf8)
        #expect(glabCfg.contains(glFake))
    }
}
