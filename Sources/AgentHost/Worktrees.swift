import Foundation

/// Git branches for native sessions — the same shape bromure-agentd gives a
/// VM's: a worktree at ~/.bromure/worktrees/<repo>/<slug> on branch
/// wt/<slug> (made unique with -2, -3…), the repo's .worktreeinclude copied
/// in, the agent started there in a tmux window tagged @worktree /
/// @parent_branch / @root_repo. The session records carry what Bromure AC's
/// branch UI reads (worktreeOf, worktreeBranch, branchParent, branchRoot,
/// branchInfo, branchMerge); merges follow AgentSessionEngine's (SessionBranches
/// .swift): a clean branch merges on its own, anything else goes back to the
/// session's agent, and a watch notices when it has landed.
enum Worktrees {
    // MARK: Git

    /// A git/shell step in `dir`; stdout trimmed, nil on failure.
    @discardableResult
    static func sh(_ script: String, in dir: String? = nil, timeout: TimeInterval = 60) -> String? {
        let r = HostProcess.run(executable: "/bin/bash", args: ["-c", script],
                                env: HostEnvironment.forCommands(), cwd: dir, timeout: timeout)
        guard r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func q(_ s: String) -> String { shellQuote(s) }

    /// The folder's repository state, as GitFolderState.json has it (the new
    /// branch sheet): repo on which branch, the branches to start from, what
    /// .worktreeinclude copies.
    static func folderState(_ dir: String) -> [String: Any] {
        guard let top = sh("git -C \(q(dir)) rev-parse --show-toplevel 2>/dev/null"), !top.isEmpty else {
            return ["kind": "notRepo", "repo": false, "branches": [], "includes": []]
        }
        guard sh("git -C \(q(dir)) rev-parse --verify -q HEAD") != nil else {
            return ["kind": "noCommits", "repo": false, "branches": [], "includes": []]
        }
        let branch = sh("git -C \(q(dir)) rev-parse --abbrev-ref HEAD") ?? ""
        let branches = (sh("git -C \(q(dir)) for-each-ref refs/heads --sort=-committerdate --format='%(refname:short)'") ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("wt/") }
        let includes = ((try? String(contentsOfFile: top + "/.worktreeinclude", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var o: [String: Any] = ["kind": "repo", "repo": true, "branches": branches, "includes": includes]
        if !branch.isEmpty && branch != "HEAD" { o["branch"] = branch }
        return o
    }

    /// AgentSession.worktreeSlug.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let t = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return t.isEmpty ? "worktree" : t
    }

    struct Made {
        var dir: String
        var branch: String
        var parent: String
        var root: String
    }

    /// Make the checkout (bromure-agentd's `_worktree_create`, git part).
    static func make(from dir: String, name: String, initGit: Bool, base: String?,
                     tool: String = "claude") -> Result<Made, HostError> {
        let d = q(dir)
        if sh("git -C \(d) rev-parse --show-toplevel 2>/dev/null")?.isEmpty ?? true {
            guard initGit else { return .failure(.bad("\(dir) isn't a git repository")) }
            let who = "-c user.name=Bromure -c user.email=bromure@localhost"
            guard sh("cd \(d) && git init -q && git add -A && (git commit -q -m 'Initial commit' || git \(who) commit -q --allow-empty -m 'Initial commit')") != nil else {
                return .failure(.failed("Couldn't make \(dir) a git repository"))
            }
        }
        if sh("git -C \(d) rev-parse --verify -q HEAD") == nil {
            // A repository with no commit can't branch: give it a root commit.
            sh("git -C \(d) commit -q --allow-empty -m 'Initial commit' || git -c user.name=Bromure -c user.email=bromure@localhost -C \(d) commit -q --allow-empty -m 'Initial commit'")
        }
        var parent = sh("git -C \(d) rev-parse --abbrev-ref HEAD") ?? "HEAD"
        if parent == "HEAD" { parent = sh("git -C \(d) rev-parse --short HEAD") ?? "HEAD" }
        let root = (sh("git -C \(d) worktree list --porcelain") ?? "").split(separator: "\n")
            .first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) } ?? dir
        var start = parent
        if let base, !base.isEmpty {
            guard sh("git -C \(d) rev-parse --verify --quiet \(q(base + "^{commit}"))") != nil else {
                return .failure(.bad("No branch or commit “\(base)” to start from"))
            }
            start = base
            parent = base
        }
        let s = slug(name)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let repoDir = home.appendingPathComponent(".bromure/worktrees/\((root as NSString).lastPathComponent)")
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        var suffix = ""
        var n = 1
        while true {
            let branch = "wt/\(s)\(suffix)"
            let wt = repoDir.appendingPathComponent(s + suffix).path
            let taken = sh("git -C \(d) show-ref --verify --quiet \(q("refs/heads/" + branch))") != nil
                || FileManager.default.fileExists(atPath: wt)
            if !taken {
                guard sh("git -C \(d) worktree add -q -b \(q(branch)) \(q(wt)) \(q(start)) 2>&1") != nil else {
                    return .failure(.failed("git couldn't create the worktree"))
                }
                copyIncludes(root: root, into: wt)
                registryAdd(repoDir, branch: branch, parent: parent, display: name, tool: tool)
                return .success(Made(dir: wt, branch: branch, parent: parent, root: root))
            }
            n += 1
            suffix = "-\(n)"
            if n > 50 { return .failure(.failed("Too many worktrees named \(s)")) }
        }
    }

    /// The repo's .worktreeinclude: gitignored files agents need (.env…).
    private static func copyIncludes(root: String, into wt: String) {
        guard let list = try? String(contentsOfFile: root + "/.worktreeinclude", encoding: .utf8) else { return }
        for pat in list.split(separator: "\n").map(String.init) where !pat.isEmpty && !pat.hasPrefix("#") {
            let src = root + "/" + pat, dst = wt + "/" + pat
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst) else { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            sh("cp -a \(q(src)) \(q(dst))")
        }
    }

    /// Remove the checkout and the branch (agentd's `_worktree_remove`).
    static func remove(root: String, branch: String) {
        let r = q(root)
        let dir = (sh("git -C \(r) worktree list --porcelain") ?? "")
            .components(separatedBy: "\n\n").first { $0.contains("branch refs/heads/\(branch)") }?
            .split(separator: "\n").first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        if let dir { sh("git -C \(r) worktree remove --force \(q(dir))") }
        sh("git -C \(r) branch -D \(q(branch))")
        sh("git -C \(r) worktree prune")
        registryDel(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".bromure/worktrees/\((root as NSString).lastPathComponent)"), branch: branch)
    }

