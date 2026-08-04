import Foundation
import Testing
@testable import bromure_ac

// Whole-file config import. The tests that matter most are the negative ones:
// this code decides what leaves the user's Mac and lands in a VM, so a secret
// surviving sanitization is a real leak, not a cosmetic bug.
@Suite("Config file sanitize")
struct ConfigFileSanitizeTests {

    // MARK: - gitconfig

    @Test("gitconfig: ordinary settings survive verbatim")
    func gitKeepsSettings() {
        let r = ConfigFileSanitize.gitConfig("""
        # my config
        [user]
            name = Ada Lovelace
        [alias]
            co = checkout
            lg = log --graph --oneline
        [pull]
            rebase = true
        [init]
            defaultBranch = main
        """)
        #expect(r.contents.contains("co = checkout"))
        #expect(r.contents.contains("lg = log --graph --oneline"))
        #expect(r.contents.contains("rebase = true"))
        #expect(r.contents.contains("defaultBranch = main"))
        #expect(r.contents.contains("# my config"))   // comments too
        #expect(r.strippedSecrets == 0)
    }

    @Test("gitconfig: a token in a url rewrite is dropped, body and all")
    func gitDropsURLToken() {
        let r = ConfigFileSanitize.gitConfig("""
        [url "https://ghp_SECRETVALUE@github.com/"]
            insteadOf = https://github.com/
        [alias]
            st = status
        """)
        #expect(!r.contents.contains("ghp_SECRETVALUE"))
        // The section's body must go with it — an orphaned insteadOf would
        // rewrite URLs to nothing.
        #expect(!r.contents.contains("insteadOf"))
        #expect(r.strippedSecrets == 1)
        #expect(r.contents.contains("st = status"))
    }

    @Test("gitconfig: a token in a plain value is dropped too")
    func gitDropsInlineToken() {
        let r = ConfigFileSanitize.gitConfig("""
        [remote "origin"]
            url = https://user:glpat_SECRET@gitlab.com/x/y.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """)
        #expect(!r.contents.contains("glpat_SECRET"))
        #expect(r.contents.contains("fetch = +refs/heads/*"))
        #expect(r.strippedSecrets == 1)
    }

    @Test("gitconfig: a token split across a continuation line can't sneak through")
    func gitDropsFoldedToken() {
        let r = ConfigFileSanitize.gitConfig("""
        [url "https://ghp_SPLIT\\
        TOKEN@github.com/"]
            insteadOf = https://github.com/
        """)
        #expect(!r.contents.contains("ghp_SPLIT"))
        #expect(!r.contents.contains("TOKEN@github.com"))
        #expect(r.strippedSecrets == 1)
    }

    @Test("gitconfig: macOS credential helper is dropped")
    func gitDropsHelper() {
        let r = ConfigFileSanitize.gitConfig("""
        [credential]
            helper = osxkeychain
        [credential "https://github.com"]
            helper = !gh auth git-credential
        """)
        #expect(!r.contents.contains("osxkeychain"))
        #expect(!r.contents.contains("gh auth git-credential"))
        #expect(r.disabled.contains("credential.helper"))
    }

    @Test("gitconfig: commit signing is forced off, not deleted")
    func gitDisablesSigning() {
        let r = ConfigFileSanitize.gitConfig("""
        [commit]
            gpgsign = true
        [tag]
            gpgsign = true
        [user]
            signingkey = ABC123
        """)
        // Left on, every commit in the VM fails: the key stayed on the host.
        #expect(!r.contents.contains("gpgsign = true"))
        #expect(r.contents.contains("gpgsign = false"))
        #expect(r.disabled.contains("commit.gpgsign"))
        #expect(r.disabled.contains("tag.gpgsign"))
        // The key reference is harmless once signing is off — keep it, so
        // turning signing back on by hand still works.
        #expect(r.contents.contains("signingkey = ABC123"))
    }

    @Test("gitconfig: signing already off is left exactly alone")
    func gitLeavesSigningOff() {
        let r = ConfigFileSanitize.gitConfig("""
        [commit]
            gpgsign = false
        """)
        #expect(r.disabled.isEmpty)
        #expect(r.contents.contains("gpgsign = false"))
    }

