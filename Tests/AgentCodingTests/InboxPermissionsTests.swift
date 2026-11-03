import Foundation
import Testing
@testable import bromure_ac

/// Files other agents hand over land in ~/.bromure/inbox: a workspace VM's
/// Claude reads them without a prompt (its home is that workspace's own);
/// editing or unpacking them, and anything on a Sidecar Mac, goes through
/// the approval mode.
@Suite("Delegation inbox permissions")
struct InboxPermissionsTests {

    private func settings(after existing: [String: Any]?) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-perms-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let claudeDir = store.homeDirectory(for: p).appendingPathComponent(".claude")
        let url = claudeDir.appendingPathComponent("settings.json")
        if let existing {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: existing).write(to: url)
        }
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("a workspace's Claude may read the inbox, not edit it, and has it as a working directory")
    func seeded() throws {
        let perms = try #require(try settings(after: nil)["permissions"] as? [String: Any])
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.contains("Read(~/.bromure/inbox/**)"))
        #expect(!allow.contains { $0.hasPrefix("Edit(") || $0.hasPrefix("Write(") })
        #expect(perms["additionalDirectories"] as? [String] == ["~/.bromure/inbox"])
    }

    /// Finding (CWE-732): "Sidecar Claude can read and edit every
    /// workspace's delegation inbox without a prompt" — the Edit rule was
    /// re-added on every merge, so a user couldn't drop it.
    @Test("an inbox Edit rule an earlier build seeded is taken back out; the user's own rules stay")
    func editRetracted() throws {
        let existing: [String: Any] = ["permissions": [
            "allow": ["Bash(make *)", "Read(~/.bromure/inbox/**)", "Edit(~/.bromure/inbox/**)", "Edit(src/**)"],
        ]]
        let allow = try #require((try settings(after: existing)["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(!allow.contains("Edit(~/.bromure/inbox/**)"))
        #expect(allow.contains("Edit(src/**)") && allow.first == "Bash(make *)")
    }

    /// The Sidecar runs Claude on a plain Mac whose home — and inbox — is
    /// shared by every session there and every Bromure linked to it.
    @Test("the Sidecar's Claude settings grant nothing on the shared inbox")
    func sidecarGrantsNoInbox() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentHost/ClaudeHooks.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.contains { $0.contains(".bromure/inbox") })
        #expect(code.contains { $0.contains(#""allow": ["mcp__delegation"]"#) })
    }

    @Test("the user's own rules and directories are kept, and nothing is added twice")
    func merged() throws {
        let existing: [String: Any] = ["permissions": [
            "allow": ["Bash(make *)", "Read(~/.bromure/inbox/**)"],
            "additionalDirectories": ["~/notes", "~/.bromure/inbox"],
        ]]
        let perms = try #require(try settings(after: existing)["permissions"] as? [String: Any])
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.first == "Bash(make *)")
        #expect(allow.filter { $0 == "Read(~/.bromure/inbox/**)" }.count == 1)
        #expect(perms["additionalDirectories"] as? [String] == ["~/notes", "~/.bromure/inbox"])
    }

    @Test("the guest-side rewrite carries the same rules")
    func guestMirror() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = try String(contentsOf: url, encoding: .utf8)
        for rule in ProfileStore.claudeAlwaysAllowed { #expect(py.contains("\"\(rule)\"")) }
        for rule in ProfileStore.claudeRetractedRules {
            #expect(py.contains("_CLAUDE_RETRACTED_RULES = [\"\(rule)\"]"))
        }
        #expect(py.contains("allow = [r for r in allow if r not in _CLAUDE_RETRACTED_RULES]"))
        let always = try #require(py.range(of: "_CLAUDE_ALWAYS_ALLOWED = [").map { py[$0.upperBound...] })
        #expect(!always.prefix(while: { $0 != "]" }).contains("Edit("))
        #expect(py.contains("_CLAUDE_INBOX_DIR = \"\(ProfileStore.claudeInboxDirectory)\""))
    }
}
