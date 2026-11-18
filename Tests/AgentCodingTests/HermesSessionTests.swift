import Foundation
import Testing
@testable import bromure_ac

/// Hermes sessions: resumed by their own session id, and their chat read
/// from that session's mirrored transcript. Hermes's `-c` takes the newest
/// session in the whole Hermes home (outside a git repo): a relaunched tab
/// picked up a session begun from `/` in another tab, and the chat view —
/// looking in the folder named after the tab's cwd — showed none of the
/// replies.
@Suite("Hermes sessions")
struct HermesSessionTests {
    private let sid = "local-147a006f46b39fbd692517c969fd37fbc8ff2c0c971f28d8cef9931516972193"

    @Test("Hermes session ids: what its hook names transcripts by, and nothing a shell would read")
    func ids() {
        #expect(AgentSessionLocator.isHermesSessionID(sid))
        #expect(AgentSessionLocator.isHermesSessionID("20261117_140352_ab12cd"))
        for bad in ["", "-c", ".hidden", "a b", "a;rm", "a/b", "x..y", "$(id)", "abc", "local-*",
                    String(repeating: "a", count: 129)] {
            #expect(!AgentSessionLocator.isHermesSessionID(bad), "\(bad)")
        }
    }

    @Test("A Hermes session resumes its own session by id")
    @MainActor func resumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .hermes, title: "t")
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = sid
        #expect(AgentSessionEngine.resumeFlags(for: s) == "--resume \(sid)")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "--resume \(sid)")
        s.agentTranscriptID = "-c; rm -rf ~"
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
    }

    @Test("The probe's transcript name is the Hermes tab's session id; other agents keep UUIDs")
    @MainActor func probe() {
        let lines = AgentSessionEngine.parseProbe("1\thermes\t\(sid)\tHello\n2\tclaude\t\(sid)\tx\n")
        #expect(lines.count == 2)
        #expect(lines[0].transcriptID(for: .hermes) == sid)
        #expect(lines[1].transcriptID(for: .claude) == nil)
        #expect(lines[0].transcriptID(for: .claude) == nil)
    }

    @Test("A pinned Hermes session reads its own transcript, in whichever folder")
    func pinnedRead() {
        let pin = TranscriptPin.conversation(tool: "hermes", id: sid)
        #expect(pin.hermesSession == sid)
        let cmd = AgentSessionLocator.locatePrefix(path: "/home/ubuntu", since: 0, agent: "hermes",
                                                   pinnedWindow: 1, pin: pin)
        #expect(cmd.contains("f=$(ls -t \"$HOME/.hermes/bromure-transcripts\"/*/\(sid).jsonl"))
        #expect(cmd.contains("[ -z \"$f\" ] && pe=1; "), "never the folder's newest instead")
        // Unpinned: as before.
        let loose = AgentSessionLocator.locatePrefix(path: "/home/ubuntu", since: 0, agent: "hermes",
                                                     pinnedWindow: 1)
        #expect(!loose.contains("/*/"))
        #expect(TranscriptPin.conversation(tool: "hermes", id: "../x").hermesSession == nil)
    }

    /// A "Hermes's" in a comment inside agent-status.sh's single-quoted
    /// `python3 -c '…'` closed the quote: bash stopped at a syntax error,
    /// so no agent's turn status or transcript record was ever written.
    @Test("the staged hook scripts and .bashrc parse (bash -n)")
    func scriptsParse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-sh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .token)
        let seed = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seed, terminalDefaults: .fallback)
        let files = seed.appendingPathComponent("files")
        var checked = 0
        for rel in [".bromure/agent-status.sh", ".bashrc"] {
            let url = files.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-n", url.path]
            let err = Pipe()
            proc.standardError = err
            try proc.run(); proc.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 0, "\(rel): \(msg)")
            checked += 1
        }
        #expect(checked == 2)
    }

    /// A resumed Hermes session runs on the model it was stored with:
    /// one begun on a local model, resumed after the workspace moved to
    /// Nous Portal, asked for the hidden local key ("No API key for the
    /// custom endpoint"). Bromure's bare resume opens with Hermes's
    /// session-only `/model` for the workspace's model.
    @Test("a bare resume opens on the workspace's model; anything else is left alone")
    func resumeModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .token)
        let seed = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seed, terminalDefaults: .fallback)
        let rc = try String(contentsOf: seed.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasSuffix("_bromure_hermes_resume_model() {") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        let settings = root.appendingPathComponent("hermes-settings.json")
        let fn = lines[start...end].joined(separator: "\n")
            .replacingOccurrences(of: "/mnt/bromure-meta/hermes-settings.json", with: settings.path)
        func run(_ args: String, model: [String: String]) throws -> String? {
            try JSONSerialization.data(withJSONObject: ["model": model]).write(to: settings)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", fn + "\n_bromure_hermes_resume_model " + args]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            try proc.run(); proc.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return proc.terminationStatus == 0 ? text : nil
        }
        let nous = ["provider": "nous", "default": "openai/gpt-5.5"]
        let want = "/model openai/gpt-5.5 --provider nous --session"
        #expect(try run("--resume local-abc123", model: nous) == want)
        #expect(try run("--yolo -r local-abc123", model: nous) == want)
        #expect(try run("-c", model: nous) == want)
        #expect(try run("--resume=local-abc123 --yolo", model: nous) == want)
        // Not a bare resume, or nothing to switch to: untouched.
        #expect(try run("", model: nous) == nil)
        #expect(try run("--resume", model: nous) == nil)
        #expect(try run("--resume x chat --query=hi", model: nous) == nil)
        #expect(try run("-c -m other", model: nous) == nil)
        #expect(try run("sessions list", model: nous) == nil)
        #expect(try run("-c", model: ["provider": "auto", "default": "x"]) == nil)
        #expect(try run("-c", model: ["provider": "nous"]) == nil)
        #expect(try run("-c", model: ["provider": "nous", "default": "a b; rm -rf ~"]) == nil)
    }

    /// The argv the wrapper hands Hermes on a bare resume: `chat` first.
    /// -c / --continue take an optional session name, so `-c chat --query=…`
    /// had argparse read `chat` as that name and exit on the stray --query.
    @Test("a bare resume puts chat before the resume flags", arguments: [
        "-c", "--continue", "--yolo -c", "--resume local-abc123", "-r local-abc123 --yolo",
    ])
    func resumeArgv(_ args: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-argv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .token)
        let seed = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seed, terminalDefaults: .fallback)
        let rc = try String(contentsOf: seed.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        let lines = rc.components(separatedBy: "\n")
        func fn(_ name: String) throws -> String {
            let start = try #require(lines.firstIndex { $0 == name + "() {" })
            let end = try #require(lines[start...].firstIndex { $0 == "}" })
            return lines[start...end].joined(separator: "\n")
        }
        let settings = root.appendingPathComponent("hermes-settings.json")
        try JSONSerialization.data(withJSONObject: ["model": ["provider": "nous", "default": "openai/gpt-5.5"]])
            .write(to: settings)
        // A stand-in hermes that prints its argv, one word a line.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("hermes")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let script = [
            "_bromure_hermes_opt_ready() { :; }", "_bromure_hermes_apply() { :; }",
            try fn("_bromure_hermes_resume_model"), try fn("hermes"),
            "hermes " + args,
        ].joined(separator: "\n").replacingOccurrences(of: "/mnt/bromure-meta/", with: root.path + "/")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        let argv = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(proc.terminationStatus == 0)
        #expect(argv == ["chat", "--query=/model openai/gpt-5.5 --provider nous --session"]
                + args.split(separator: " ").map(String.init))
    }
}
