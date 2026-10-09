import Foundation
import Testing
@testable import bromure_ac

/// The guest ~/.gitconfig identity: a workspace with no identity anywhere
/// still commits, under a generic agent identity — never a real person's.
@Suite("Guest git identity defaults")
struct GitIdentityDefaultTests {
    private func template(_ name: String, _ email: String) -> Profile {
        var p = Profile(name: "tpl", tool: .claude, authMode: .token)
        p.gitUserName = name; p.gitUserEmail = email
        return p
    }

    @Test("No identity on the workspace, template or imported file → generic agent identity")
    func genericWhenUnset() {
        let id = ProfileStore.resolvedGitIdentity(name: " ", email: "", template: nil, importedGitconfig: nil)
        #expect(id.name == "Bromure Agent")
        #expect(id.email == "agent@bromure.invalid")
        let viaEmptyTemplate = ProfileStore.resolvedGitIdentity(
            name: "", email: "", template: template("", ""), importedGitconfig: "[core]\n    editor = vim\n")
        #expect(viaEmptyTemplate.name == "Bromure Agent")
        #expect(viaEmptyTemplate.email == "agent@bromure.invalid")
    }

    @Test("The workspace's own identity stands untouched")
    func ownIdentityKept() {
        let id = ProfileStore.resolvedGitIdentity(name: "Ada", email: "ada@example.com",
                                                  template: template("T", "t@example.com"), importedGitconfig: nil)
        #expect(id.name == "Ada")
        #expect(id.email == "ada@example.com")
    }

    @Test("The template's identity is used when the workspace has none")
    func templateIdentity() {
        let id = ProfileStore.resolvedGitIdentity(name: "", email: "",
                                                  template: template("T", "t@example.com"), importedGitconfig: nil)
        #expect(id.name == "T")
        #expect(id.email == "t@example.com")
    }

    @Test("Only a missing field is filled; an imported identity is never overridden")
    func partialAndImported() {
        let partial = ProfileStore.resolvedGitIdentity(name: "Ada", email: "", template: nil, importedGitconfig: nil)
        #expect(partial.name == "Ada")
        #expect(partial.email == "agent@bromure.invalid")
        let imported = ProfileStore.resolvedGitIdentity(
            name: "", email: "", template: nil,
            importedGitconfig: "[user]\n    name = Imported\n    email = i@example.com\n")
        #expect(imported.name.isEmpty)
        #expect(imported.email.isEmpty)
    }
}
