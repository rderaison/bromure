import Foundation
import Testing
@testable import bromure_ac

// Kimi Code starts in "Always Ask" unless its command line says otherwise, and
// a resume (`-c`, `-S <id>`) does not keep the mode the session ran in. Live QA
// found Bromure's session launches passing no mode at all: every Bromure MCP
// tool call and every shell command stopped on an approval panel. These pin
// the workspace setting (Never Ask by default) on every launch path — the
// host-built ones (new session, resume, relaunch, model restart, Switchboard)
// and the guest-built ones (board tasks, plans, branch sessions), which the
// tab launcher in .bashrc runs from the meta share's kimi-approvals file.
@Suite("Kimi approvals: every Bromure-managed launch runs in the workspace's mode")
struct KimiApprovalsTests {

    static let sid = "session_abaa0376-d98d-4aae-9e56-cfaca1701024"

    // MARK: Setting

    @Test("The setting defaults to Never Ask and maps to Kimi's flags")
    func flags() {
        #expect(Profile(name: "w", tool: .kimi, authMode: .token).kimiApprovals == .neverAsk)
        #expect(KimiApprovals.neverAsk.launchFlag == "--auto")
        #expect(KimiApprovals.askWhenNeeded.launchFlag == "--yolo")
    }

    @Test("Saved only when changed; old and unknown values load as Never Ask")
    func codable() throws {
        var p = Profile(name: "w", tool: .kimi, authMode: .token)
        let plain = try JSONEncoder().encode(p)
        #expect(!String(decoding: plain, as: UTF8.self).contains("kimiApprovals"))
        #expect(try JSONDecoder().decode(Profile.self, from: plain).kimiApprovals == .neverAsk)

        p.kimiApprovals = .askWhenNeeded
        let changed = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Profile.self, from: changed).kimiApprovals == .askWhenNeeded)

        var obj = try #require(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        obj["kimiApprovals"] = "somethingNewer"
        let future = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(Profile.self, from: future).kimiApprovals == .neverAsk)
    }

    // MARK: Host-built launches

    @Test("A new session, its resumes and its relaunches all carry the mode")
    @MainActor func sessionFlags() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "t", cwd: "~/qa")
        // New session (agent-tab): the role flags ride with the launch.
        #expect(AgentSessionEngine.roleFlags(for: s) == "--auto")
        #expect(AgentSessionEngine.roleFlags(for: s, kimi: .askWhenNeeded) == "--yolo")
        // Resume / relaunch in place / model restart: resume flags + role flags.
        func line(_ s: AgentSession, _ k: KimiApprovals) -> String {
            [s.tool.rawValue, AgentSessionEngine.resumeFlags(for: s), AgentSessionEngine.roleFlags(for: s, kimi: k)]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        #expect(line(s, .neverAsk) == "kimi -c --auto")
        s.agentTranscriptID = Self.sid
        #expect(line(s, .neverAsk) == "kimi -S \(Self.sid) --auto")
        #expect(line(s, .askWhenNeeded) == "kimi -S \(Self.sid) --yolo")
    }

    @Test("Never both modes, never on another agent")
    @MainActor func onlyKimi() {
        for k in KimiApprovals.allCases {
            let f = AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .kimi, title: "t"), kimi: k)
            #expect(!(f.contains("--auto") && f.contains("--yolo")))
            #expect(AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .claude, title: "t"), kimi: k).isEmpty)
            #expect(AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .grok, title: "t"), kimi: k).isEmpty)
            #expect(AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .omp, title: "t"), kimi: k).isEmpty)
            #expect(AgentSessionEngine.roleFlags(for: AgentSession(profileID: UUID(), tool: .codex, title: "t"), kimi: k)
                == "--dangerously-bypass-approvals-and-sandbox")
        }
    }

    @Test("A Kimi Switchboard runs in the mode too")
    @MainActor func switchboard() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "Switchboard")
        s.role = AgentSession.switchboardRole
        #expect(AgentSessionEngine.roleFlags(for: s).split(separator: " ").contains("--auto"))
    }

    @Test("The instructions agent file and the mode go together on a fresh start")
    @MainActor func instructionsAndMode() {
        let f = AgentSessionEngine.instructionFlags(tool: .kimi, text: "x", path: "/p", resuming: false)
        let all = [f, "", AgentSessionEngine.autonomyFlags(for: .kimi)].filter { !$0.isEmpty }.joined(separator: " ")
        #expect(all == "--agent-file /p --auto")
        // The launcher word-splits flags: none has a space inside.
        #expect(!KimiApprovals.allCases.contains { $0.launchFlag.contains(" ") })
    }

    // MARK: Guest-built launches (.bashrc tab launcher)

    @Test("The tab launcher never hard-codes a mode and passes the staged one to every interactive Kimi")
    func launcherText() {
        let rc = ProfileStore.bashrcContent
        #expect(rc.contains("/mnt/bromure-meta/\(SessionDisk.kimiApprovalsMetaFile)"))
        #expect(!rc.contains("$_wt_flags --auto"))
        // Board task / plan (interactive) and branch session (no inline prompt).
        #expect(rc.components(separatedBy: "\"$_wt_tool\" $_wt_flags $_kimi_mode").count - 1 == 2)
        // The one-shot run (automations) stays without: Kimi refuses --prompt with a mode.
        #expect(rc.contains("\"$_wt_tool\" --prompt=\"$_wt_prompt\""))
        #expect(rc.contains("\"$_wt_tool\" -c --prompt=\"$_wt_prompt\""))
    }

    /// Runs the launcher's mode lines in bash against a staged file.
    private func mode(staged: String?, flags: String) throws -> String {
        let rc = ProfileStore.bashrcContent
        let lines = rc.split(separator: "\n").map(String.init)
        guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "_kimi_mode=--auto" })
        else { Issue.record("no _kimi_mode in the launcher"); return "" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("kimi-approvals")
        if let staged { try staged.write(to: file, atomically: true, encoding: .utf8) }
        let snippet = lines[i...(i + 2)].joined(separator: "\n")
            .replacingOccurrences(of: "/mnt/bromure-meta/kimi-approvals", with: file.path)
        let script = "_wt_flags='\(flags)'\n" + snippet + "\nprintf '%s' \"$_kimi_mode\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("Launcher: staged mode wins, Never Ask when nothing is staged, nothing added over the host's own")
    func launcherMode() throws {
        #expect(try mode(staged: nil, flags: "") == "--auto")
        #expect(try mode(staged: "--auto\n", flags: "") == "--auto")
        #expect(try mode(staged: "--yolo\n", flags: "") == "--yolo")
        #expect(try mode(staged: "garbage\n", flags: "") == "--auto")
        // A resume keeps the mode (task-resume "continue": -c in the flags).
        #expect(try mode(staged: "--yolo\n", flags: "-c") == "--yolo")
        // The host already passed one (agent-tab): Kimi refuses two.
        #expect(try mode(staged: "--yolo\n", flags: "-S \(Self.sid) --auto") == "")
        #expect(try mode(staged: nil, flags: "--agent-file /p --yolo") == "")
    }

    // MARK: When Kimi does ask (Ask When Needed)

    @Test("Kimi's question dialog ([n] rows) becomes a card with clean labels")
    func kimiQuestionCard() throws {
        // Kimi Code 2.1 question-dialog layout (src/tui/components/dialogs/question-dialog.ts).
        let screen = """
        ────────────────────────────────────────
         question

          Approach   Submit

         ? Which storage should the cache use?

          → [1] SQLite
                One file, transactional
            [2] Redis
                Needs a server
            [3] Other

          ↑↓ select  1-3 / ↵ choose  esc cancel
        ────────────────────────────────────────
        """
        let p = try #require(TerminalPrompt.detect(inScreen: screen, agent: "kimi"))
        #expect(p.kind == .picker)
        #expect(p.options.map(\.label) == ["SQLite", "Redis", "Other"])
        #expect(p.selectedOption == 1)
        #expect(p.title.contains("Which storage should the cache use?"))
        #expect(p.keys(picking: 2) == ["Down", "Enter"])
        // And nothing is typed into it while it's up.
        #expect(AgentPhrases.menuOpen(screen))
    }
}
