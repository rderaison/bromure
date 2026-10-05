import Foundation
import Testing
@testable import bromure_ac

/// Grok Build sessions: resumed by their own conversation, titled by what
/// they're about (never their status), metered in the header, carded
/// without terminal clutter, and their tools shown as the cards they are.
@Suite("Grok sessions")
struct GrokSessionTests {
    /// A uuidv7 minted 2026-10-05 (0x0199b4a5c000 ms).
    private let id = "0199b4a5-c000-7abc-8def-0123456789ab"

    // MARK: GK-2 resume

    @Test("A Grok session resumes its own conversation by id, else the folder's latest")
    @MainActor func resumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .grok, title: "t")
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
        // Another session in the folder: never its conversation.
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = id
        #expect(AgentSessionEngine.resumeFlags(for: s) == "--resume \(id)")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "--resume \(id)")
        s.agentTranscriptID = "session_x"
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
    }

    @Test("The conversation id comes from the session folder, its uuidv7 time, or the exit line")
    @MainActor func learnsID() {
        let path = "/home/ubuntu/.grok/sessions/%2Fmnt%2Fbromure-share-1/\(id)/updates.jsonl"
        #expect(AgentSessionEngine.grokConversationID(inPath: path) == id)
        #expect(AgentSessionEngine.grokConversationID(inPath: "/home/ubuntu/.grok/sessions/x/\(id)") == id)
        #expect(AgentSessionEngine.grokConversationID(inPath: "/tmp/\(id)/updates.jsonl") == nil)
        #expect(AgentSessionEngine.grokConversationID(inPath: "/home/ubuntu/.grok/sessions/x/nope/updates.jsonl") == nil)
        let minted = AgentSessionEngine.uuidV7Date(id)
        #expect(minted.map { abs($0.timeIntervalSince1970 - Double(0x0199b4a5c000) / 1000) < 0.01 } == true)
        // Not a v7: no time to read.
        #expect(AgentSessionEngine.uuidV7Date("01a10cc6-661b-42c2-9263-8d83b3a2b2ca") == nil)
        let exit = "Goodbye!\nResume this session with: grok --resume \(id)\n$ "
        #expect(AgentSessionEngine.grokResumeID(inScreen: exit) == id)
        #expect(AgentSessionEngine.grokResumeID(inScreen: "grok -r \(id)\n") == id)
        #expect(AgentSessionEngine.grokResumeID(inScreen: "grok --resume <id>") == nil)
        // The probe's pinned path: `<uuid>/updates.jsonl` names the folder.
        #expect(AgentSessionEngine.probeCommand(window: "3").contains("[ \"$tid\" = updates ]"))
        #expect(AgentSessionEngine.parseProbe("3\tgrok\t\(id)\tTitle").first?.transcriptID == id)
    }

    @Test("Two Grok sessions on a machine never claim each other's conversation")
    @MainActor func claims() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-claims-\(UUID().uuidString).json"))
        let ws = UUID()
        var a = AgentSession(profileID: ws, tool: .grok, title: "a")
        a.agentTranscriptID = id
        var b = AgentSession(profileID: ws, tool: .grok, title: "b")
        b.agentTranscriptID = nil
        var c = AgentSession(profileID: ws, tool: .codex, title: "c")
        c.agentTranscriptID = "01a10cc6-661b-72c2-9263-8d83b3a2b2ca"
        store.upsert(a); store.upsert(b); store.upsert(c)
        #expect(store.grokConversationsClaimed(profileID: ws, besides: b.id) == [id])
        #expect(store.grokConversationsClaimed(profileID: ws, besides: a.id).isEmpty)
        // Codex's claims stay Codex's.
        #expect(store.codexConversationsClaimed(profileID: ws, besides: nil) == [c.agentTranscriptID!])
    }

    // MARK: GK-4 title

    @Test("Grok's status in its terminal title is never the session's name")
    func statusTitles() {
        func t(_ raw: String) -> String? { SessionHome.cleanAgentTitle(raw, agent: "grok", cwd: "~/gk-demo") }
        #expect(t("Waiting for response…") == nil)
        #expect(t("Action Required - :. - Running: Fetch: https://neverssl.com/...") == nil)
        #expect(t("⠼ Thinking...") == nil)
        #expect(t("Add a mul function - Thinking…") == "Add a mul function")
        #expect(t("Add a mul function - grok") == "Add a mul function")
        // A real title that merely starts with a status-like word stays.
        #expect(t("Reading list app") == "Reading list app")
        #expect(t("Waiting room redesign") == "Waiting room redesign")
        #expect(t("Fix login – add tests") == "Fix login – add tests")
    }

    @Test("GK-4: status parts, a cut ' - grok' suffix and a cut title never become the name")
    func statusAndCutTitles() {
        func t(_ raw: String) -> String? { SessionHome.cleanAgentTitle(raw, agent: "grok", cwd: "~/gk-demo") }
        let full = "Remember and recall the code word MANGO"
        // The live terminal title.
        #expect(t("⠧ - Thinking - Remember and recall the code word MANGO - grok") == full)
        // The guest roster's 60-character cut of it.
        #expect(t("⠧ - Thinking - Remember and recall the code word MANGO - gro") == full)
        #expect(t("Remember and recall the code word MANGO - gro") == full)
        #expect(t("Remember and recall the code word MANGO - gr") == full)
        #expect(t("Remember and recall the code word MANGO -") == full)
        #expect(t("Writing edit (5)… - Remember and recall the code word MA") == "Remember and recall the code word MA")
        #expect(t("Running… - Remember and recall the code word MANGO - grok") == full)
        #expect(t("Running command… - Remember and recall the code word MANGO") == full)
        #expect(t("Reading 3 files… - Add a mul function - grok") == "Add a mul function")
        // Status alone is never a title; a title alone that starts with a
        // gerund stays.
        #expect(t("Writing edit (5)…") == nil)
        #expect(t("Writing a parser in Rust") == "Writing a parser in Rust")
        #expect(t("Plan A - gro") == "Plan A")
        // A cut that is a prefix of the session's fuller name keeps the name.
        var s = AgentSession(profileID: UUID(), tool: .grok, title: full, cwd: "/home/ubuntu/gk-demo")
        #expect(AgentSession.title(fromAgent: "Writing edit (5)… - Remember and recall the code word MA", of: s) == full)
        #expect(AgentSession.title(fromAgent: "Remember and recall the code wor", of: s) == full)
        #expect(AgentSession.title(fromAgent: "⠧ - Thinking - Remember and recall the code word MANGO - gro", of: s) == full)
        // A different name does replace it.
        #expect(AgentSession.title(fromAgent: "Add a mul function - grok", of: s) == "Add a mul function")
        // With no fuller name yet, the cut is taken (a later full title replaces it).
        s.title = "Grok Build in gk-demo"
        #expect(AgentSession.title(fromAgent: "Remember and recall the code wor", of: s) == "Remember and recall the code wor")
    }

    // MARK: GK-5 header

    @Test("Grok's model and context come from its turn_completed usage")
    func usage() {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "end_turn", "usage": {"inputTokens": 103833, "outputTokens": 541, "totalTokens": 104374, "cachedReadTokens": 84224, "cacheCreationTokens": 0, "reasoningTokens": 193, "modelCalls": 5, "modelUsage": {"grok-4.7-build": {"inputTokens": 103833, "outputTokens": 541, "cachedReadTokens": 84224, "modelCalls": 5}}}}}}"#
        let data = Data((line + "\n").utf8)
        #expect(TranscriptSearchIndex.model(in: data) == "grok-4.7-build")
        #expect(TranscriptSearchIndex.prettyModel("grok-4.7-build") == "Grok 4.7 Build")
        let t = TranscriptSearchIndex.tokens(in: data)
        // The turn's sum over its 5 model calls, per call.
        #expect(t.input == (103833 - 84224) / 5)
        #expect(t.cached == 84224 / 5)
        #expect(t.output == 541 / 5)
    }

    // MARK: GK-6 approval cards

    private let approvalScreen = [
        "  I'll fetch it now.",
        "",
        "◆ Fetch https://neverssl.com/ 25s                              28s ↓22.5k",
        "[stop]",
        "Help improve Grok                                              [Opt out]",
        "[Opt in]",
        "Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,",
        "prompts, traces, & metrics, for training and debugging purposes.",
        "Change anytime via settings.",
        "Read Terms and Privacy Policy.",
        "Allow Fetch: https://neverssl.com/?",
        "❯ 1. Yes, and don't ask again for anything (always-approve mode)",
        "  2. Yes, always allow neverssl.com for this project",
        "  3. Yes, allow once",
        "  4. No, reject (type to add feedback)",
    ]

    @Test("An approval card leaves out the spinner line and the data-retention banner")
    func cleanBody() {
        let menu = AgentScreen.liveMenu(approvalScreen, after: -1)
        #expect(menu?.options.count == 4)
        let first = menu?.firstOffset ?? 11
        let title = AgentScreen.title(approvalScreen, before: first)
        #expect(title == "Allow Fetch: https://neverssl.com/?")
        let body = AgentScreen.context(approvalScreen, before: first, title: title)
        #expect(!body.contains("[stop]"))
        #expect(!body.contains("↓22.5k"))
        #expect(!body.contains("Help improve Grok"))
        #expect(!body.contains("SpaceXAI"))
        #expect(AgentScreen.isStatusChrome("◆ Run Write `/home/ubuntu/pii.txt` 57s     1m5s ↓33.1k"))
        #expect(!AgentScreen.isStatusChrome("   sleep 30s"))
        #expect(!AgentScreen.isStatusChrome("Allow Fetch: https://neverssl.com/?"))
    }

    @Test("The data-retention banner is a card of its own, with or without a dialog")
    func privacyCard() {
        let p = TerminalPrompt.detect(tail: approvalScreen, agent: "grok")
        #expect(p?.kind == .picker)
        #expect(p?.privacyNotice?.hasPrefix("Off by default.") == true)
        #expect(p?.privacyNotice?.contains("[Opt") == false)
        #expect(p?.detail.contains("SpaceXAI") == false)
        // The banner alone: a notice, which holds no message back.
        let alone = Array(approvalScreen[0..<10])
        let n = TerminalPrompt.detect(tail: alone, agent: "grok")
        #expect(n?.kind == .notice)
        #expect(n?.detail.contains("Privacy Policy") == true)
        #expect(n?.options.isEmpty == true)
        // Nothing of the sort: no card.
        #expect(TerminalPrompt.detect(tail: ["$ ls", "calc.py"], agent: "grok") == nil)
    }

    @Test("An edit waiting for approval (or refused) is no change yet")
    func unsettledEdit() {
        func item(_ id: Int, _ k: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: id, kind: k, timestamp: nil) }
        let edit = #"{"file_path":"/a/x.py","old_string":"a","new_string":"a\nb\nc\nd\ne"}"#
        let pending = [item(1, .userText("go")), item(2, .toolUse(name: "Edit", summary: "", detail: edit))]
        #expect(TurnChanges.of(pending) == nil)
        let refused = pending + [item(3, .toolResult(tool: "Edit", content: "rejected", isError: true)),
                                 item(4, .assistantText("ok, not changing it"))]
        #expect(TurnChanges.of(refused) == nil)
        let done = pending + [item(3, .toolResult(tool: "Edit", content: "diff: /a/x.py", isError: false))]
        // "a" is kept: four lines added, as the review's diff counts them.
        #expect(TurnChanges.of(done)?.added == 4)
    }

    // MARK: GK-7 tool cards

    @Test("Grok's built-in tools read as the cards other agents get")
    func toolNames() {
        let lines = [
            #"{"method":"session/update","params":{"update":{"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "run_terminal_command", "rawInput": {"command": "python3 -c 1", "description": "Verify"}, "_meta": {"x.ai/tool": {"name": "run_terminal_command", "kind": "execute", "namespace": "grok_build"}}}}}"#,
            #"{"method":"session/update","params":{"update":{"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed", "rawOutput": "12"}}}"#,
            #"{"method":"session/update","params":{"update":{"sessionUpdate": "tool_call", "toolCallId": "c2", "title": "search_replace", "rawInput": {"file_path": "/mnt/bromure-share-1/calc.py", "old_string": "a", "new_string": "b"}}}}"#,
            #"{"method":"session/update","params":{"update":{"sessionUpdate": "tool_call", "toolCallId": "c3", "title": "read_file", "rawInput": {"target_file": "/mnt/bromure-share-1/README.md"}}}}"#,
            #"{"method":"session/update","params":{"update":{"sessionUpdate": "tool_call", "toolCallId": "c4", "title": "mcp__display__show", "rawInput": {}}}}"#,
        ]
        let items = GrokTranscriptParser.parse(Data(lines.joined(separator: "\n").utf8))
        let uses = items.compactMap { i -> (String, String, String)? in
            if case .toolUse(let n, let s, let d) = i.kind { return (n, s, d) } else { return nil }
        }
        #expect(uses.map(\.0) == ["Bash", "Edit", "Read", "mcp__display__show"])
        #expect(uses[0].1 == "python3 -c 1")
        #expect(uses[2].1 == "/mnt/bromure-share-1/README.md")
        #expect(uses[2].2.contains("\"file_path\""))
        // The result answers the call under its card name.
        #expect(items.contains { if case .toolResult(tool: "Bash", content: "12", isError: false) = $0.kind { true } else { false } })
        #expect(ActivitySummary.category("Edit") == .edit)
    }

    @Test("A shared folder's mount reads as the folder the user knows")
    func sharePaths() {
        let names = GuestSharePaths.names(mountNames: ["gk-demo", "other"])
        #expect(names["/mnt/bromure-share-1"] == "~/gk-demo")
        #expect(GuestSharePaths.display("/mnt/bromure-share-1/calc.py", names: names) == "~/gk-demo/calc.py")
        #expect(GuestSharePaths.display("cd /mnt/bromure-share-2 && ls", names: names) == "cd ~/other && ls")
        // A whole component only: share 10 isn't share 1.
        #expect(GuestSharePaths.display("/mnt/bromure-share-10/x", names: names) == "/mnt/bromure-share-10/x")
        let items = [
            TranscriptItem(id: 0, kind: .userText("look at /mnt/bromure-share-1"), timestamp: nil),
            TranscriptItem(id: 1, kind: .toolUse(name: "Read", summary: "/mnt/bromure-share-1/a",
                                                 detail: #"{"file_path":"/mnt/bromure-share-1/a"}"#), timestamp: nil),
            TranscriptItem(id: 2, kind: .assistantText("Removed /mnt/bromure-share-1/__pycache__."), timestamp: nil),
        ]
        let out = GuestSharePaths.rewrite(items, names: names)
        #expect(out[0].kind == items[0].kind)   // what the user typed stays
        #expect(out[1].kind == .toolUse(name: "Read", summary: "~/gk-demo/a", detail: #"{"file_path":"~/gk-demo/a"}"#))
        #expect(out[2].kind == .assistantText("Removed ~/gk-demo/__pycache__."))
    }

    @Test("A cancelled prompt and the next one are two user messages, never one joined bubble")
    func cancelledPromptNotJoined() {
        // Real records (QA, grok 1.0.46): the cancelled turn ends, then the
        // resent prompt, a hook, and the next prompt — same promptIndex.
        let jsonl = """
        {"timestamp":1791224881,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Write an essay (do not create files)."},"_meta":{"promptIndex":2}}}}
        {"timestamp":1791224882,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"turn_completed","prompt_id":"p2","stop_reason":"cancelled"}}}
        {"timestamp":1791224916,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Write an essay, directly in the chat."},"_meta":{"promptIndex":3}}}}
        {"timestamp":1791224916,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"hook_execution"}}}
        {"timestamp":1791225520,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Create a file notes.md"},"_meta":{"promptIndex":3}}}}
        {"timestamp":1791225521,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}}}
        """
        let users = AgentTranscript.parse(Data(jsonl.utf8), agent: "grok").compactMap { item -> String? in
            if case .userText(let t) = item.kind { return t } else { return nil }
        }
        #expect(users == ["Write an essay (do not create files).", "Write an essay, directly in the chat.",
                          "Create a file notes.md"])
        // One message split over consecutive chunk records stays one.
        let split = """
        {"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"add a retry "}}}}
        {"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"to the uploader"}}}}
        """
        let one = AgentTranscript.parse(Data(split.utf8), agent: "grok").compactMap { item -> String? in
            if case .userText(let t) = item.kind { return t } else { return nil }
        }
        #expect(one == ["add a retry to the uploader"])
    }

    @Test("GK-7: a step card's header (read from the call's JSON) shows the folder, not the mount")
    func sharePathsInCardHeaders() throws {
        let names = GuestSharePaths.names(mountNames: ["gk-demo"])
        // Grok's own transcript lines, through the real parser: the detail
        // JSON Foundation writes escapes its slashes.
        let jsonl = """
        {"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"list_dir","rawInput":{"target_directory":"/mnt/bromure-share-1"}}}}
        {"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"t2","title":"write_file","rawInput":{"target_file":"/mnt/bromure-share-1/notes.md","content":"hello"}}}}
        """
        let out = GuestSharePaths.rewrite(AgentTranscript.parse(Data(jsonl.utf8), agent: "grok"), names: names)
        let uses = out.compactMap { item -> (String, String, String)? in
            if case .toolUse(let n, let s, let d) = item.kind { return (n, s, d) } else { return nil }
        }
        #expect(uses.count == 2)
        for (_, summary, detail) in uses {
            #expect(!summary.contains("bromure-share"))
            #expect(!detail.contains("bromure-share"), "\(detail)")
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
            let path = (obj["file_path"] ?? obj["path"]) as? String
            #expect(path?.hasPrefix("~/gk-demo") == true)
        }
        #expect(GuestSharePaths.display(#"{"path":"\/mnt\/bromure-share-10"}"#, names: names)
                == #"{"path":"\/mnt\/bromure-share-10"}"#)
    }
}

