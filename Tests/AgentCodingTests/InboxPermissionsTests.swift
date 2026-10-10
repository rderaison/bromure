import Foundation
import Testing
@testable import bromure_ac

/// Files other agents hand over land in ~/.bromure/inbox: every workspace's
/// Claude reads and unpacks them without a prompt (running one still goes
/// through its approval mode).
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

    @Test("a workspace's Claude may read and edit the inbox, and has it as a working directory")
    func seeded() throws {
        let perms = try #require(try settings(after: nil)["permissions"] as? [String: Any])
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.contains("Read(~/.bromure/inbox/**)"))
        #expect(allow.contains("Edit(~/.bromure/inbox/**)"))
        #expect(perms["additionalDirectories"] as? [String] == ["~/.bromure/inbox"])
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
        #expect(py.contains("_CLAUDE_INBOX_DIR = \"\(ProfileStore.claudeInboxDirectory)\""))
    }
}
