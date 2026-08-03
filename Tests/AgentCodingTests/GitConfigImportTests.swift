import Foundation
import Testing
@testable import bromure_ac

// Importing a real ~/.gitconfig. The point isn't just convenience: a token
// lifted out of a URL rewrite becomes a GitHTTPSCredential, so the real value
// stays on the host and the VM gets a fake the proxy swaps back. Getting the
// parse wrong therefore either loses a credential or ships a real token into
// the guest, so the shapes below are all drawn from configs seen in the wild.
@Suite("GitConfig import")
struct GitConfigImportTests {

    @Test("identity only")
    func identity() throws {
        let r = try GitConfigImport.parse("""
        [user]
            name = Ada Lovelace
            email = ada@example.com
        [core]
            editor = vim
        """)
        #expect(r.identity.name == "Ada Lovelace")
        #expect(r.identity.email == "ada@example.com")
        #expect(r.entries.isEmpty)
    }

    @Test("token baked into a url rewrite becomes a swappable credential")
    func urlRewriteToken() throws {
        let r = try GitConfigImport.parse("""
        [url "https://ghp_abc123@github.com/"]
            insteadOf = https://github.com/
        [url "https://oauth2:glpat-xyz@gitlab.com/"]
            insteadOf = https://gitlab.com/
        """)
        #expect(r.entries.count == 2)
        let gh = try #require(r.entries.first { $0.host == "github.com" })
        // A bare-token URL has no user; git's conventional placeholder keeps
        // the generated .git-credentials line valid.
        #expect(gh.username == "x-access-token")
        #expect(gh.token == "ghp_abc123")
        let gl = try #require(r.entries.first { $0.host == "gitlab.com" })
        #expect(gl.username == "oauth2")
        #expect(gl.token == "glpat-xyz")
    }

    @Test("percent-encoded tokens are decoded")
    func percentEncoded() throws {
        let r = try GitConfigImport.parse("""
        [url "https://me%40corp.com:tok%2Fwith%2Fslashes@git.example.com/"]
            insteadOf = https://git.example.com/
        """)
        let e = try #require(r.entries.first)
        #expect(e.username == "me@corp.com")
        #expect(e.token == "tok/with/slashes")
        #expect(e.host == "git.example.com")
    }

    @Test("a host with no token is reported, not silently dropped")
    func noTokenIsReported() throws {
        let r = try GitConfigImport.parse("""
        [credential "https://github.com"]
            username = someone
        [url "https://github.com/"]
            insteadOf = git@github.com:
        """)
        #expect(r.entries.isEmpty)
        #expect(r.skippedNoToken == 2)
    }

    @Test("classic github basic-auth: the token is the USER half")
    func placeholderPasswords() throws {
        // `https://<token>:x-oauth-basic@github.com` is the old GitHub scheme:
        // the token sits in the user field and the password is a dummy. Reading
        // it the other way round would import "x-oauth-basic" as the token and
        // silently lose the real one.
        let r = try GitConfigImport.parse("""
        [url "https://ghp_realtoken:x-oauth-basic@github.com/"]
            insteadOf = https://github.com/
        """)
        let e = try #require(r.entries.first)
        #expect(e.token == "ghp_realtoken")
        #expect(e.username == "x-access-token")
    }

    @Test("comments, quoting and line continuations")
    func lexing() throws {
        let r = try GitConfigImport.parse("""
        # a comment with an @ and a [section]
        [user]
            name = "Ada # Lovelace"   ; trailing comment
            email = ada@example.com
        [url "https://tok_continued@github.com/"]
            insteadOf = https://gi\\
        thub.com/
        """)
        // The `#` inside quotes is part of the name, not a comment.
        #expect(r.identity.name == "Ada # Lovelace")
        #expect(r.entries.first?.token == "tok_continued")
    }

    @Test("dotted legacy section header")
    func dottedHeader() throws {
        let r = try GitConfigImport.parse("""
        [url.https://tok_legacy@github.com/]
            insteadOf = https://github.com/
        """)
        #expect(r.entries.first?.token == "tok_legacy")
    }

    @Test("duplicate host+user keeps the first")
    func duplicates() throws {
        let r = try GitConfigImport.parse("""
        [url "https://u:first@github.com/"]
            insteadOf = https://github.com/
        [url "https://u:second@github.com/"]
            insteadOf = https://github.com/
        """)
        #expect(r.entries.count == 1)
        #expect(r.entries.first?.token == "first")
    }

    @Test("a config with nothing useful throws rather than importing silence")
    func nothingFound() {
        #expect(throws: GitConfigImport.Error.self) {
            _ = try GitConfigImport.parse("[core]\n\teditor = vim\n")
        }
    }

    @Test("remote urls carrying a token are picked up too")
    func remoteURL() throws {
        let r = try GitConfigImport.parse("""
        [remote "origin"]
            url = https://user:ghp_fromremote@github.com/acme/repo.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """)
        let e = try #require(r.entries.first)
        #expect(e.host == "github.com")
        #expect(e.token == "ghp_fromremote")
        // The path must not leak into the host.
        #expect(!e.host.contains("/"))
    }
}

// The security property that makes importing a gitconfig *safer* than sharing
// one: whatever host a token came from, the guest gets a FAKE and the real
// value stays on the host for the proxy to swap in. A regression here would
// ship someone's real token into the VM, so it is asserted directly rather
// than inferred from the import path.
@Suite("Imported git tokens are faked for the guest")
struct ImportedGitTokenSwapTests {

    private func plan(for creds: [GitHTTPSCredential]) -> SessionTokenPlan {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = creds
        return p.makeTokenPlan(salt: Data(repeating: 7, count: 32))
    }

    @Test("a self-hosted forge token is faked too, not passed through")
    func arbitraryHostIsFaked() throws {
        let real = "ghp_thisisarealtokenvalue0000000000000000"
        let imported = try #require(GitConfigImport.credential(
            fromURL: "https://ci:\(real)@git.internal.example.com/"))
        let p = plan(for: [GitHTTPSCredential(host: imported.host,
                                              username: imported.username,
                                              token: imported.token)])
        let fake = try #require(p.fakeForGitHTTPS(host: imported.host,
                                                  username: imported.username))
        #expect(fake != real, "the guest must never receive the real token")
        #expect(!fake.isEmpty)
    }

    @Test("github/gitlab fakes keep the shape their CLIs validate")
    func knownForgeShapes() throws {
        let creds = [
            GitHTTPSCredential(host: "github.com", username: "u", token: "ghp_real000000000000000000000000000000000"),
            GitHTTPSCredential(host: "gitlab.com", username: "u", token: "glpat-real0000000000000"),
        ]
        let p = plan(for: creds)
        let gh = try #require(p.fakeForGitHTTPS(host: "github.com", username: "u"))
        let gl = try #require(p.fakeForGitHTTPS(host: "gitlab.com", username: "u"))
        // gh/glab reject tokens whose prefix or length is wrong, so a fake that
        // doesn't match the shape breaks the CLIs inside the VM.
        #expect(gh.hasPrefix("ghp_")); #expect(gh.count == 40)
        #expect(gl.hasPrefix("glpat-")); #expect(gl.count == 26)
        #expect(gh != creds[0].token); #expect(gl != creds[1].token)
    }
}