/// The guest agent's side: Grok's MCP servers and task worktrees.
@Suite("Grok guest setup (agentd)")
struct GrokAgentdTests {
    private static let python = "/usr/bin/python3"
    private static var vmSetup: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
    }

    private func run(_ script: String, dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = Self.vmSetup
        p.arguments = ["-c", "\(Self.python) - '\(dir.path)' <<'PY'\n"
            + "import importlib.util, sys, os, json, subprocess\n"
            + "s = importlib.util.spec_from_file_location('agentd', 'bromure-agentd.py')\n"
            + "m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
            + "d = os.path.realpath(sys.argv[1])\n" + script + "\nPY"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grok-agentd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Board/delegation servers land in .grok/config.toml, idempotently, sparing the user's own",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func grokConfigToml() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run("""
            os.makedirs(d + '/.grok')
            open(d + '/.grok/config.toml', 'w').write('[cli]\\ntheme = "dark"\\n\\n[mcp_servers.display]\\ncommand = "mine"\\n')
            open(d + '/.grok/settings.json', 'w').write(json.dumps({"mcpServers": {"bromure-board": {"command": "python3", "args": [d + "/bromure-task-mcp.py", "wt/old"]}}, "theme": "x"}))
            shim = d + '/bromure-task-mcp.py'; open(shim, 'w').write('')
            dshim = d + '/bromure-display-mcp.py'; open(dshim, 'w').write('')
            m._project_mcp_add('grok', d, 'bromure-board', shim, ['wt/x'])
            first = open(d + '/.grok/config.toml').read()
            m._project_mcp_add('grok', d, 'bromure-board', shim, ['wt/x'])
            print('IDEMPOTENT', first == open(d + '/.grok/config.toml').read())
            m._project_mcp_add('grok', d, 'display', dshim)
            t = open(d + '/.grok/config.toml').read()
            print('BOARD', '[mcp_servers.bromure-board]' in t and '"wt/x"' in t)
            print('USER_KEPT', t.count('[mcp_servers.display]') == 1 and 'command = "mine"' in t and 'theme = "dark"' in t)
            print('LEGACY_GONE', 'bromure-board' not in open(d + '/.grok/settings.json').read())
            m._project_mcp_remove('grok', d, 'bromure-board', shim)
            print('REMOVED', 'bromure-board' not in open(d + '/.grok/config.toml').read())
            """, dir: dir)
        for key in ["IDEMPOTENT", "BOARD", "USER_KEPT", "LEGACY_GONE", "REMOVED"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    @Test("Grok's folder trust is pre-seeded in ~/.grok/trusted_folders.toml: canonical paths, idempotent, never clobbering",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func grokPretrust() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run("""
            home = d + '/home'; os.makedirs(home + '/.grok'); m.HOME = home
            share = d + '/mnt-share-1'; os.makedirs(share + '/sub')
            os.symlink(share, home + '/gk-demo')
            repo = d + '/repo'; os.makedirs(repo + '/pkg')
            subprocess.run(['git', 'init', '-q', repo], check=True)
            tf = home + '/.grok/trusted_folders.toml'
            # The user said no to one folder: that answer stands.
            open(tf, 'w').write('[folders."%s"]\\ntrusted = false\\ndecided_at = 1\\n' % (d + '/repo'))
            m._pretrust('grok', home + '/gk-demo', repo + '/pkg', home)
            first = open(tf).read()
            m._pretrust('grok', home + '/gk-demo', repo + '/pkg')
            print('IDEMPOTENT', first == open(tf).read())
            print('CANONICAL', ('[folders."%s"]' % share) in first and 'gk-demo' not in first)
            print('SUBDIR', ('[folders."%s/pkg"]' % repo) in first)
            print('USER_NO_KEPT', first.count('[folders."%s"]' % repo) == 1 and 'trusted = false' in first)
            print('NO_HOME', ('[folders."%s"]' % home) not in first)
            print('INT_TIME', 'decided_at = 1' in first and 'trusted = true' in first and '"20' not in first)
            # An unreadable store is never touched.
            open(tf, 'w').write('[folders\\n')
            m._pretrust('grok', share)
            print('BROKEN_LEFT', open(tf).read() == '[folders\\n')
            """, dir: dir)
        for key in ["IDEMPOTENT", "CANONICAL", "SUBDIR", "USER_NO_KEPT", "NO_HOME", "INT_TIME", "BROKEN_LEFT"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    @Test("The guest grok() wrapper pins Ask when Grok's own config asks; any other choice passes through")
    func grokPermissionWrapper() throws {
        let rc = ProfileStore.bashrcContent
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "grok() {" })
        let indent = lines[start].prefix(while: { $0 == " " })
        let end = try #require(lines[start...].firstIndex { $0 == indent + "}" })
        let fn = lines[start...end].joined(separator: "\n")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("x"), withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("grok")
        try "#!/bin/sh\necho \"ARGS:$*\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        func call(config: String?, _ args: String) throws -> String {
            let home = dir.appendingPathComponent("home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
            if let config {
                try config.write(to: home.appendingPathComponent(".grok/config.toml"), atomically: true, encoding: .utf8)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"]
            p.arguments = ["-c", fn + "\ngrok " + args]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ask = "[cli]\ntheme = \"dark\"\n\n[ui]\npermission_mode = \"ask\"\n\n[permission]\nallow = []\n"
        #expect(try call(config: ask, "") == "ARGS:--permission-mode default")
        #expect(try call(config: ask, "-c") == "ARGS:--permission-mode default -c")
        #expect(try call(config: nil, "") == "ARGS:--permission-mode default")    // no mode named = Ask
        #expect(try call(config: "[ui]\npermission_mode = \"always-approve\"\n", "") == "ARGS:")
        #expect(try call(config: "[ui]\npermission_mode = \"auto\"\n", "-c") == "ARGS:-c")
        // A key of the same name in another table is not the mode.
        #expect(try call(config: "[hooks]\npermission_mode = \"auto\"\n", "") == "ARGS:--permission-mode default")
        // An explicit mode on the command line, a headless run, subcommands: untouched.
        #expect(try call(config: ask, "--always-approve") == "ARGS:--always-approve")
        #expect(try call(config: ask, "--permission-mode auto") == "ARGS:--permission-mode auto")
        #expect(try call(config: ask, "-p hi") == "ARGS:-p hi")
        #expect(try call(config: ask, "login") == "ARGS:login")
        #expect(try call(config: ask, "update") == "ARGS:update")
    }

    @Test("Grok's StopCancelled hook (a Ctrl-C'd turn) reports the tab done, from Grok's own hooks dir")
    func grokCancelHook() throws {
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(ProfileStore.grokStatusHooksJSON.utf8)) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["StopCancelled"])
        let group = try #require((hooks["StopCancelled"] as? [[String: Any]])?.first)
        let cmd = try #require((group["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(cmd == "/home/ubuntu/.bromure/agent-status.sh done")
    }

    @Test("A task worktree is locked (no host-side prune can drop it) and unlocked on removal",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func worktreeLock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run("""
            g = lambda *a: subprocess.run(['git', '-C', d + '/repo'] + list(a), capture_output=True, text=True)
            os.makedirs(d + '/repo')
            g('init', '-q', '-b', 'main'); g('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'a')
            wt = d + '/wt'
            g('worktree', 'add', '-q', '-b', 'wt/x', wt)
            m._worktree_lock(d + '/repo', wt)
            print('LOCKED', 'locked' in g('worktree', 'list', '--porcelain').stdout)
            # The host's view: the guest path is missing there.
            os.rename(wt, wt + '.away'); g('worktree', 'prune')
            print('SURVIVES', wt in g('worktree', 'list').stdout)
            os.rename(wt + '.away', wt)
            m._worktree_remove(d + '/repo', 'wt/x')
            print('GONE', not os.path.exists(wt) and wt not in g('worktree', 'list').stdout)
            """, dir: dir)
        for key in ["LOCKED", "SURVIVES", "GONE"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }
}
