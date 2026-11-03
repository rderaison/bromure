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
        #expect(range.contains("git log --oneline --first-parent \(shaA)..\(shaB)"))
        #expect(range.contains("git merge-base --is-ancestor \(shaA) \(shaB)"))
        #expect(range.contains("git reset --hard \(shaB)"))
        #expect(range.contains("findings_report") && range.contains("findings_done"))
        #expect(range.hasSuffix("Ignore vendor/."))

        let recent = RepoWatchPrompts.scheduledReview(w, plan: .recent(count: 20, head: nil), tool: .claude)
        #expect(recent.contains("git log --oneline --first-parent -20 origin/main"))
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
        // Kimi's one-shot --prompt refuses --yolo/--auto; Grok's would
        // otherwise ask before every command.
        #expect(out.contains("kimi FLAGS ''"), Comment(rawValue: out))
        #expect(out.contains("grok FLAGS '--always-approve'"), Comment(rawValue: out))
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

    @Test("A review base the checkout lacks refuses the run instead of reviewing HEAD",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func baseFallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            errors = []
            m.worktree_err = errors.append
            print('KNOWN', m._resolve_run_base(repo, first) == first)
            print('BRANCH', m._resolve_run_base(repo, 'main') == 'main')
            print('UNKNOWN', m._resolve_run_base(repo, 'f' * 40) is None)
            print('OPTION', m._resolve_run_base(repo, '--upload-pack=x') is None)
            print('EMPTY', m._resolve_run_base(repo, '') is None)
            # A review asked for a base that isn't there: refused, said so, nothing launched.
            m._automation_run(repo, 'gone', 'x', 'grok', '-', 'review', 'f' * 40)
            print('REFUSED', not launched and len(errors) == 1 and 'f' * 40 in errors[0])
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
        for key in ["KNOWN", "BRANCH", "UNKNOWN", "OPTION", "EMPTY", "REFUSED", "PLAIN_HEAD", "PLAIN_NO_FINDINGS"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// Finding (CWE-78): "Review fetch allows a repo uploadpack and cannot
    /// fetch https remotes". The fetch's protocol whitelist kept `file`, which
    /// overrides protocol.file.allow=never: a repository's own
    /// remote.origin.uploadpack (or an insteadOf rewrite onto file://) ran a
    /// program of its choosing.
    @Test("The review fetch never runs a repository's upload pack, and keeps only network transports",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func fetchRunsNoRepoProgram() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            marker = d + '/ran'
            evil = d + '/uploadpack'
            open(evil, 'w').write('#!/bin/sh\\necho "$@" > %s\\nexec git-upload-pack "$@"\\n' % marker)
            os.chmod(evil, 0o755)
            # A file origin that has a commit the checkout lacks.
            up = d + '/up'
            subprocess.run(['git', 'clone', '-q', '--bare', repo, up], check=True)
            other = d + '/other'
            subprocess.run(['git', 'clone', '-q', up, other], check=True)
            subprocess.run(['git', '-C', other, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                            'commit', '-q', '--allow-empty', '-m', 'three'], check=True)
            subprocess.run(['git', '-C', other, 'push', '-q', 'origin', 'main'], check=True)
            ahead = subprocess.run(['git', '-C', other, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            g('remote', 'add', 'origin', 'file://' + up)
            g('config', 'remote.origin.uploadpack', evil)
            print('FILE_ORIGIN', m._resolve_run_base(repo, ahead) is None and not os.path.exists(marker))
            # An https origin rewritten onto that file one by the repo's config.
            g('remote', 'set-url', 'origin', 'https://example.invalid/up.git')
            g('config', 'url.file://%s.insteadOf' % up, 'https://example.invalid/up.git')
            print('REWRITE', m._resolve_run_base(repo, ahead) is None and not os.path.exists(marker))
            # What the fetch is run with: network transports only, agentd's GIT_* left behind.
            seen = []
            real = subprocess.run
            def spy(args, **kw):
                if 'fetch' not in args: return real(args, **kw)
                seen.append((list(args), kw.get('env') or {}))
                return real(['true'])
            m.subprocess.run = spy
            os.environ['GIT_SSH_COMMAND'] = 'touch ' + marker
            m._resolve_run_base(repo, 'e' * 40)
            m.subprocess.run = real
            argv, env = seen[0]
            print('PROTOCOLS', env.get('GIT_ALLOW_PROTOCOL') == 'https:ssh')
            print('NO_AGENTD_GIT_ENV', env.get('GIT_SSH_COMMAND') == m._FETCH_SSH_COMMAND)
            print('PINNED_PACK', '--upload-pack=git-upload-pack' in argv)
            try:
                m._ws_run(['git', 'fetch'], git_protocols='file:https'); print('NO_FILE', False)
            except ValueError:
                print('NO_FILE', True)
            """, dir: dir)
        for key in ["FILE_ORIGIN", "REWRITE", "PROTOCOLS", "NO_AGENTD_GIT_ENV", "PINNED_PACK", "NO_FILE"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// Finding (CWE-670): "SSH origin fetch still runs /bin/false, so
    /// automation bases stay on HEAD". Every git call is hardened with
    /// core.sshCommand=/bin/false, so the base fetch from an ssh origin ran
    /// /bin/false and quietly exited 128.
    @Test("The base fetch from an ssh origin runs a config-less ssh, not /bin/false or the environment's",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func sshOriginFetch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            trace = d + '/trace'
            g('remote', 'add', 'origin', 'ssh://git@127.0.0.1:1/nope.git')   # refused at once
            os.environ['GIT_TRACE'] = trace
            # The fetch keeps only an allowlist of agentd's environment: let the trace through.
            m._GIT_NETWORK_ENV_KEEP = m._GIT_NETWORK_ENV_KEEP | {'GIT_TRACE'}
            os.environ['GIT_SSH_COMMAND'] = 'touch ' + d + '/hijacked'
            m._resolve_run_base(repo, 'f' * 40)
            t = open(trace).read() if os.path.exists(trace) else ''
            print('SSH', '/usr/bin/ssh -F /dev/null -o BatchMode=yes' in t)
            print('NOT_FALSE', '/bin/false' not in t)
            print('NOT_ENV', not os.path.exists(d + '/hijacked'))
            """, dir: dir)
        for key in ["SSH", "NOT_FALSE", "NOT_ENV"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// Finding (CWE-670): "A review whose base cannot be fetched is recorded
    /// as a successful launch" — the refusal now names its run.
    @Test("A run refused for its base names its slug in worktree-error.txt",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func refusalNamesRun() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            published = []
            m._atomic_publish = lambda tmp, name, text: published.append((name, text))
            m._resolve_run_base = lambda cwd, base: None
            m._automation_run(repo, 'review-dead', 'Review', 'claude', '', mode='review', base='d' * 40)
            name, text = published[-1]
            print('NAMED', name.startswith('worktree-error-') and name.endswith('.txt')
                  and text.startswith('run-slug: review-dead\\n'))
            # Outside a run, an error carries no slug (merge, pr, …).
            m.worktree_err('merge: conflicts')
            print('PLAIN', published[-1][1] == 'merge: conflicts')
            """, dir: dir)
        for key in ["NAMED", "PLAIN"] { #expect(out.contains("\(key) True"), Comment(rawValue: out)) }
    }

    /// Finding (CWE-362): "Concurrent guest refusals share one worktree-error
    /// file, so one run stays a finished review". Every refusal replaced one
    /// worktree-error.txt (through one shared temp name), so of two reviews
    /// refused together only one reached the host; the other stayed launched.
    @Test("Refusals published together each get their own file, whole",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func concurrentRefusalsEachLand() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            import threading
            outbox = d + '/outbox'; os.makedirs(outbox); m.OUTBOX = outbox
            go = threading.Barrier(8)
            def refuse(slug):
                m._RUN_CTX.slug = slug
                go.wait()
                for i in range(25):
                    m.worktree_err('base %s %d: cannot fetch origin' % (slug, i) + ' x' * 2000)
            ts = [threading.Thread(target=refuse, args=('review-%d' % n,)) for n in range(8)]
            for t in ts: t.start()
            for t in ts: t.join()
            names = [n for n in os.listdir(outbox) if not n.startswith('.')]
            bodies = [open(os.path.join(outbox, n)).read() for n in names]
            print('ALL', len(names) == 200 and all(n.startswith('worktree-error-') and n.endswith('.txt') for n in names))
            slugs = sorted(set(b.split('\\n', 1)[0] for b in bodies))
            print('SLUGS', slugs == sorted('run-slug: review-%d' % n for n in range(8)))
            print('WHOLE', all(b.split('\\n', 1)[1].startswith('base ' + b.split('\\n', 1)[0][10:] + ' ') for b in bodies))
            print('NO_TMP', not [n for n in os.listdir(outbox) if n.startswith('.')])
            m.docker_err('pull failed'); m.docker_err('pull failed again')
            print('DOCKER', len([n for n in os.listdir(outbox) if n.startswith('docker-error-')]) == 2)
            """, dir: dir)
        for key in ["ALL", "SLUGS", "WHOLE", "NO_TMP", "DOCKER"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
        // The host takes each of them (and a legacy single file), nothing else.
        #expect(UbuntuSandboxVM.isOneShot("worktree-error-1729-12-0.txt", stem: "worktree-error"))
        #expect(UbuntuSandboxVM.isOneShot("worktree-error.txt", stem: "worktree-error"))
        #expect(!UbuntuSandboxVM.isOneShot(".worktree-error.tmp.12.34", stem: "worktree-error"))
        #expect(!UbuntuSandboxVM.isOneShot("docker-errors.txt", stem: "docker-error"))
    }

    /// Finding (CWE-670): "SSH origin fetch has no agent socket, so
    /// automation bases stay on HEAD". The VM's only key is the host's,
    /// through agentd's ssh-agent bridge; SSH_AUTH_SOCK comes from proxy.env,
    /// which agentd (a systemd service) never sources.
    @Test("The base fetch carries the bridged agent socket, not whatever agentd's environment has",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func sshFetchHasAgentSocket() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            g('remote', 'add', 'origin', 'ssh://git@127.0.0.1:1/nope.git')
            seen = []
            real = subprocess.run
            def spy(args, **kw):
                if 'fetch' not in args: return real(args, **kw)
                seen.append(kw.get('env') or {})
                return real(['true'])
            m.subprocess.run = spy
            os.environ.pop('SSH_AUTH_SOCK', None)          # agentd's own environment
            m._resolve_run_base(repo, 'e' * 40)
            print('SOCK', bool(seen) and seen[0].get('SSH_AUTH_SOCK') == '/tmp/bromure-agent.sock')
            os.environ['SSH_AUTH_SOCK'] = d + '/elsewhere.sock'
            m._resolve_run_base(repo, 'e' * 40)
            print('NOT_ENV', seen[-1].get('SSH_AUTH_SOCK') == m.SSH_AGENT_UNIX_PATH)
            print('STILL_FIXED', seen[-1].get('GIT_SSH_COMMAND') == m._FETCH_SSH_COMMAND)
            """, dir: dir)
        for key in ["SOCK", "NOT_ENV", "STILL_FIXED"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }

    /// The same fetch inside a sandbox goes through the supervisor's exec:
    /// `_DEVNULL` used to be `os.dup`ed (EBADF) before the supervisor was
    /// asked, killing the automation thread. And the cooperative proxy's
    /// variables come from proxy.env, which agentd never sources.
    @Test("Sandboxed, the fetch reaches the supervisor with the agent socket and the proxy",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func sandboxedFetchReachesSupervisor() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try run(Self.setup + """
            meta = d + '/meta'; os.makedirs(meta)
            open(meta + '/proxy.env', 'w').write(
                'export HTTPS_PROXY=http://127.0.0.1:3128\\nexport NO_PROXY=localhost,127.0.0.1\\n'
                'export OPENAI_API_KEY=sk-not-for-git\\n'
                "export HTTPS_PROXY='http://127.0.0.1:3129'\\n")      # a profile's own, shell-quoted: it wins
            m.META = meta
            calls = []
            def fake_exec(argv, cwd=None, env=None, fds=(), pty=False, timeout=None):
                calls.append((list(argv), dict(env or {}), [os.fstat(f).st_mode for f in fds]))
                return {'ok': True, 'exit': 1}            # the commit isn't there
            m._sandbox_exec = fake_exec
            m._SANDBOX['control_socket'] = d + '/ctl.sock'
            os.environ.pop('SSH_AUTH_SOCK', None)
            try:
                m._resolve_run_base(repo, 'e' * 40)
                print('NO_CRASH', True)
            except OSError as e:
                print('NO_CRASH', False, e)
            fetch = [c for c in calls if 'fetch' in c[0]]
            env = fetch[0][1] if fetch else {}
            print('FETCHED', bool(fetch))
            print('SOCK', env.get('SSH_AUTH_SOCK') == '/tmp/bromure-agent.sock')
            print('PROXY', env.get('HTTPS_PROXY') == 'http://127.0.0.1:3129' and env.get('NO_PROXY') == 'localhost,127.0.0.1')
            print('ONLY_PROXY', 'OPENAI_API_KEY' not in env)
            print('FDS', bool(fetch) and len(fetch[0][2]) == 3)
            """, dir: dir)
        for key in ["NO_CRASH", "FETCHED", "SOCK", "PROXY", "ONLY_PROXY", "FDS"] {
            #expect(out.contains("\(key) True"), Comment(rawValue: out))
        }
    }
}
