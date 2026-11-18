import Foundation
import Testing
@testable import bromure_ac

/// "Hermes fails to launch": a workspace's Hermes setup (`hermes pm repair`)
/// failed opening the image's root-only install lock, or downloaded every
/// package from PyPI (the image's own download cache was root's alone) and
/// timed out; and a Mac's Hermes install records, imported with the agent's
/// config, sent it rebuilding that Mac's environment by its /Users path.
@Suite("Hermes workspace setup")
struct HermesWorkspaceSetupTests {
    private static let top = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func step(_ seq: Int) throws -> [String: Any] {
        let data = try Data(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Resources/img-catalog.json"))
        let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try #require(doc["postinstall"] as? [[String: Any]])
        return try #require(steps.first { ($0["seq"] as? Int) == seq })
    }

    @Test("the image step gives every workspace the packages and the lock")
    func imageStep() throws {
        let s = try Self.step(39)
        let cmd = try #require(s["command"] as? String)
        // After the Hermes install itself (38), from the same app version.
        #expect(try Self.step(38)["min_version"] as? String == s["min_version"] as? String)
        #expect(cmd.contains("mv /opt/hermes/cache/uv /opt/hermes/uv-cache"))
        #expect(cmd.contains("chmod -R a+rX /opt/hermes/uv-cache"))
        #expect(cmd.contains("chmod 666 /opt/hermes/tools/.install.lock"))
        #expect(cmd.contains("chmod a+r /opt/hermes/tools/facts.json"))
        #expect(cmd.contains("if [ -d /opt/hermes/hermes-agent ] && [ -d /opt/hermes/tools ]; then"), "nothing without Hermes in /opt")
        // It parses (bash -n): a broken step fails the image build.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", "-c", cmd]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test("a network hiccup gets one retry")
    func retry() throws {
        let rc = try String(contentsOf: Self.top.appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        #expect(rc.contains("|| { sleep 3; command hermes pm repair >>/tmp/bromure-tool-install.log 2>&1; }; then"))
    }

    @Test("another Mac's Hermes install state isn't imported, nor seeded if it was", arguments: [
        (".hermes/installs/bceb66d11c12ceaa/facts.json", true),
        (".hermes/installs/bceb66d11c12ceaa/pm-runtime/selected.json", true),
        (".hermes/shared/nous_auth.json", true),
        (".hermes/runtime/state.json", true),
        (".hermes/SOUL.md", false),
        (".hermes/skills/review/SKILL.md", false),
        (".hermes/memories/notes.md", false),
        (".claude/settings.json", false),
        (".gitconfig", false),
    ])
    func denied(path: String, denied: Bool) {
        #expect(AgentConfigScan.isDenied(homeRelativePath: path) == denied)
    }

    @Test("a scan of a Mac's ~/.hermes leaves its install records")
    func scan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hscan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let h = home.appendingPathComponent(".hermes", isDirectory: true)
        for (rel, body) in [("SOUL.md", "be kind"),
                            ("installs/abc/facts.json", "{\"environment\": \"/Users/x/.hermes/installs/abc\"}"),
                            ("shared/nous_auth.json", "{}")] {
            let url = h.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let source = try #require(AgentConfigScan.sources.first { $0.tool == .hermes })
        let r = try #require(AgentConfigScan.scan(source, home: home))
        #expect(r.files.map(\.path) == [".hermes/SOUL.md"])
    }
}
