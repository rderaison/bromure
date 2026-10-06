import Foundation
import Testing
@testable import bromure_ac

/// Code-review watches: the scheduled review's scope (baseline vs the
/// commits since the last review), the "reviewed through" mark, the
/// fire-time plan and prompts, the run record, the guest command, and the
/// agent choice.
@Suite("Code review scope and agent choice")
@MainActor
struct RepoWatchReviewScopeTests {
    private let shaA = "1111111111111111111111111111111111111111"
    private let shaB = "2222222222222222222222222222222222222222"

    private func tempStore() -> FindingStore {
        FindingStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("findings-\(UUID().uuidString).json"), persists: false)
    }

    // MARK: Model + back-compat

    @Test("New watches review new commits; watches saved before the choice keep reviewing everything")
    func backCompat() throws {
        #expect(WatchedRepo(repo: "a/b", profileID: UUID()).scheduledScope == .newCommits)

        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let legacy = #"{"id":"\#(UUID().uuidString)","repo":"acme/api","profileID":"\#(UUID().uuidString)","tool":"claude","scans":["fullScan","commits"]}"#
        let old = try dec.decode(WatchedRepo.self, from: Data(legacy.utf8))
        #expect(old.scheduledScope == .baseline)
        #expect(old.reviewedThrough.isEmpty)
        #expect(!old.firstRunBaseline)
        #expect(old.lastReviewed == nil)

        // An unknown scope from a newer build: the old behavior, not a failure.
        let future = #"{"id":"\#(UUID().uuidString)","repo":"acme/api","profileID":"\#(UUID().uuidString)","scheduledScope":"somethingNew"}"#
        #expect(try dec.decode(WatchedRepo.self, from: Data(future.utf8)).scheduledScope == .baseline)
    }

    @Test("Scope, first-run choice and marks round-trip through JSON")
    func roundTrip() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let w = WatchedRepo(repo: "a/b", profileID: UUID(), tool: .codex, commitBranch: "main",
                            createdAt: t, scheduledScope: .newCommits, firstRunBaseline: true,
                            reviewedThrough: ["main": .init(sha: shaA, at: t)])
        let back = try dec.decode(WatchedRepo.self, from: enc.encode(w))
        #expect(back == w)
        #expect(back.lastReviewed?.sha == shaA)
        #expect(back.tool == .codex)
    }

    @Test("The mark is per branch and only moves forward in time")
    func markPersistence() {
        let store = tempStore()
        let w = WatchedRepo(repo: "a/b", profileID: UUID(), commitBranch: "main")
        store.upsertWatch(w)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(store.advanceReviewMark(watchID: w.id, branch: "main", sha: shaA, at: t0))
        #expect(store.watch(w.id)?.lastReviewed?.sha == shaA)
        // An older run finishing late never winds it back.
        #expect(!store.advanceReviewMark(watchID: w.id, branch: "main", sha: shaB,
                                         at: t0.addingTimeInterval(-60)))
        #expect(store.watch(w.id)?.lastReviewed?.sha == shaA)
        #expect(store.advanceReviewMark(watchID: w.id, branch: "main", sha: shaB.uppercased(),
                                        at: t0.addingTimeInterval(60)))
        #expect(store.watch(w.id)?.lastReviewed?.sha == shaB)
        // Not a commit id: refused. Another branch: its own mark.
        #expect(!store.advanceReviewMark(watchID: w.id, branch: "main", sha: "HEAD", at: Date()))
        #expect(store.advanceReviewMark(watchID: w.id, branch: "", sha: shaA, at: t0))
        #expect(store.watch(w.id)?.reviewedThrough.count == 2)
    }

    // MARK: Plan

    @Test("What a run covers: baseline, the range since the mark, the latest commits, or nothing")
    func plan() {
        var w = WatchedRepo(repo: "a/b", profileID: UUID(), commitBranch: "main")
        // No mark yet: the latest 20 commits.
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaB)
                == .recent(count: WatchedRepo.recentCommitWindow, head: shaB))
        // ...or a baseline first, when asked.
        w.firstRunBaseline = true
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaB) == .baseline(head: shaB))
        w.firstRunBaseline = false
        // A mark: the range after it.
        w.reviewedThrough["main"] = .init(sha: shaA, at: Date())
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaB) == .range(base: shaA, head: shaB))
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: nil) == .range(base: shaA, head: nil))
        // Nothing new since.
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaA.uppercased()) == .upToDate(head: shaA))
        // The one-off baseline, and a baseline-scope watch.
        #expect(ReviewPlan.make(for: w, forceBaseline: true, head: shaB) == .baseline(head: shaB))
        w.scheduledScope = .baseline
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaB) == .baseline(head: shaB))
        // A head that isn't a commit id is ignored.
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: "not a sha") == .baseline(head: nil))
        // The mark belongs to its branch: another branch starts over.
        w.scheduledScope = .newCommits
        w.commitBranch = "release"
        #expect(ReviewPlan.make(for: w, forceBaseline: false, head: shaB)
                == .recent(count: WatchedRepo.recentCommitWindow, head: shaB))
    }

    // MARK: Prompts

    @Test("Each scope's prompt carries its git commands, the reporting rules and findings_done")
    func prompts() {
        var w = WatchedRepo(repo: "acme/api", profileID: UUID(), commitBranch: "main",
                            instructions: "Ignore vendor/.")
        let range = RepoWatchPrompts.scheduledReview(w, plan: .range(base: shaA, head: shaB), tool: .claude)
        #expect(range.contains("git log --oneline \(shaA)..\(shaB)"))
        #expect(range.contains("git merge-base --is-ancestor \(shaA) \(shaB)"))
        #expect(range.contains("git reset --hard \(shaB)"))
        #expect(range.contains("findings_report") && range.contains("findings_done"))
        #expect(range.hasSuffix("Ignore vendor/."))

        let recent = RepoWatchPrompts.scheduledReview(w, plan: .recent(count: 20, head: nil), tool: .claude)
        #expect(recent.contains("git log --oneline -20 origin/main"))
        #expect(recent.contains("git fetch origin"))

        w.commitBranch = ""
        let base = RepoWatchPrompts.scheduledReview(w, plan: .baseline(head: shaB), tool: .claude)
        #expect(base.contains("git ls-files | wc -l"))
        #expect(base.contains("Rank the directories"))
        #expect(base.contains("before you move on to the next one"))
        #expect(base.contains(shaB))
        #expect(!RepoWatchPrompts.scheduledReview(w, plan: .baseline(head: nil), tool: .claude)
            .contains("git reset --hard \(shaB)"))
    }

    @Test("The prompt names the findings tools the way each agent lists them")
    func toolNaming() {
        let w = WatchedRepo(repo: "acme/api", profileID: UUID())
        let claude = RepoWatchPrompts.scheduledReview(w, plan: .baseline(head: nil), tool: .claude)
        #expect(claude.contains("mcp__automations__findings_report"))
        for tool in [Profile.Tool.codex, .grok, .kimi, .omp] {
            let p = RepoWatchPrompts.scheduledReview(w, plan: .baseline(head: nil), tool: tool)
            #expect(p.contains("server named `automations`"), "\(tool)")
            #expect(p.contains("not as shell commands"), "\(tool)")
        }
        // The event scans follow the watch's agent too.
        var codexWatch = w
        codexWatch.tool = .codex
        #expect(RepoWatchPrompts.commitScan(codexWatch).contains("not as shell commands"))
        #expect(RepoWatchPrompts.pullRequestScan(codexWatch).contains("not as shell commands"))
    }

    @Test("Fire-time preparation: prompt, worktree base, run record, and a skip when nothing is new")
    func preparation() {
        var w = WatchedRepo(repo: "acme/api", profileID: UUID(), tool: .grok, commitBranch: "main")
        var a = RepoWatchEngine.automation(for: .fullScan, of: w, id: UUID(), createdAt: nil)
        a.tool = .grok
        w.automationIDs["fullScan"] = a.id

        let first = RepoWatchEngine.preparation(for: w, automation: a, forceBaseline: false, head: shaB)
        #expect(first.skipReason == nil)
        #expect(first.base == shaB)
        #expect(first.review == .init(scope: "newCommits", branch: "main", base: nil, head: shaB))
        #expect(first.prompt.contains("-20"))
        #expect(first.prompt.contains("server named `automations`"))

        w.reviewedThrough["main"] = .init(sha: shaA, at: Date())
        let next = RepoWatchEngine.preparation(for: w, automation: a, forceBaseline: false, head: shaB)
        #expect(next.review.base == shaA)
        #expect(next.detail.contains("1111111") && next.detail.contains("2222222"))

        // GitHub couldn't be asked: start from the remote branch; the agent resolves it.
        let blind = RepoWatchEngine.preparation(for: w, automation: a, forceBaseline: false, head: nil)
        #expect(blind.base == "origin/main")
        #expect(blind.review.head == nil)

        let none = RepoWatchEngine.preparation(for: w, automation: a, forceBaseline: false, head: shaA)
        #expect(none.skipReason != nil)

        let forced = RepoWatchEngine.preparation(for: w, automation: a, forceBaseline: true, head: shaA)
        #expect(forced.skipReason == nil)
        #expect(forced.review.scope == "baseline")
    }

    @Test("The scheduled review's automation is named after what it covers")
    func automationNames() {
        var w = WatchedRepo(repo: "acme/api", profileID: UUID())
        #expect(RepoWatchEngine.automation(for: .fullScan, of: w, id: UUID(), createdAt: nil).name
                == "api · " + w.scanShortName(.fullScan))
        #expect(w.scanShortName(.fullScan) != WatchedRepo.Scan.fullScan.shortName)
        w.scheduledScope = .baseline
        #expect(w.scanShortName(.fullScan) == WatchedRepo.Scan.fullScan.shortName)
        #expect(w.scanShortName(.commits) == WatchedRepo.Scan.commits.shortName)
    }

    // MARK: Run record + guest command

    @Test("Run records keep the agent and what a review covered; old records decode")
    func runRecord() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = AutomationRunRecord(
            automationID: UUID(), firedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .launched, detail: "d", branchSlug: "s", tool: .kimi,
            review: .init(scope: "newCommits", branch: "main", base: shaA, head: shaB))
        #expect(try dec.decode(AutomationRunRecord.self, from: enc.encode(r)) == r)
        let legacy = #"{"id":"\#(UUID().uuidString)","automationID":"\#(UUID().uuidString)","firedAt":"2026-01-01T00:00:00Z","outcome":"launched","detail":"x"}"#
        let old = try dec.decode(AutomationRunRecord.self, from: Data(legacy.utf8))
        #expect(old.tool == nil && old.review == nil)
    }

    @Test("A review run's head learnt from the agent fills in, never overwrites")
    func reviewHeadFromAgent() {
        let store = ScheduledAutomationStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("autos-\(UUID().uuidString).json"))
        let run = AutomationRunRecord(automationID: UUID(), firedAt: Date(), outcome: .launched,
                                      detail: "d", review: .init(scope: "baseline", branch: ""))
        store.record(run)
        store.setReviewHead(run.id, sha: shaA)
        #expect(store.runs.first?.review?.head == shaA)
        store.setReviewHead(run.id, sha: shaB)
        #expect(store.runs.first?.review?.head == shaA)
    }

    @Test("automation-run carries the review mode and the commit the worktree starts from")
    func guestCommand() throws {
        let base = ["/home/ubuntu/api", "slug", "name", "codex", "prompt"]
        let plain = try #require(GuestCommand.line(action: "run", args: base))
        #expect(GuestCommand.fields(plain, 8).filter { !$0.isEmpty }.count == 6)   // verb + 5

        let review = try #require(GuestCommand.line(action: "run", args: base + ["review", shaB]))
        let f = GuestCommand.fields(review, 8)
        #expect(f[0] == "automation-run")
        #expect(GuestCommand.decode(f[4]) == "codex")
        #expect(GuestCommand.decode(f[6]) == "review")
        #expect(GuestCommand.decode(f[7]) == shaB)

        // A base with no mode keeps the mode's slot with the placeholder.
        let baseOnly = try #require(GuestCommand.line(action: "run", args: base + ["", "origin/main"]))
        let g = GuestCommand.fields(baseOnly, 8)
        #expect(g[6] == GuestCommand.emptyPlaceholder)
        #expect(GuestCommand.decode(g[7]) == "origin/main")
        // A board task's line is unchanged.
        let task = try #require(GuestCommand.line(action: "run", args: base + ["task"]))
        #expect(GuestCommand.fields(task, 8).filter { !$0.isEmpty }.count == 7)
    }

    // MARK: Agent choice + MCP

    @Test("A new watch's agent: the workspace's main agent when ready, else Claude Code, else any ready one")
    func defaultAgent() {
        #expect(WatchWorkspaceChoice.defaultTool(primary: .codex, ready: [.claude, .codex]) == .codex)
        #expect(WatchWorkspaceChoice.defaultTool(primary: .grok, ready: [.kimi, .claude]) == .claude)
        #expect(WatchWorkspaceChoice.defaultTool(primary: .grok, ready: [.kimi, .omp]) == .kimi)
        #expect(WatchWorkspaceChoice.defaultTool(primary: .omp, ready: []) == .omp)
    }

    @Test("findings_done is offered, and refuses a session that isn't a scan run")
    func findingsDone() async {
        #expect(AutomationMCPServer.toolDefinitions.contains { ($0["name"] as? String) == "findings_done" })
        let engine = RepoWatchEngine(store: tempStore(), delegate: nil)
        let server = AutomationMCPServer(profileID: UUID(), store: { nil }, profile: { nil },
                                         save: { _ in }, remove: { _ in }, runNow: { _ in },
                                         watches: { engine })
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": "findings_done",
                                             "arguments": ["summary": "done", "commit": shaA]]]
        let line = String(data: try! JSONSerialization.data(withJSONObject: req), encoding: .utf8)!
        let resp = await server.handle(line: line, branch: "wt/not-a-run") ?? ""
        #expect(resp.contains("isn't a running repository-watch scan"))
    }
}

