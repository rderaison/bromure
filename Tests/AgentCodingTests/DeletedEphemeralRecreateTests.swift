import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-459): "The other Bromure process recreates a deleted vm run
/// --rm workspace, including its secrets". The GUI and the login agent share
/// one store, each with its own `profiles`. One's sweep deleted a stopped
/// `--rm` workspace; the other still listed it, and Start (sidebar, fat
/// client, automation) reached `launch`, whose `store.touch` → `save`
/// recreated the directory with profile.json and secrets.enc -- without the
/// `ephemeral` marker, so it came back as a kept workspace.
@Suite("A workspace the other process deleted stays deleted")
struct DeletedEphemeralRecreateTests {
    @Test("touch on a deleted workspace refuses and writes nothing")
    func touchDoesNotRecreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "rm-run", tool: .claude, authMode: .token)
        try store.save(p)
        store.markEphemeral(p)
        #expect(store.exists(p))
        try store.touch(p)                       // still there: stamped
        // The other process's sweep.
        try store.delete(p)
        #expect(throws: ProfileStore.ProfileGone.self) { try store.touch(p) }
        #expect(!FileManager.default.fileExists(atPath: store.profileDirectory(for: p).path))
        #expect(!store.exists(p))
        #expect(store.loadAll().isEmpty)
        #expect(ProfileStore.ProfileGone(name: "rm-run").localizedDescription.contains("rm-run"))
        // Nor does an update from the stale in-memory copy.
        var edited = p
        edited.squelch.enabled = true
        #expect(throws: ProfileStore.ProfileGone.self) { try store.update(edited) }
        #expect(!FileManager.default.fileExists(atPath: store.profileDirectory(for: p).path))
        // A saved one updates.
        let kept = Profile(name: "kept", tool: .claude, authMode: .token)
        try store.save(kept)
        var k2 = kept
        k2.squelch.enabled = true
        try store.update(k2)
        #expect(store.loadAll().first { $0.id == kept.id }?.squelch.enabled == true)
    }

    @Test("a fat-client Start (POST /vms) of a deleted workspace answers 404 instead of saving it back")
    func fatClientStart() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        let start = try #require(ac.range(of: "private func automationCreateVM(spec: [String: Any]) async -> [String: Any]? {"))
        let body = ac[start.upperBound...]
        let gone = try #require(body.range(of: "guard store.exists(existing) else {"))
        let save = try #require(body.range(of: "do { try store.save(profile) }"))
        #expect(gone.lowerBound < save.lowerBound)
        #expect(body[gone.lowerBound...].prefix(400).contains("\"notFound\": true"))
        // Updates from an in-memory row never recreate one either.
        for (file, needle) in [("Sources/AgentCoding/BromureAC.swift", "p.squelch.enabled = on\n        do { try store.update(p) }"),
                               ("Sources/AgentCoding/BromureAC.swift", "change(&saved)\n        try? store.update(saved)"),
                               ("Sources/AgentCoding/FirewallRuleActions.swift", "p.egressRules = text\n        do { try store.update(p) }"),
                               ("Sources/AgentCoding/SupplyChainOverrides.swift", "do { try store.update(p) }"),
                               ("Sources/AgentCoding/ScriptCommands.swift", "try d.store.update(incoming)"),
                               ("Sources/AgentCoding/ScriptCommands.swift", "try d.store.update(p)")] {
            #expect(try src(file).contains(needle), "\(file): \(needle)")
        }
    }

    @Test("launch checks the disk before it asks or boots, and again at touch; an edit doesn't write it back")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "    func launch(_ profile: Profile, detached: Bool = false,"))
        let body = src[start.upperBound...]
        let check = try #require(body.range(of: "guard store.exists(profile) else { forgetDeletedProfile(profile, unattended: unattended); return }"))
        let firstPrompt = try #require(body.range(of: "alert.runModal()"))
        #expect(check.lowerBound < firstPrompt.lowerBound)
        let touch = try #require(body.range(of: "let written = try store.touch(profile)"))
        #expect(body[touch.upperBound...].prefix(600).contains("} catch is ProfileStore.ProfileGone {"))
        #expect(!src.contains("try? store.touch(profile)"))
        let persist = try #require(src.range(of: "func persistEditedProfile("))
        #expect(src[persist.upperBound...].prefix(1200).contains("if editing != nil, !store.exists(profile) {"))
    }
}