    @Test("gitconfig: a file that is nothing but secrets sanitizes to empty")
    func gitAllSecrets() {
        let r = ConfigFileSanitize.gitConfig("""
        [credential]
            helper = osxkeychain
        """)
        #expect(r.isEmpty)   // caller stores nil rather than an empty file
    }

    // MARK: - npmrc

    @Test("npmrc: auth lines out, registry config in")
    func npm() {
        let r = ConfigFileSanitize.npmrc("""
        //registry.npmjs.org/:_authToken=npm_SECRET
        @acme:registry=https://npm.acme.dev
        strict-ssl=true
        prefix=/Users/ada/.npm-global
        """)
        #expect(!r.contents.contains("npm_SECRET"))
        #expect(r.contents.contains("@acme:registry=https://npm.acme.dev"))
        #expect(r.contents.contains("strict-ssl=true"))
        // The guest pins its own prefix; a /Users path would break global installs.
        #expect(!r.contents.contains("prefix="))
        #expect(r.strippedSecrets == 1)
        #expect(r.disabled.contains("prefix"))
    }

    // MARK: - pypirc

    @Test("pypirc: passwords out, index layout in")
    func pypi() {
        let r = ConfigFileSanitize.pypirc("""
        [distutils]
        index-servers =
            pypi
            acme

        [acme]
        repository = https://pypi.acme.dev/simple
        username = __token__
        password = pypi-SECRET
        """)
        #expect(!r.contents.contains("pypi-SECRET"))
        #expect(!r.contents.contains("__token__"))
        #expect(r.contents.contains("repository = https://pypi.acme.dev/simple"))
        #expect(r.contents.contains("[acme]"))
        #expect(r.strippedSecrets == 2)
    }

    // MARK: - path safety

    @Test("an imported path can never escape the home directory")
    func pathSafety() {
        #expect(ImportedConfigFile.isSafeRelativePath(".gitconfig"))
        #expect(ImportedConfigFile.isSafeRelativePath(".config/gh/config.yml"))
        #expect(!ImportedConfigFile.isSafeRelativePath("/etc/passwd"))
        #expect(!ImportedConfigFile.isSafeRelativePath("../../etc/passwd"))
        #expect(!ImportedConfigFile.isSafeRelativePath(".ssh/../../escape"))
        #expect(!ImportedConfigFile.isSafeRelativePath("~/.gitconfig"))
        #expect(!ImportedConfigFile.isSafeRelativePath(""))
    }

    @Test("a profile decoded with an unsafe imported path drops it")
    func decodeRejectsUnsafePath() throws {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.importedConfigFiles = [ImportedConfigFile(path: ".gitconfig", contents: "[alias]\n x = y\n")]
        var doc = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as! [String: Any]
        // Tamper the way a hand-edited (or hostile) profile JSON would.
        doc["importedConfigFiles"] = [["path": "../../../../etc/cron.d/x",
                                       "contents": "* * * * * root sh\n",
                                       "strippedSecrets": 0, "disabled": []]]
        let back = try JSONDecoder().decode(
            Profile.self, from: JSONSerialization.data(withJSONObject: doc))
        #expect(back.importedConfigFiles.isEmpty)
    }

    @Test("imported files survive a profile encode/decode round trip")
    func roundTrip() throws {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.importedConfigFiles = [
            ImportedConfigFile(path: ".gitconfig", contents: "[alias]\n    co = checkout\n",
                               strippedSecrets: 2, disabled: ["credential.helper"])]
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.importedConfigFiles.count == 1)
        #expect(back.importedConfigFiles[0].contents.contains("co = checkout"))
        #expect(back.importedConfigFiles[0].strippedSecrets == 2)
        #expect(back.importedConfigFiles[0].disabled == ["credential.helper"])
    }

    @Test("a profile written before this feature still decodes")
    func backCompat() throws {
        let p = Profile(name: "t", tool: .claude, authMode: .token)
        var doc = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as! [String: Any]
        doc.removeValue(forKey: "importedConfigFiles")
        let back = try JSONDecoder().decode(
            Profile.self, from: JSONSerialization.data(withJSONObject: doc))
        #expect(back.importedConfigFiles.isEmpty)
    }
}

// What actually lands in the guest. The sanitizer tests above prove the right
// bytes are stored; these prove they reach ~/.gitconfig in the right ORDER —
// git resolves single-valued keys last-wins, so a managed identity written
// before the imported file would be silently overridden by it.
@Suite("Imported config files reach the guest home")
struct ImportedConfigFileHomeTests {