/// The guest side of a review run, per agent: launch flags, the findings
/// tools' MCP declaration, folder trust, and the pinned worktree base.
@Suite("Code review runs in the guest (agentd)")
struct ReviewRunAgentdTests {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-agentd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A repo with two commits; the review is pinned to the FIRST while the
    /// checkout sits on the second. `_new_window` is stubbed to capture the
    /// launch env.
    private static let setup = """
        home = d + '/home'; os.makedirs(home); m.HOME = home
        # Worktrees go under ~/.bromure/worktrees (expanduser): never the real home.
        os.environ['HOME'] = home
        shim = d + '/bromure-automations-mcp.py'; open(shim, 'w').write('')
        m._AUTOMATIONS_MCP_SHIM = shim
        m._ensure_seed_current = lambda: None
        # Never the developer's real Claude install or home.
        m._claude_nudge_keys = lambda: {}
        m._NUDGE_CACHE = home + '/.bromure/claude-nudge-keys.json'
        m._set_window_option = lambda *a: None
        launched = []
        def fake_window(command=None, cwd=None, env=None, background=False):
            launched.append({'cwd': cwd, 'env': env}); return '@9'
        m._new_window = fake_window
        repo = d + '/api'; os.makedirs(repo)
        g = lambda *a: subprocess.run(['git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@example.com'] + list(a),
                                      check=True, capture_output=True, text=True).stdout.strip()
        subprocess.run(['git', 'init', '-q', '-b', 'main', repo], check=True)
        g('commit', '-q', '--allow-empty', '-m', 'one'); first = g('rev-parse', 'HEAD')
        g('commit', '-q', '--allow-empty', '-m', 'two')

        """

