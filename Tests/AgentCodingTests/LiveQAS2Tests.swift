import Foundation
import Testing
@testable import bromure_ac

/// Live-QA round S2 (and the rest of S1): sessions, Kimi folders and
/// permissions, chat echoes, failure cards.

@MainActor private func roster(_ id: UUID, _ tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
    let model = TabsModel()
    model.tabs = tabs
    model.rosterLive = true
    return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: model)
}

@Suite("Live QA S2 — a new agent run in an ended tab")
@MainActor
struct LiveQAS2NewRunTests {
    private func tempStore() -> AgentSessionStore {
        AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
    }

    /// A Kimi session bound to tab 1, started long ago, its agent exited.
    private func endedKimi(_ ws: UUID, store: AgentSessionStore) -> AgentSession {
        var s = AgentSession(profileID: ws, tool: .kimi, title: "Explain hash tables", cwd: "~/hash-1004-2143",
                             createdAt: Date().addingTimeInterval(-3600), windowIndex: 1)
        s.agentAlive = false
        store.upsert(s)
        #expect(store.checkAgentProcess(s.id, start: 1_000_000))   // first sight: stamped
        return s
    }

    @Test("S2-2: the same agent process keeps the session; another one ends it and frees the tab")
    func newProcessFreesTab() {
        let store = tempStore()
        let ws = UUID()
        let s = endedKimi(ws, store: store)
        #expect(store.session(s.id)?.agentProcessStart == 1_000_000)
        #expect(store.checkAgentProcess(s.id, start: 1_000_001))    // rounding
        #expect(store.session(s.id)?.windowIndex == 1)
        // `kimi` typed again in that tab.
        #expect(!store.checkAgentProcess(s.id, start: 1_000_500))
        let old = store.session(s.id)!
        #expect(old.windowIndex == nil)
        #expect(old.releasedWindowIndex == 1)
        #expect(old.hasEnded)
        #expect(old.title == "Explain hash tables")
        #expect(old.cwd == "~/hash-1004-2143")
    }

    @Test("S2-2: the roster adopts the new run as a session of its own; the old one never rebinds")
    func rosterAdoptsNewSession() {
        let store = tempStore()
        let ws = UUID()
        let s = endedKimi(ws, store: store)
        var followed: (UUID, UUID)?
        store.onSucceeded = { followed = ($0, $1) }
        #expect(!store.checkAgentProcess(s.id, start: 1_000_500))
        let tabs = [TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"),
                    TabsModel.Tab(label: "kimi", index: 1, cwd: "/home/ubuntu/hash-1004-2143")]
        store.reconcile(entries: [roster(ws, tabs)])
        let bound = store.session(profileID: ws, windowIndex: 1)
        #expect(bound != nil)
        #expect(bound?.id != s.id)
        #expect(store.session(s.id)?.windowIndex == nil)
        #expect(store.session(s.id)?.title == "Explain hash tables")
        #expect(followed?.0 == s.id)
        #expect(followed?.1 == bound?.id)
        // Later reconciles leave it that way.
        store.reconcile(entries: [roster(ws, tabs)])
        #expect(store.session(s.id)?.windowIndex == nil)
    }

    @Test("S2-2: our own launch, resume or restart in place is never a new run")
    func ownRestartsAreNotNewRuns() {
        let ws = UUID()
        let old = Date().addingTimeInterval(-3600)
        var s = AgentSession(profileID: ws, tool: .kimi, title: "t", createdAt: old, windowIndex: 1)
        let start = Int(Date().timeIntervalSince1970)
        #expect(AgentSessionStore.isNewAgentRun(s, start: start))
        s.launchingSince = Date()
        #expect(!AgentSessionStore.isNewAgentRun(s, start: start))
        s.launchingSince = nil
        s.resumedAt = Date().addingTimeInterval(-30)               // resumed just now (host clock)
        #expect(!AgentSessionStore.isNewAgentRun(s, start: start + 100_000))   // whatever the guest clock says
        s.resumedAt = Date().addingTimeInterval(-600)
        #expect(!AgentSessionStore.isNewAgentRun(s, start: Int(s.resumedAt!.timeIntervalSince1970) + 5))
        #expect(AgentSessionStore.isNewAgentRun(s, start: start))
        let fresh = AgentSession(profileID: ws, tool: .kimi, title: "t", windowIndex: 1)
        #expect(!AgentSessionStore.isNewAgentRun(fresh, start: start))   // a launch's first moments
    }

    @Test("S2-2: the probe's proc lines parse to start times")
    func parseAgentStarts() {
        let out = "boot\tabc\nwin\t1\t@3\nproc\t1\t1759600000\nproc\t2\tx\nproc\t1\t1\n"
        #expect(AgentSessionEngine.parseAgentStarts(out) == [1: 1_759_600_000])
    }
}

