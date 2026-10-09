import Foundation
import Testing
@testable import bromure_ac

/// Host → guest outbox lines: the guest splits fields on whitespace, so an
/// empty value must still hold its slot (a dropped empty parent branch once
/// shifted the display name into @parent_branch and the tool into @display).
@Suite("Guest command encoding")
struct GuestCommandEncodingTests {
    /// The decoded positional fields of `line` (after the verb), the way
    /// agentd's `_fields` + `_b64d` read them.
    private func decoded(_ line: String, _ n: Int) -> (verb: String, fields: [String]) {
        let verb = String(line.prefix { $0 != " " })
        let rest = line.contains(" ") ? String(line.drop { $0 != " " }.dropFirst()) : ""
        return (verb, GuestCommand.fields(rest, n))
    }

    @Test("Empty values encode as a placeholder that decodes back to empty")
    func emptyPlaceholder() {
        #expect(GuestCommand.arg("") == "-")
        #expect(GuestCommand.decode("-") == "")
        #expect(GuestCommand.decode(GuestCommand.arg("main")) == "main")
        #expect(GuestCommand.decode(GuestCommand.arg("Matrix module (v2)")) == "Matrix module (v2)")
    }

    @Test("task-resume with an empty parent branch keeps every later field in place")
    func taskResumeEmptyParent() throws {
        let line = try #require(GuestCommand.line(action: "task-resume", args: [
            "/home/ubuntu/repo", "wt/matrix", "", "Matrix module", "kimi", "", "continue"]))
        let (verb, f) = decoded(line, 7)
        #expect(verb == "task-resume")
        #expect(GuestCommand.decode(f[0]) == "/home/ubuntu/repo")
        #expect(GuestCommand.decode(f[1]) == "wt/matrix")
        #expect(GuestCommand.decode(f[2]) == "")
        #expect(GuestCommand.decode(f[3]) == "Matrix module")
        #expect(GuestCommand.decode(f[4]) == "kimi")
        #expect(f[5] == "-")              // raw prompt slot: the "no prompt" sentinel
        #expect(f[6] == "continue")
    }

    @Test("Every verb keeps its field count when every value is empty")
    func allVerbsEmptyValues() throws {
        let cases: [(action: String, args: [String], minFields: Int)] = [
            ("create", ["", "", "", "", "", "", ""], 6),
            ("run", ["", "", "", "", "", ""], 5),
            ("finish", [""], 1),
            ("task-resume", ["", "", "", "", "", ""], 6),
            ("agent-tab", ["", "", "", ""], 4),
            ("merge", ["", "", "", "", "", "", ""], 7),
            ("pr", ["", "", "", "", ""], 5),
            ("remove", ["", ""], 2),
            ("resolve", ["", ""], 2),
            ("terminal", ["", ""], 2),
            ("unregister", ["", ""], 2),
        ]
        for c in cases {
            let line = try #require(GuestCommand.line(action: c.action, args: c.args))
            let tokens = line.split(separator: " ")
            #expect(tokens.count - 1 >= c.minFields, "\(c.action): \(line)")
            #expect(!line.contains("  "), "\(c.action) has an empty token: \(line)")
            for t in tokens.dropFirst() { #expect(GuestCommand.decode(String(t)) == "") }
        }
    }

    @Test("agent-tab: background with no flags keeps the flags slot")
    func agentTabBackground() throws {
        let line = try #require(GuestCommand.line(action: "agent-tab",
                                                  args: ["/w", "Title", "claude", "", "", "background"]))
        let (_, f) = decoded(line, 6)
        #expect(GuestCommand.decode(f[0]) == "/w")
        #expect(GuestCommand.decode(f[2]) == "claude")
        #expect(f[3] == "-")
        #expect(GuestCommand.decode(f[4]) == "")
        #expect(f[5] == "background")
    }

    @Test("worktree-create: base branch lands in the 7th slot after an empty prompt")
    func createWithBase() throws {
        let line = try #require(GuestCommand.line(action: "create",
                                                  args: ["/w", "slug", "Disp", "codex", "", "", "dev"]))
        let (_, f) = decoded(line, 7)
        #expect(f[4] == "-")
        #expect(f[5] == "-")
        #expect(GuestCommand.decode(f[6]) == "dev")
    }

    @Test("Unknown verbs and short argument lists are refused")
    func refused() {
        #expect(GuestCommand.line(action: "nope", args: ["a"]) == nil)
        #expect(GuestCommand.line(action: "task-resume", args: ["a", "b"]) == nil)
    }

    /// Cross-check against the guest's real decoder: run agentd's `_fields`
    /// and `_b64d` (extracted from the shipped script) over an encoded line.
    @Test("agentd decodes the host's line field-for-field")
    func agentdRoundTrip() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let src = try String(contentsOf: script, encoding: .utf8)
        func extract(_ name: String) throws -> String {
            let start = try #require(src.range(of: "def \(name)("))
            let tail = src[start.lowerBound...]
            let end = tail.range(of: "\n\n\n")?.lowerBound ?? tail.endIndex
            return String(tail[..<end])
        }
        let fns = try extract("_b64d") + "\n\n" + (try extract("_fields"))
        let args = ["/home/ubuntu/my repo", "wt/x", "", "Matrix module", "kimi", ""]
        let line = try #require(GuestCommand.line(action: "task-resume", args: args))
        let rest = String(line.drop { $0 != " " }.dropFirst())
        let py = "import base64, sys, json\n" + fns + "\n"
            + "f = _fields(sys.argv[1], 7)\n"
            + "print(json.dumps([_b64d(x) for x in f[:5]] + [f[5]]))\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", py, rest]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }   // no python3 on this host
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let got = try #require(try JSONSerialization.jsonObject(with: data) as? [String])
        #expect(got == ["/home/ubuntu/my repo", "wt/x", "", "Matrix module", "kimi", "-"])
    }
}
