import Foundation
import Testing

/// E2E 34.10 failed on Jenkins with "the host never listed tab 1" and nothing
/// in agentd's log: a failed tabs.txt write, or a failed tmux list-windows
/// while the session still existed, were both silent — the host just kept the
/// last tab list. They're now logged, once per streak, and when they recover.
@Suite("agentd says when its tab roster stops reaching the host")
struct AgentdRosterNoteTests {
    @Test("a failed publish or list is logged once per streak, and its recovery too",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func rosterNotes() throws {
        let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outbox) }
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys, json, subprocess
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            logs = []
            m.log = lambda tag, *a: logs.append(tag + ": " + " ".join(str(x) for x in a))
            m._git_toplevel = lambda cwd: ""
            row = "\\t".join(["0", "1", "bash", "/dev/pts/0", "", "", "", "", "", "", "", "0", ""])
            state = {"rc": 0}
            m._tmux = lambda *a: subprocess.CompletedProcess(a, state["rc"], row + "\\n" if state["rc"] == 0 else "", "boom")
            m._has_session = lambda: True
            out = {}
            m.OUTBOX = "/nonexistent/outbox"            # can't be written
            m.publish_roster(); m.publish_roster(); m.publish_roster()
            out["publish_fail"] = [l for l in logs if "tabs.txt" in l]
            m.OUTBOX = sys.argv[2]                      # writable again
            m.publish_roster(); m.publish_roster()
            out["publish_back"] = [l for l in logs if "publish: working again" in l]
            out["tabs"] = open(sys.argv[2] + "/tabs.txt").read().split("\\t")[0]
            state["rc"] = 1                             # list-windows fails, session still there
            m.publish_roster(); m.publish_roster()
            out["list_fail"] = [l for l in logs if "list-windows failed" in l]
            state["rc"] = 0
            m.publish_roster()
            out["list_back"] = [l for l in logs if "list: working again" in l]
            print(json.dumps(out))
            """, agentd.path, outbox.path]
        let pipe = Pipe(), err = Pipe()
        py.standardOutput = pipe
        py.standardError = err
        try py.run(); py.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let out = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(errText)")
        #expect((out["publish_fail"] as? [String])?.count == 1)
        #expect((out["publish_back"] as? [String])?.count == 1)
        #expect(out["tabs"] as? String == "0")
        #expect((out["list_fail"] as? [String])?.count == 1)
        #expect((out["list_fail"] as? [String])?.first?.contains("boom") == true)
        #expect((out["list_back"] as? [String])?.count == 1)
    }
}