@Suite("Live QA S2 — Kimi folders in any script")
@MainActor
struct LiveQAS2KimiFolderTests {
    @Test("S2-1: Kimi's slug drops what isn't [a-z0-9._-], exactly like workdir-slug.ts")
    func kimiSlug() {
        #expect(AgentSessionLocator.kimiWorkDirSlug("请用一句话解释什么是哈希表-1004-2143") == "1004-2143")
        #expect(AgentSessionLocator.kimiWorkDirSlug("Café Ünïcode") == "caf-n-code")
        #expect(AgentSessionLocator.kimiWorkDirSlug("请用") == "workspace")
        #expect(AgentSessionLocator.kimiWorkDirSlug("..") == "workspace")
        #expect(AgentSessionLocator.kimiWorkDirSlug(String(repeating: "a", count: 39) + "-bc") == String(repeating: "a", count: 39))
        #expect(CodingTaskEngine.kimiSlug("add-a-multiply-function-to-calc-py-and-print") == "add-a-multiply-function-to-calc-py-and-p")
    }

    @Test("S2-1: the guest's shell computes the same bucket as Kimi for a CJK folder")
    func shellBucketMatches() throws {
        guard FileManager.default.isExecutableFile(atPath: "/sbin/sha256sum")
                || FileManager.default.isExecutableFile(atPath: "/usr/bin/sha256sum") else { return }
        for d in ["/home/ubuntu/请用一句话解释什么是哈希表-1004-2143", "/home/ubuntu/Café-déjà", "/home/ubuntu/plain-dir"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Through a file: Process arguments and environment go through
            // the file system representation, which decomposes "é".
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("kdir-\(UUID().uuidString)")
            try Data(d.utf8).write(to: f)
            defer { try? FileManager.default.removeItem(at: f) }
            p.arguments = ["-c", "d=$(cat \"$1\"); r=\"$d\"; " + AgentSessionLocator.kimiBucketVars + "printf 'wd_%s_%s' \"$kb\" \"$kh\"",
                           "sh", f.path]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["LANG"] = "en_US.UTF-8"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(out == AgentSessionLocator.kimiWorkDirKey(d), "\(d)")
        }
        #expect(AgentSessionLocator.kimiWorkDirKey("/home/ubuntu/请用一句话解释什么是哈希表-1004-2143/")
                    .hasPrefix("wd_1004-2143_"))
    }

    @Test("S2-1: a cwd in another script is a path we can look up, a control character never")
    func sanitizedCwd() {
        #expect(AgentSessionLocator.sanitized(guestCwd: "/home/ubuntu/请用-1004-2143/") == "/home/ubuntu/请用-1004-2143")
        #expect(AgentSessionLocator.sanitized(guestCwd: "/home/ubuntu/a\nb") == nil)
        #expect(AgentSessionLocator.sanitized(guestCwd: "/home/ubuntu/it's") == nil)
    }

    @Test("S2-1: folders Bromure names are ASCII only")
    func asciiFolderNames() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 4; c.hour = 21; c.minute = 43
        let now = Calendar.current.date(from: c)!
        #expect(AgentSessionEngine.syntheticFolderName(message: "请用一句话解释什么是哈希表 🚀 然后…", tool: .kimi, now: now)
                    == "kimi-1004-2143")
        #expect(AgentSessionEngine.syntheticFolderName(message: "Réparer le café", tool: .kimi, now: now)
                    == "reparer-le-1004-2143")
        #expect(AgentSession.worktreeSlug("Café 请用 fix") == "cafe-fix")
        #expect(AgentSession.worktreeSlug("请用") == "worktree")
        let slug = ScheduledAutomationEngine.branchSlug(for: "Nightly 构建 résumé", at: now)
        #expect(slug.allSatisfy { $0.isASCII })
        #expect(slug.hasPrefix("nightly-resume"))
    }
}