    @Test("Each agent's review run: unattended flags, the findings MCP where it reads it, trust, pinned base",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func perAgentLaunch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            for i, tool in enumerate(['claude', 'codex', 'grok', 'kimi', 'omp']):
                m._automation_run(repo, 'rev-%d' % i, 'api review', tool, '-', 'review', first)
                import time
                for _ in range(50):
                    if len(launched) > i: break
                    time.sleep(0.1)
                L = launched[i]; wt = L['cwd']; env = L['env']
                flags = env.get('BROMURE_AC_WT_FLAGS', '')
                head = subprocess.run(['git', '-C', wt, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
                print(tool, 'TOOL', env.get('BROMURE_AC_WT_TOOL') == tool)
                print(tool, 'PINNED', head == first)
                print(tool, 'FLAGS', repr(flags))
                grok_cfg = os.path.join(wt, '.grok', 'config.toml')
                kimi_cfg = os.path.join(wt, '.kimi-code', 'mcp.json')
                omp_cfg = os.path.join(wt, '.mcp.json')
                def has(p, needle):
                    return os.path.exists(p) and needle in open(p).read()
                print(tool, 'GROKMCP', has(grok_cfg, '[mcp_servers.automations]') and has(grok_cfg, shim))
                print(tool, 'KIMIMCP', os.path.exists(kimi_cfg) and 'automations' in json.load(open(kimi_cfg)).get('mcpServers', {}))
                print(tool, 'OMPMCP', os.path.exists(omp_cfg) and 'automations' in json.load(open(omp_cfg)).get('mcpServers', {}))
                st = subprocess.run(['git', '-C', wt, 'status', '--porcelain'], capture_output=True, text=True).stdout.strip()
                print(tool, 'CLEAN', st == '')
            kt = os.path.join(home, '.kimi-code', 'workspace-trust')
            print('KIMI_TRUSTED', os.path.isdir(kt) and len(os.listdir(kt)) > 0)
            ct = os.path.join(home, '.codex', 'config.toml')
            print('CODEX_TRUSTED', os.path.exists(ct) and 'trust_level = "trusted"' in open(ct).read())
            cj = os.path.join(home, '.claude.json')
            print('CLAUDE_TRUSTED', os.path.exists(cj) and any(v.get('hasTrustDialogAccepted') for v in json.load(open(cj)).get('projects', {}).values()))
            gt = os.path.join(home, '.grok', 'trusted_folders.toml')
            print('GROK_TRUSTED', os.path.exists(gt) and 'trusted = true' in open(gt).read())
            """, dir: dir)
        // Unattended flags exactly as automations already get them.
        #expect(out.contains("claude FLAGS '--dangerously-skip-permissions'"), Comment(rawValue: out))
        #expect(out.contains("codex FLAGS '--dangerously-bypass-approvals-and-sandbox'"), Comment(rawValue: out))
        #expect(out.contains("omp FLAGS '--auto-approve'"), Comment(rawValue: out))
        // Kimi's one-shot --prompt refuses --yolo/--auto; Grok has none.
        #expect(out.contains("kimi FLAGS ''"), Comment(rawValue: out))
        #expect(out.contains("grok FLAGS ''"), Comment(rawValue: out))
        for tool in ["claude", "codex", "grok", "kimi", "omp"] {
            #expect(out.contains("\(tool) TOOL True"), Comment(rawValue: out))
            #expect(out.contains("\(tool) PINNED True"), Comment(rawValue: out))
            // The declarations are git-excluded: the review leaves no diff.
            #expect(out.contains("\(tool) CLEAN True"), Comment(rawValue: out))
        }
        // Findings MCP in the project scope of the agents that need it, only.
        #expect(out.contains("grok GROKMCP True"), Comment(rawValue: out))
        #expect(out.contains("kimi KIMIMCP True"), Comment(rawValue: out))
        #expect(out.contains("omp OMPMCP True"), Comment(rawValue: out))
        for tool in ["claude", "codex"] {
            #expect(out.contains("\(tool) GROKMCP False") && out.contains("\(tool) KIMIMCP False")
                    && out.contains("\(tool) OMPMCP False"), Comment(rawValue: out))
        }
        for key in ["KIMI_TRUSTED", "CODEX_TRUSTED", "CLAUDE_TRUSTED", "GROK_TRUSTED"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    @Test("A review base the checkout lacks falls back to HEAD instead of failing the run",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func baseFallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            print('KNOWN', m._resolve_run_base(repo, first) == first)
            print('BRANCH', m._resolve_run_base(repo, 'main') == 'main')
            print('UNKNOWN', m._resolve_run_base(repo, 'f' * 40) == '')
            print('OPTION', m._resolve_run_base(repo, '--upload-pack=x') == '')
            print('EMPTY', m._resolve_run_base(repo, '') == '')
            # Old-style run (no mode, no base): a plain worktree at HEAD, no findings declaration.
            m._automation_run(repo, 'plain', 'x', 'grok', '-')
            import time
            for _ in range(50):
                if launched: break
                time.sleep(0.1)
            wt = launched[0]['cwd']
            print('PLAIN_HEAD', subprocess.run(['git', '-C', wt, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip() == g('rev-parse', 'HEAD'))
            cfg = os.path.join(wt, '.grok', 'config.toml')
            print('PLAIN_NO_FINDINGS', not os.path.exists(cfg) or 'automations' not in open(cfg).read())
            """, dir: dir)
        for key in ["KNOWN", "BRANCH", "UNKNOWN", "OPTION", "EMPTY", "PLAIN_HEAD", "PLAIN_NO_FINDINGS"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }
}