    private func makeStore() throws -> (ProfileStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-imported-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProfileStore(rootDir: root), root)
    }

    @Test("imported .gitconfig is written, with the managed identity winning")
    func gitconfigMerge() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.gitUserName = "Managed Name"
        p.gitUserEmail = "managed@example.com"
        p.importedConfigFiles = [ImportedConfigFile(path: ".gitconfig", contents: """
        [user]
            name = Imported Name
        [alias]
            co = checkout
        [pull]
            rebase = true
        """)]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let text = try String(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".gitconfig"), encoding: .utf8)
        // The user's own settings made it across.
        #expect(text.contains("co = checkout"))
        #expect(text.contains("rebase = true"))
        // Both identities are present, but the managed one comes last and wins.
        let importedAt = try #require(text.range(of: "Imported Name")).lowerBound
        let managedAt = try #require(text.range(of: "Managed Name")).lowerBound
        #expect(importedAt < managedAt)
        // Still recognizable as ours, so the cleanup sweep can reclaim it.
        #expect(text.hasPrefix("# Managed by Bromure Agentic Coding."))
    }

    @Test("imported .npmrc rides under the managed prefix")
    func npmrcMerge() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.importedConfigFiles = [ImportedConfigFile(
            path: ".npmrc", contents: "@acme:registry=https://npm.acme.dev\n")]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let text = try String(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".npmrc"), encoding: .utf8)
        #expect(text.contains("prefix=/home/ubuntu/.npm-global"))
        #expect(text.contains("@acme:registry=https://npm.acme.dev"))
    }

    @Test("a file with no managed counterpart is written verbatim")
    func plainFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.importedConfigFiles = [ImportedConfigFile(
            path: ".pypirc", contents: "[distutils]\nindex-servers =\n    acme\n")]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let text = try String(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".pypirc"), encoding: .utf8)
        #expect(text.contains("index-servers"))
    }

    @Test("an unsafe path is refused at write time, not just at decode")
    func unsafePathNotWritten() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        // Bypasses the decode filter the way in-memory construction would.
        p.importedConfigFiles = [ImportedConfigFile(
            path: "../escaped.txt", contents: "nope\n")]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let escaped = store.homeDirectory(for: p)
            .deletingLastPathComponent().appendingPathComponent("escaped.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test("no imported .gitconfig keeps the old generated-only behaviour")
    func withoutImport() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.gitUserName = "Ada"
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())
        let text = try String(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".gitconfig"), encoding: .utf8)
        #expect(text.contains("name  = Ada"))
        #expect(!text.contains("imported from your Mac"))
    }
}

// Regression: the identity must not be carried twice.
@Suite("Identity stays in exactly one place")
struct ImportedIdentityOwnershipTests {

    @Test("gitconfig: user.name/email are left to the typed field")
    func identityNotDuplicated() {
        let r = ConfigFileSanitize.gitConfig("""
        [user]
            name = Ada Lovelace
            email = ada@example.com
            signingkey = ABC123
        [alias]
            co = checkout
        """)
        #expect(!r.contents.contains("Ada Lovelace"))
        #expect(!r.contents.contains("ada@example.com"))
        #expect(r.contents.contains("signingkey = ABC123"))  // no typed home
        #expect(r.contents.contains("co = checkout"))
    }

    @Test("an identity-only gitconfig carries nothing extra")
    func identityOnlyIsEmpty() {
        // The common case: most people's ~/.gitconfig is just a name and email,
        // which the typed importer already handles. Nothing left to carry.
        let r = ConfigFileSanitize.gitConfig("""
        [user]
            name = Ada Lovelace
            email = ada@example.com
        """)
        #expect(r.isEmpty)
    }

    @Test("clearing the identity can't resurrect an imported one")
    func clearedIdentityStaysCleared() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-ident-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.gitUserName = ""      // user cleared the editor fields
        p.gitUserEmail = ""
        p.importedConfigFiles = [ImportedConfigFile(
            path: ".gitconfig",
            contents: ConfigFileSanitize.gitConfig("""
            [user]
                name = Stale Name
            [alias]
                co = checkout
            """).contents)]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let text = try String(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".gitconfig"), encoding: .utf8)
        #expect(!text.contains("Stale Name"))
        #expect(text.contains("co = checkout"))
    }
}