@Suite("Live QA S2 — provider errors in the status")
@MainActor
struct LiveQAS2ProviderErrorTests {
    @Test("S1-3: an error card puts a working session under Needs you, worded for the error")
    func providerErrorBucket() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let ws = UUID()
        var s = AgentSession(profileID: ws, tool: .omp, title: "Retry", cwd: "~/r",
                             createdAt: Date().addingTimeInterval(-3600), windowIndex: 1)
        s.agentAlive = true
        store.upsert(s)
        let tab = TabsModel.Tab(label: "omp", index: 1, cwd: "/home/ubuntu/r")
        tab.agentStatus = .working
        let model = SessionListModel()
        model.headlessEntries = [roster(ws, [TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"), tab])]
        model.profileRows = [SessionListModel.ProfileRow(id: ws, name: "QA", accentHex: "#000000",
                                                         state: .running, compromised: false)]
        #expect(SessionHome.bucket(for: store.session(s.id)!, in: model) == .working)
        store.setProviderError(s.id, AgentSession.providerErrorKind(SessionFailure(kind: .generic, detail: "502")))
        #expect(SessionHome.bucket(for: store.session(s.id)!, in: model) == .needsYou)
        #expect(SessionHome.statusLine(for: store.session(s.id)!, in: model) == "Provider unreachable")
        store.setProviderError(s.id, "quota")
        #expect(SessionHome.statusLine(for: store.session(s.id)!, in: model) == "Usage limit reached")
        // New output cleared the card: back to what the agent says.
        store.setProviderError(s.id, nil)
        #expect(SessionHome.bucket(for: store.session(s.id)!, in: model) == .working)
    }
}

@Suite("Live QA S2 — Kimi's permission rules")
struct LiveQAS2KimiPermissionTests {
    /// Kimi's `sanitizeMcpNamePart` + `qualifyMcpToolName` (tool-naming.ts).
    private func qualified(_ server: String, _ tool: String) -> String {
        func part(_ s: String) -> String {
            s.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
                .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        }
        return "mcp__\(part(server))__\(part(tool))"
    }

    /// picomatch on a name with no "/": `*` is any run of characters.
    private func globMatches(_ glob: String, _ name: String) -> Bool {
        let re = "^" + glob.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return name.range(of: re, options: .regularExpression) != nil
    }

    private var patterns: [String] {
        SessionDisk.kimiHooksTOML.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("pattern = \"") else { return nil }
            return String(l.dropFirst("pattern = \"".count).dropLast())
        }
    }

    @Test("S1-5: each rule is Kimi's shape and matches our tools' qualified names, nothing else")
    func rulesMatchQualifiedNames() {
        let toml = SessionDisk.kimiHooksTOML
        #expect(toml.contains("[[permission.rules]]\ndecision = \"allow\"\npattern = \"mcp__delegation__*\""))
        let ps = patterns
        #expect(!ps.isEmpty)
        for (server, tool) in [("delegation", "delegate"), ("delegation", "list_peers"),
                               ("bromure-delegation", "ask"), ("display", "show_image"),
                               ("switchboard", "route")] {
            let name = qualified(server, tool)
            #expect(ps.contains { globMatches($0, name) }, "\(name)")
        }
        for name in [qualified("browser", "navigate"), "Bash", "mcp__delegationx__ask", "mcp__delegation"] {
            #expect(!ps.contains { globMatches($0, name) }, "\(name)")
        }
        // The bare server name (Claude's form) would match nothing in Kimi.
        #expect(!globMatches("mcp__delegation", qualified("delegation", "ask")))
    }
}

@Suite("Live QA S2 — chat echoes")
struct LiveQAS2EchoTests {
    @Test("S1-2: Claude's closing tag that repeats the id still closes the paste")
    func closingTagWithID() {
        let wrapped = "<pasted_content id=\"11de\">line 1\nline 2</pasted_content id=\"11de\">"
        #expect(ClaudeTranscriptParser.unwrapPasted(wrapped) == "line 1\nline 2")
        #expect(ClaudeTranscriptParser.unwrapPasted("see:\n" + wrapped + "\nthanks") == "see:\nline 1\nline 2\nthanks")
        #expect(BeautifiedSessionModel.echoMatches("line 1\r\nline 2", recorded: wrapped))
        // Malformed stays as written.
        #expect(ClaudeTranscriptParser.unwrapPasted("<pasted_content id=\"1\">x") == "<pasted_content id=\"1\">x")
    }

    @Test("S2-10: a huge paste recorded cut short or re-flowed is the same message")
    func hugePasteEcho() {
        var echo = ""
        var i = 0
        while echo.utf8.count < 778_131 { echo += "word\(i) "; i += 1 }
        echo = String(echo.prefix(778_131))
        let cut = String(echo.prefix(500_000))
        #expect(BeautifiedSessionModel.echoMatches(echo, recorded: cut))
        let reflowed = echo.replacingOccurrences(of: " ", with: "\n")
        #expect(BeautifiedSessionModel.echoMatches(echo, recorded: reflowed))
        // Another big message is not.
        let other = String(repeating: "other text ", count: 60_000)
        #expect(!BeautifiedSessionModel.echoMatches(echo, recorded: other))
        // Short messages still need to match whole.
        #expect(!BeautifiedSessionModel.echoMatches("hello world", recorded: "hello"))
    }
}

@Suite("Live QA S2 — failure card body")
@MainActor
struct LiveQAS2FailureCardTests {
    @Test("J6: box art scraped off the screen is no reason; the task's recorded reason wins")
    func failureBody() {
        #expect(SessionFailure.clean("╰──────────────────────╯") == "")
        #expect(SessionFailure.clean("│ Error: no model configured │") == "Error: no model configured")
        let scraped = SessionFailure(kind: .generic, detail: "╭- - - - - - - - - - -╮")
        let reason = "Kimi Code exited right after it started (status 137) — open the session to see why, then Restart Session."
        #expect(SessionFailure.body(scraped, taskError: reason) == reason)
        #expect(SessionFailure.body(scraped, taskError: nil) == "")
        // A sign-in card keeps the agent's words.
        let auth = SessionFailure(kind: .auth, detail: "Invalid API key")
        #expect(SessionFailure.body(auth, taskError: reason) == "Invalid API key")
    }

    @Test("J6: the launcher's exit reason skips a frame line the TUI left")
    func earlyExitSkipsBoxArt() {
        let screen = """
        [bromure-ac] starting kimi
        error: something broke
        ╰──────────────────────╯
        [bromure-ac] kimi exited with status 137
        """
        #expect(AgentSessionEngine.earlyExitReason(screen, tool: "kimi") == "error: something broke")
    }
}