    // MARK: Registry

    /// `<repo>/.registry` (agentd's): branch, parent, display, tool — 0x1f
    /// separated, one per line. The Branches window reads parent and display.
    private static let us = "\u{1f}"

    private static func registryAdd(_ repoDir: URL, branch: String, parent: String, display: String, tool: String) {
        let clean = { (v: String) in v.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: us, with: " ") }
        let line = [branch, parent, display, tool].map(clean).joined(separator: us) + "\n"
        let reg = repoDir.appendingPathComponent(".registry")
        if let h = FileHandle(forWritingAtPath: reg.path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: reg, atomically: true, encoding: .utf8)
        }
    }

    private static func registryDel(_ repoDir: URL, branch: String) {
        let reg = repoDir.appendingPathComponent(".registry")
        guard let text = try? String(contentsOf: reg, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").filter {
            let b = $0.components(separatedBy: us).first ?? ""
            return !b.isEmpty && b != branch
        }
        try? (kept.map { $0 + "\n" }.joined()).write(to: reg, atomically: true, encoding: .utf8)
    }

    // MARK: Status

    /// ahead / behind the parent, uncommitted files (SessionBranches'
    /// probe); nil when the checkout is gone.
    static func probe(dir: String, parent: String?) -> (info: [String: Any], root: String, parent: String)? {
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let script = "cd \(q(dir)) || exit 1; r=$(git worktree list --porcelain | head -1 | cut -c10-); "
            + "p=\(q(parent ?? "")); [ -n \"$p\" ] || p=$(git -C \"$r\" rev-parse --abbrev-ref HEAD); "
            + "a=$(git rev-list --count \"$p..HEAD\" 2>/dev/null || echo 0); "
            + "b=$(git rev-list --count \"HEAD..$p\" 2>/dev/null || echo 0); "
            + "c=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' '); echo \"$a $b $c|$r|$p\""
        guard let out = sh(script) else { return nil }
        let f = out.split(separator: "|").map(String.init)
        guard f.count == 3 else { return nil }
        let n = f[0].split(separator: " ").map { Int($0) ?? 0 }
        guard n.count == 3 else { return nil }
        let iso = ISO8601DateFormatter().string(from: Date())
        return (["ahead": n[0], "behind": n[1], "changed": n[2], "checkedAt": iso], f[1], f[2])
    }

    // MARK: Merge

    enum MergeOutcome { case merged, dirty, elsewhere, conflict }

    /// The fast path: a clean branch merges on its own (SessionBranches'
    /// mergeBranch script, run here).
    static func tryMerge(root: String, branch: String, into target: String, source dir: String,
                         squash: Bool) -> MergeOutcome {
        let r = q(root), b = q(branch), t = q(target)
        let tdir = "t=$(git -C \(r) worktree list --porcelain | awk -v want=\"branch refs/heads/\"\(t) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w}'); [ -n \"$t\" ] || t=\(r); "
        let who = "who=; git -C \"$t\" config user.email >/dev/null || who='-c user.name=Bromure -c user.email=bromure@localhost'; "
        let mergeCmd = squash
            ? "git $who -C \"$t\" merge --squash \(b) >/dev/null 2>&1 && git $who -C \"$t\" commit -q -m \"Squash-merge \(branch)\" >/dev/null 2>&1"
            : "git $who -C \"$t\" merge --no-edit \(b) >/dev/null 2>&1"
        let script = tdir + who
            + "if [ \"$(git -C \"$t\" rev-parse --abbrev-ref HEAD 2>/dev/null)\" != \(t) ]; then echo elsewhere; "
            + "elif [ -n \"$(git -C \(q(dir)) status --porcelain 2>/dev/null)\" ]; then echo dirty; "
            + "elif \(mergeCmd); then echo merged; "
            + "else git -C \"$t\" merge --abort >/dev/null 2>&1; git -C \"$t\" reset -q --merge >/dev/null 2>&1; echo conflict; fi"
        switch sh(script) ?? "" {
        case let o where o.hasSuffix("merged"): return .merged
        case let o where o.hasSuffix("dirty"): return .dirty
        case let o where o.hasSuffix("elsewhere"): return .elsewhere
        default: return .conflict
        }
    }

    /// Has the branch landed in the target (a merge, or a squash's content)?
    static func landed(root: String, branch: String, target: String, squash: Bool) -> Bool {
        let r = q(root), b = q(branch), t = q(target)
        let check = squash
            ? "[ -z \"$(git -C \(r) diff \(t) \(b) -- 2>/dev/null)\" ] && echo merged"
            : "git -C \(r) merge-base --is-ancestor \(b) \(t) 2>/dev/null && echo merged"
        return (sh(check + "; true") ?? "").contains("merged")
    }

    /// What the session's agent is told when the merge needs it (the same
    /// words bromure-ac uses for a VM's branch).
    static func mergePrompt(branch: String, into: String, squash: Bool, why outcome: MergeOutcome) -> String {
        let why: String
        switch outcome {
        case .dirty: why = "This worktree has uncommitted changes."
        case .elsewhere: why = "'\(into)' isn't checked out anywhere, so it can't be merged into directly — check it out (in the main checkout, if that is free) first."
        default: why = "Merging it straight away hit a conflict (or the target checkout has uncommitted changes)."
        }
        let step = squash
            ? "`git -C \"$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0==\"branch refs/heads/\(into)\"{print w}')\" merge --squash \(branch)`, then commit it there as \"Squash-merge \(branch)\""
            : "`git merge --no-edit \(branch)` in the checkout of '\(into)' (`git worktree list` shows where it is)"
        return """
            The user asked to \(squash ? "squash-merge" : "merge") this branch ('\(branch)') into '\(into)'. \(why)
            1. Commit all the intended work on this branch with clear commit messages (leave out build artifacts and scratch files).
            2. Then run \(step).
            3. If it conflicts, resolve every conflicted file keeping both sides' intent, stage the resolutions and complete the merge commit.
            4. Reply with one line saying what landed in '\(into)'.
            If git has no identity configured here, commit with `git -c user.name=Bromure -c user.email=bromure@localhost` rather than stopping to ask.
            """
    }

    static func pullRequestPrompt(branch: String, into: String) -> String {
        """
        Open a pull request for this branch ('\(branch)') into '\(into)':
        1. Review the changes and commit anything outstanding with clear messages.
        2. Push the branch: `git push -u origin \(branch)`.
        3. Create the PR with `gh pr create --base \(into)` — a concise title, and a body that explains what changed and why, and how it was tested.
        4. Reply with the PR's URL.
        """
    }
}
