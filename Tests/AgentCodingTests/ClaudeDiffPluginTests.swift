import Foundation
import Testing
@testable import bromure_ac

/// Board task: Claude Code's built-in /diff plugin opens its own multi-window
/// diff, which fights Bromure's session view. Every session start writes
/// `"enabledPlugins": {"cc-plugin-diff@builtin": false}` into
/// ~/.claude/settings.json -- the host's writer and bromure-agentd's twin --
/// keeping the user's other plugins.
@Suite("Claude Code's /diff plugin is kept off")
struct ClaudeDiffPluginTests {
    private func plugins(_ settings: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: settings),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o["enabledPlugins"] as? [String: Any] ?? [:]
    }
    private let userSettings = #"{"enabledPlugins": {"cc-plugin-diff@builtin": true, "my-plugin@market": true}, "theme": "dark"}"#

    @Test("the host's settings writer turns it off and keeps the user's other plugins")
    func hostWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diffplugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let claudeDir = store.homeDirectory(for: p).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try userSettings.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        let got = plugins(claudeDir.appendingPathComponent("settings.json"))
        #expect(got[ProfileStore.claudeDiffPlugin] as? Bool == false)
        #expect(got["my-plugin@market"] as? Bool == true)
        #expect(ProfileStore.claudeDiffPlugin == "cc-plugin-diff@builtin")
    }

    @Test("bromure-agentd's twin does the same in the guest",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func guestWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diffplugin-g-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let guestHome = root.appendingPathComponent("guest-home"), seedIn = root.appendingPathComponent("guest-seed")
        try FileManager.default.createDirectory(at: guestHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seedIn, withIntermediateDirectories: true)
        try userSettings.write(to: guestHome.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"usesClaude": true}"#.write(to: seedIn.appendingPathComponent("claude-settings.spec.json"), atomically: true, encoding: .utf8)
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, os
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m.SEED_DIR = sys.argv[2]; m.HOME_MOUNT = sys.argv[3]; m.HOME = sys.argv[3]
            m._approve_claude_api_key = lambda *a: None; m._preonboard_claude = lambda *a: None
            m.log = lambda *a: None
            os.chown = lambda *a, **k: None
            m._seed_claude_settings()
            """, agentd.path, seedIn.path, guestHome.path]
        py.standardError = FileHandle.nullDevice
        try py.run(); py.waitUntilExit()
        let got = plugins(guestHome.appendingPathComponent(".claude/settings.json"))
        #expect(got["cc-plugin-diff@builtin"] as? Bool == false)
        #expect(got["my-plugin@market"] as? Bool == true)
    }
}
