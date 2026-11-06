import Foundation
import Testing
@testable import bromure_ac

/// Finding: "Codex and Grok findings_done lose their closing grace despite
/// having no supported quiet probe". With Codex and Grok trusted for hook
/// completion, a findings_done from one of them no longer got the 45 s
/// grace, and the quiet probe that replaced it only globbed Claude's and
/// Kimi's transcript trees: it printed nothing, read as quiet, and the
/// watch's tab was archived two seconds after the call, its closing message
/// missing from the saved transcript. The probe now finds each agent's own
/// transcript, and a declared done with nothing to watch keeps the grace.
@Suite("A declared done waits on the agent's own transcript, or the grace")
struct DeclaredDoneQuietTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    /// Runs `cmd` with `home` as $HOME and no tmux on the path (no tab
    /// marker: the run's tab is gone or never listed).
    private static func run(_ cmd: String, home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tempHome() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("ddq-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    @Test("the probe reads a Codex rollout's age (by its session_meta cwd)")
    func codexAge() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent(".codex/sessions/2026/11/02")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"cwd":"/home/ubuntu/wt/watch-pr-12"}}"#
            .write(to: day.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
        let cmd = try #require(CodingTaskEngine.transcriptAgeCommand(slug: "watch-pr-12", agent: .codex))
        let age = try #require(Int(try Self.run(cmd, home: home)))
        #expect((0...30).contains(age))
        // Another run's rollout is not this one's.
        #expect(try Self.run(try #require(CodingTaskEngine.transcriptAgeCommand(slug: "other-run", agent: .codex)),
                             home: home).isEmpty)
        // Claude's and Kimi's probe never saw it: that was the hole.
        #expect(try Self.run(try #require(CodingTaskEngine.transcriptAgeCommand(slug: "watch-pr-12")), home: home).isEmpty)
    }

    @Test("the probe reads a Grok session's age (its per-cwd store)")
    func grokAge() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".grok/sessions/%2Fhome%2Fubuntu%2Fwt%2Fwatch-pr-12/s1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}\n".write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let cmd = try #require(CodingTaskEngine.transcriptAgeCommand(slug: "watch-pr-12", agent: .grok))
        let age = try #require(Int(try Self.run(cmd, home: home)))
        #expect((0...30).contains(age))
    }

    /// Finding: "omp completion now waits on unrelated sessions because its
    /// probe uses the wrong directory encoding". omp stores ~/proj as
    /// `-proj` (scoped to the home), the probe looked for `-home-ubuntu-proj`,
    /// missed, and watched the newest omp session anywhere: another session
    /// writing on held a finished run's completion up to its 30-minute cap.
    @Test("the omp probe reads the run's own session dir (omp's scoped name), never another session's")
    func ompAge() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = home.appendingPathComponent(".omp/agent/sessions")
        let mine = store.appendingPathComponent("-wt-watch-pr-12")        // ~/wt/watch-pr-12
        let other = store.appendingPathComponent("-proj")                  // ~/proj, still writing
        for d in [mine, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "{}\n".write(to: mine.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: mine.appendingPathComponent("s1.jsonl").path)
        try "{}\n".write(to: other.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        let cmd = try #require(CodingTaskEngine.transcriptAgeCommand(slug: "watch-pr-12", agent: .omp))
        let age = try #require(Int(try Self.run(cmd, home: home)))
        #expect((590...700).contains(age), "read another session's age: \(age)")
        // A run whose session can't be found prints nothing (the grace holds),
        // not the age of whatever omp session wrote last.
        let none = try #require(CodingTaskEngine.transcriptAgeCommand(slug: "fix-leak-0720", agent: .omp))
        #expect(try Self.run(none, home: home).isEmpty)
        // The transcript view finds the same file, and nothing for a stranger.
        let view = try #require(CodingTaskEngine.taskTranscriptCommand(branch: "wt/watch-pr-12", agent: .omp))
        #expect(try Self.run(view, home: home) == "{}")
        let stranger = try #require(CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-leak-0720", agent: .omp))
        #expect(try Self.run(stranger, home: home).isEmpty)
    }

    @Test("omp's scoped dir names: under the home, /tmp, elsewhere")
    func ompDirNames() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func name(_ path: String) throws -> String {
            try Self.run("src=\"\(path)\"; " + AgentSessionLocator.ompDirName("src", into: "v") + "printf %s \"$v\"", home: home)
        }
        #expect(try name(home.path) == "-")
        #expect(try name(home.path + "/proj/a") == "-proj-a")
        #expect(try name("/tmp/x") == "-tmp-x")
        #expect(try name("/mnt/share/x") == "--mnt-share-x--")
    }

    @Test("Claude and Kimi keep the whole-tree probe; a bad slug gets none")
    func otherAgents() throws {
        for agent: Profile.Tool? in [nil, .claude, .kimi] {
            let cmd = try #require(CodingTaskEngine.transcriptAgeCommand(slug: "fix-leak-0720", agent: agent))
            #expect(cmd.contains("*-fix-leak-0720") && cmd.contains("%T@"))
        }
        for agent: Profile.Tool in [.codex, .grok, .omp] {
            #expect(CodingTaskEngine.transcriptAgeCommand(slug: "bad'slug", agent: agent) == nil)
        }
    }

    @Test("a declared done is held on the probe, and on the grace when it read nothing")
    func declaredGrace() throws {
        let s = try Self.src("Sources/AgentCoding/ScheduledAutomations.swift")
        let declared = try #require(s.range(of: "func runDeclaredDone(profileID: UUID, worktreeBranch: String?) -> Bool {"))
        #expect(s[declared.upperBound...].prefix(700).contains("declared: true)"))
        let finish = try #require(s.range(of: "profileID: UUID, branch: String, declared: Bool) {"))
        let body = s[finish.upperBound...].prefix(1800)
        let watch = try #require(body.range(of: "let watched = await self?.delegate?.waitForSessionQuiet(profileID: profileID,\n                                                                    branch: branch, tool: tool) ?? false"))
        let grace = try #require(body.range(of: "if declared && !watched {\n                try? await Task.sleep(nanoseconds: Self.declaredDoneGrace)"))
        let stamp = try #require(body.range(of: "self.store.markCompleted(runID)"))
        #expect(watch.lowerBound < grace.lowerBound && grace.lowerBound < stamp.lowerBound)
        // The tasks' settles name their agent too.
        let t = try Self.src("Sources/AgentCoding/CodingTasks.swift")
        #expect(t.components(separatedBy: "branch: branch, tool: tool)").count - 1 == 2)
    }
}
