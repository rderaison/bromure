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

    /// The .bashrc's functions `names`, lifted out as they are written.
    private static func bashrcFunctions(_ names: [String]) throws -> (String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-type-\(UUID().uuidString)")
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .token)
        let seed = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seed, terminalDefaults: .fallback)
        let rc = try String(contentsOf: seed.appendingPathComponent("files/.bashrc"), encoding: .utf8)
        let lines = rc.components(separatedBy: "\n")
        let body = try names.map { name -> String in
            let start = try #require(lines.firstIndex { $0 == name + "() {" })
            let end = try #require(lines[start...].firstIndex { $0 == "}" })
            return lines[start...end].joined(separator: "\n")
        }.joined(separator: "\n")
        return (body, root)
    }

    /// A stand-in tmux pane: `capture-pane` draws Hermes's composer once
    /// `$SIM/up` exists (its placeholder in italics while `$SIM/text` is
    /// empty), `send-keys -l` types into it, Enter sends it to `$SIM/sent`;
    /// `ps` shows a Hermes on the pane's terminal once it is up. The pane is
    /// `$SIM/width` columns wide (200 without it); like Hermes, the composer
    /// cuts longer input at that width and carries on at the next row's
    /// first column, and like tmux, the capture drops the blanks ending a row.
    private static func simulatedPane(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tmux = """
        #!/bin/sh
        case "$1" in
          display-message)
            case "$5" in
              *pane_width*) cat "$SIM/width" 2>/dev/null || echo 200 ;;
              *) echo /dev/pts/9 ;;
            esac ;;
          capture-pane)
            if [ -e "$SIM/up" ]; then
              echo '↻ Resumed session local-abc'
              t=$(cat "$SIM/text" 2>/dev/null)
              w=$(cat "$SIM/width" 2>/dev/null || echo 200)
              if [ -n "$t" ]; then
                printf '\\033[38;5;230m❯ \\033[0m%s\\n' "$(printf '%s' "$t" | cut -c1-$((w - 2)) | sed 's/ *$//')"
                rest=$(printf '%s' "$t" | cut -c$((w - 1))-)
                if [ -n "$rest" ]; then printf '%s\\n' "$rest" | fold -w "$w" | sed 's/ *$//'; fi
              else printf '\\033[38;5;230m❯ \\033[3m\\033[38;5;136mFind and fix a failing test\\033[0m\\n'; fi
              printf '\\033[38;5;250m ☤ \\033[1mgpt-5.5\\033[0m\\n'
            else
              echo 'ubuntu@vm:~$ hermes -c'
            fi ;;
          send-keys)
            shift 3
            if [ "$1" = -l ]; then printf '%s' "$3" >> "$SIM/text"; else mv "$SIM/text" "$SIM/sent"; fi ;;
        esac
        """
        // `ps -o pgid=,tpgid=,args=`: the shell, its background jobs (this
        // probe among them, its command line naming hermes), and Hermes in
        // the foreground once up -- unless `$SIM/gone` says it has exited.
        let ps = """
        #!/bin/sh
        if [ -e "$SIM/up" ] && [ ! -e "$SIM/gone" ]; then fg=100; else fg=90; fi
        echo "   90 $fg -bash"
        echo "  130 $fg grep -q hermes"
        [ "$fg" = 100 ] && echo "  100 100 python3 -I -c import hermes_bootstrap /opt/hermes/hermes-agent"
        exit 0
        """
        for (name, text) in [("tmux", tmux), ("ps", ps)] {
            let url = bin.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return bin
    }

    private static func bash(_ script: String, path: URL, sim: URL) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.environment = ["PATH": path.path + ":/usr/bin:/bin", "SIM": sim.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return (proc.terminationStatus, String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    @Test("the composer reader drops Hermes's italic placeholder and keeps typed text")
    func composer() throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_composer"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = root.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        let bin = try Self.simulatedPane(in: root)
        let read = fns + "\n_bromure_hermes_composer %1"
        #expect(try Self.bash(read, path: bin, sim: sim).0 == 2, "no composer on screen")
        FileManager.default.createFile(atPath: sim.appendingPathComponent("up").path, contents: nil)
        #expect(try Self.bash(read, path: bin, sim: sim) == (0, "\n"), "the placeholder is not content")
        try "fix the build".write(to: sim.appendingPathComponent("text"), atomically: true, encoding: .utf8)
        #expect(try Self.bash(read, path: bin, sim: sim) == (0, "fix the build\n"))
    }

    /// The resume's `/model` goes into Hermes's composer as typed input, once
    /// Hermes is up: never as `chat --query`, which Hermes sends literally,
    /// as a turn on the session's old model.
    @Test("a bare resume's /model is typed into an empty composer, never over the user's text", arguments: [false, true])
    func typesModel(userTyped: Bool) throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_composer", "_bromure_hermes_foreground", "_bromure_hermes_type_model"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = root.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        let bin = try Self.simulatedPane(in: root)
        let model = "/model openai/gpt-5.5 --provider nous --session"
        let script = fns + """

        _bromure_hermes_type_model %1 '\(model)' &
        sleep 0.3
        \(userTyped ? "printf 'hello' > \"$SIM/text\"" : ":")
        touch "$SIM/up"
        wait
        """
        #expect(try Self.bash(script, path: bin, sim: sim).0 == 0)
        let sent = try? String(contentsOf: sim.appendingPathComponent("sent"), encoding: .utf8)
        let left = try? String(contentsOf: sim.appendingPathComponent("text"), encoding: .utf8)
        if userTyped {
            #expect(sent == nil)
            #expect(left == "hello")
        } else {
            #expect(sent == model)
            #expect(left == nil)
        }
    }

    /// Hermes gone (the resume failed) but its last composer still on
    /// screen: the shell has the terminal again, and nothing is typed into
    /// it -- not even though a `grep hermes` of this very probe is on the
    /// terminal too.
    @Test("nothing is typed when Hermes isn't the terminal's foreground program")
    func noHermesNoTyping() throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_composer", "_bromure_hermes_foreground", "_bromure_hermes_type_model"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = root.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        let bin = try Self.simulatedPane(in: root)
        FileManager.default.createFile(atPath: sim.appendingPathComponent("gone").path, contents: nil)
        let script = fns + """

        _bromure_hermes_type_model %1 '/model openai/gpt-5.5 --provider nous --session' &
        sleep 0.3
        touch "$SIM/up"
        sleep 2.5
        kill $! 2>/dev/null
        wait
        """
        _ = try Self.bash(script, path: bin, sim: sim)
        #expect(!FileManager.default.fileExists(atPath: sim.appendingPathComponent("text").path))
        #expect(!FileManager.default.fileExists(atPath: sim.appendingPathComponent("sent").path))
    }

    @Test("Hermes counts only as the terminal's foreground program", arguments: [
        ("   90  100 -bash\n  100  100 python3 -I -c import hermes_bootstrap", true),
        ("   90   90 -bash\n  130   90 grep -q hermes", false),
        ("   90   90 /bin/bash -c hermes --resume x", false),
        ("   90   90 bash -i\n  140   90 awk /herm[e]s/", false),
        ("", false),
    ])
    func foreground(ps: String, running: Bool) throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_foreground"])
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent("ps")
        try "#!/bin/sh\nprintf '%s\\n' \"$PS_OUT\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", fns + "\n_bromure_hermes_foreground pts/9"]
        proc.environment = ["PATH": bin.path + ":/usr/bin:/bin", "PS_OUT": ps.replacingOccurrences(of: "\\n", with: "\n")]
        try proc.run(); proc.waitUntilExit()
        #expect((proc.terminationStatus == 0) == running)
    }

    /// A pane narrower than the `/model` line: Hermes wraps it onto a second
    /// row, and the check before Enter reads it across both.
    @Test("a /model longer than the pane is sent once typed, read across the rows it wraps onto")
    func typesWrappedModel() throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_composer", "_bromure_hermes_foreground", "_bromure_hermes_type_model"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = root.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        let bin = try Self.simulatedPane(in: root)
        try "40".write(to: sim.appendingPathComponent("width"), atomically: true, encoding: .utf8)
        let model = "/model anthropic/claude-opus-5-5 --provider nous --session"
        let script = fns + """

        _bromure_hermes_type_model %1 '\(model)' &
        sleep 0.3
        touch "$SIM/up"
        wait
        """
        #expect(try Self.bash(script, path: bin, sim: sim).0 == 0)
        #expect((try? String(contentsOf: sim.appendingPathComponent("sent"), encoding: .utf8)) == model)
    }

    /// The exact check, at the edges of Hermes's wrapping: a row the text
    /// fills exactly (the status row follows), a cut on a space (tmux drops
    /// it), and text that only starts like the expected one, or runs on.
    @Test("the composer holds exactly the expected text, however it wraps", arguments: [
        ("/model 0123456789012345678901234567890", "/model 0123456789012345678901234567890", true),
        ("/model 012345678901234567890123456789 x", "/model 012345678901234567890123456789 x", true),
        ("/model anthropic/claude-opus-5-5 --provider nous --session", "/model anthropic/claude-opus-5-5 --provider nous --session", true),
        ("/model anthropic/claude-opus-5-5 --provider nous --session", "/model anthropic/claude-opus-5-5 --provider nous", false),
        ("/model anthropic/claude-opus-5-5 --provider nous --session extra", "/model anthropic/claude-opus-5-5 --provider nous --session", false),
        ("/model anthropic/claude-opus-5-5", "/model other", false),
    ])
    func composerHolds(typed: String, want: String, holds: Bool) throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_composer"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = root.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        let bin = try Self.simulatedPane(in: root)
        try "40".write(to: sim.appendingPathComponent("width"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: sim.appendingPathComponent("up").path, contents: nil)
        try typed.write(to: sim.appendingPathComponent("text"), atomically: true, encoding: .utf8)
        let check = fns + "\n_bromure_hermes_composer %1 '\(want)'"
        #expect(try Self.bash(check, path: bin, sim: sim).0 == (holds ? 0 : 1))
        // Without an expected text it still prints the first row's content.
        let read = try Self.bash(fns + "\n_bromure_hermes_composer %1", path: bin, sim: sim)
        #expect(read.0 == 0 && typed.hasPrefix(read.1.trimmingCharacters(in: .newlines)))
    }

    @Test("the wrapper no longer seeds the resume's /model as a chat query")
    func noModelQuery() throws {
        let (fns, root) = try Self.bashrcFunctions(["hermes"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!fns.contains("chat --query=\"$_rm\""))
        #expect(fns.contains("_bromure_hermes_type_model \"$TMUX_PANE\" \"$_rm\""))
    }

    /// The argv the wrapper hands Hermes on a bare resume: the resume flags
    /// alone, nothing after them. -c / --continue take an optional session
    /// name, so a `chat …` behind `-c` was read as that name and Hermes
    /// exited on the rest; the resume's /model is typed in instead.
    @Test("a bare resume reaches Hermes with its own flags only", arguments: [
        "-c", "--continue", "--yolo -c", "--resume local-abc123", "-r local-abc123 --yolo",
    ])
    func resumeArgv(_ args: String) throws {
        let (fns, root) = try Self.bashrcFunctions(["_bromure_hermes_resume_model", "hermes"])
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("hermes-settings.json")
        try JSONSerialization.data(withJSONObject: ["model": ["provider": "nous", "default": "openai/gpt-5.5"]])
            .write(to: settings)
        // A stand-in hermes that prints its argv, one word a line.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("hermes")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let script = ["_bromure_hermes_opt_ready() { :; }", "_bromure_hermes_apply() { :; }", fns, "hermes " + args]
            .joined(separator: "\n").replacingOccurrences(of: "/mnt/bromure-meta/", with: root.path + "/")
        let (status, out) = try Self.bash(script, path: bin, sim: root)
        #expect(status == 0)
        #expect(out.split(separator: "\n").map(String.init) == args.split(separator: " ").map(String.init))
    }
}
