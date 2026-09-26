import Foundation

// MARK: - Worktree sessions: status, merge, discard
//
// A session that branched off another (a git worktree) is a line of work
// with a branch of its own. The engine keeps an eye on what that branch
// holds (commits ahead of where it came from, uncommitted files), and does
// the things you do with a branch from the session itself — no tab to hunt
// for in the machine's list:
//
// - Merge: a clean branch merges straight into its parent's checkout. When
//   there's uncommitted work or a conflict, the merge is left clean and the
//   session's own agent is asked to finish it, in its own conversation, where
//   you can follow it. Either way the engine watches until the merge has
//   landed, then (by default) removes the checkout and the branch and puts
//   the session away.
// - Discard: the checkout and the branch go, with the session.
// - Keep: an archived branch session leaves its checkout alone, but the
//   machine stops reopening it at boot.

extension AgentSessionEngine {

    /// Quote a guest path for the shell.
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Status

    /// Refresh the branch facts of every worktree session on the running
    /// machines, at most every 20 s per machine: one guest command each.
    func probeBranches(entries: [SessionListModel.VMEntry]) {
        guard delegate != nil else { return }
        let now = Date()
        for entry in entries where entry.model.rosterLive {
            let mine = store.sessions.filter {
                $0.profileID == entry.id && $0.worktreeBranch != nil && !$0.isDeleted
                    && $0.branchMerge?.phase != .merged && !($0.isArchived && $0.branchInfo != nil)
            }
            guard !mine.isEmpty, !branchProbing.contains(entry.id),
                  now.timeIntervalSince(branchProbeAt[entry.id] ?? .distantPast) > 20 else { continue }
            branchProbing.insert(entry.id)
            branchProbeAt[entry.id] = now
            let pid = entry.id
            Task { [weak self] in
                await self?.probeBranchesNow(profileID: pid, sessions: mine)
                self?.branchProbing.remove(pid)
            }
        }
    }

    /// Ask the machine where these branch sessions stand, now.
    func probeBranchesNow(profileID: UUID, sessions: [AgentSession]) async {
        guard let delegate, !sessions.isEmpty else { return }
        // One line per session: id, then "gone", or
        // "ahead behind changed|root|parent".
        var script = ""
        for s in sessions {
            let dir = Self.q(ScheduledAutomationEngine.guestPath(s.cwd))
            let parent = s.branchParent.map(Self.q) ?? "''"
            script += "( printf '%s\\t' \(s.id.uuidString); cd \(dir) 2>/dev/null || { echo gone; exit; }; "
                + "r=$(git worktree list --porcelain 2>/dev/null | head -1 | cut -c10-); "
                + "p=\(parent); [ -n \"$p\" ] || p=$(git -C \"$r\" rev-parse --abbrev-ref HEAD 2>/dev/null); "
                + "a=$(git rev-list --count \"$p..HEAD\" 2>/dev/null || echo 0); "
                + "b=$(git rev-list --count \"HEAD..$p\" 2>/dev/null || echo 0); "
                + "c=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' '); "
                + "echo \"$a $b $c|$r|$p\" ); "
        }
        guard let out = try? await delegate.guestExec(profileID: profileID, command: script, timeout: 20) else { return }
        applyBranchProbe(out)
    }

    private func applyBranchProbe(_ out: String) {
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { continue }
            if parts[1] == "gone" { continue }   // the folder probe marks it missing
            let f = parts[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let n = f.first?.split(separator: " ").compactMap { Int($0) } ?? []
            guard n.count == 3 else { continue }
            let info = BranchInfo(ahead: n[0], behind: n[1], changed: n[2], checkedAt: Date())
            store.mutate(id) { s in
                // Only the counts decide equality; don't churn the store for a date.
                if s.branchInfo.map({ $0.ahead != info.ahead || $0.behind != info.behind || $0.changed != info.changed }) ?? true {
                    s.branchInfo = info
                }
                if f.count > 1, !f[1].isEmpty, s.branchRoot != f[1] { s.branchRoot = f[1] }
                if f.count > 2, !f[2].isEmpty, s.branchParent == nil { s.branchParent = f[2] }
            }
        }
    }

    /// Root and parent for a branch session, asking the machine when the
    /// tab never reported them.
    private func branchFacts(_ s: AgentSession) async -> (root: String, parent: String)? {
        if let r = s.branchRoot, let p = s.branchParent { return (r, p) }
        guard let delegate else { return nil }
        let dir = Self.q(ScheduledAutomationEngine.guestPath(s.cwd))
        let out = (try? await delegate.guestExec(
            profileID: s.profileID,
            command: "cd \(dir) 2>/dev/null && r=$(git worktree list --porcelain | head -1 | cut -c10-) "
                + "&& printf '%s|%s' \"$r\" \"$(git -C \"$r\" rev-parse --abbrev-ref HEAD)\"",
            timeout: 15)) ?? ""
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
        guard f.count == 2 else { return nil }
        let root = s.branchRoot ?? f[0], parent = s.branchParent ?? f[1]
        store.mutate(s.id) { $0.branchRoot = root; $0.branchParent = parent }
        return (root, parent)
    }

    // MARK: Merge

    /// Merge the session's branch into `target` (its parent by default).
    func mergeBranch(_ id: UUID, into target: String? = nil, squash: Bool = false, removeAfter: Bool = true) {
        guard let s = store.session(id), let branch = s.worktreeBranch, let delegate else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureUp(s.profileID, quietly: false, remotely: false),
                  let facts = await self.branchFacts(s) else {
                self.store.mutate(id) { $0.lastError = NSLocalizedString(
                    "Couldn't read the branch on its machine — is the machine running?", comment: "branch merge") }
                return
            }
            let into = target ?? facts.parent
            self.store.mutate(id) {
                $0.lastError = nil
                $0.branchMerge = BranchMerge(target: into, squash: squash, removeAfter: removeAfter,
                                             startedAt: Date(), phase: .merging,
                                             askedBy: $0.branchMerge?.askedBy)
            }
            BACDebug.log("sessions", "merge “\(s.title)” \(branch) → \(into)\(squash ? " (squash)" : "")")
            // The fast path: a clean branch merges on its own. Anything else
            // (uncommitted work, a conflict, a dirty target) goes back as it
            // was and the session's agent is asked to finish it.
            let root = Self.q(facts.root)
            let b = Self.q(branch), t = Self.q(into)
            let tdir = "t=$(git -C \(root) worktree list --porcelain | awk -v want=\"branch refs/heads/\"\(t) "
                + "'/^worktree /{w=substr($0,10)} $0==want{print w}'); [ -n \"$t\" ] || t=\(root); "
            let src = Self.q(ScheduledAutomationEngine.guestPath(s.cwd))
            // A machine with no git identity still gets its merge commit
            // (the same stand-in `git init` on the fly uses).
            let who = "who=; git -C \"$t\" config user.email >/dev/null || who='-c user.name=Bromure -c user.email=bromure@localhost'; "
            let mergeCmd = squash
                ? "git $who -C \"$t\" merge --squash \(b) >/dev/null 2>&1 && git $who -C \"$t\" commit -q -m \"Squash-merge \(branch)\" >/dev/null 2>&1"
                : "git $who -C \"$t\" merge --no-edit \(b) >/dev/null 2>&1"
            let script = tdir + who
                + "if [ \"$(git -C \"$t\" rev-parse --abbrev-ref HEAD 2>/dev/null)\" != \(t) ]; then echo elsewhere; "
                + "elif [ -n \"$(git -C \(src) status --porcelain 2>/dev/null)\" ]; then echo dirty; "
                + "elif \(mergeCmd); then echo merged; "
                + "else git -C \"$t\" merge --abort >/dev/null 2>&1; git -C \"$t\" reset -q --merge >/dev/null 2>&1; echo conflict; fi"
            let out = ((try? await delegate.guestExec(profileID: s.profileID, command: script, timeout: 60)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.hasSuffix("merged") {
                self.landed(id)
                return
            }
            // Hand it to the session's own agent.
            let why = out.hasSuffix("dirty")
                ? "This worktree has uncommitted changes."
                : out.hasSuffix("elsewhere")
                ? "'\(into)' isn't checked out anywhere, so it can't be merged into directly — check it out (in the main checkout, if that is free) first."
                : "Merging it straight away hit a conflict (or the target checkout has uncommitted changes)."
            let step = squash
                ? "`git -C \"$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0==\"branch refs/heads/\(into)\"{print w}')\" merge --squash \(branch)`, then commit it there as \"Squash-merge \(branch)\""
                : "`git merge --no-edit \(branch)` in the checkout of '\(into)' (`git worktree list` shows where it is)"
            let prompt = """
                The user asked to \(squash ? "squash-merge" : "merge") this branch ('\(branch)') into '\(into)'. \(why)
                1. Commit all the intended work on this branch with clear commit messages (leave out build artifacts and scratch files).
                2. Then run \(step).
                3. If it conflicts, resolve every conflicted file keeping both sides' intent, stage the resolutions and complete the merge commit.
                4. Reply with one line saying what landed in '\(into)'.
                If git has no identity configured here, commit with `git -c user.name=Bromure -c user.email=bromure@localhost` rather than stopping to ask.
                """
            self.store.mutate(id) { $0.branchMerge?.phase = .conflicts }
            self.resume(id, message: prompt)
            self.watchMerge(id)
        }
    }

    /// An agent asks to merge a branch (worktree_merge): it waits on the
    /// session for the user's yes.
    func requestMerge(_ id: UUID, into target: String?, squash: Bool, askedBy: UUID) async -> String? {
        guard let s = store.session(id), s.worktreeBranch != nil else { return "not a branch session" }
        if let p = s.branchMerge?.phase, p == .merging || p == .conflicts { return "a merge is already under way" }
        let into: String
        if let target { into = target }
        else if let facts = await branchFacts(s) { into = facts.parent }
        else { return "couldn't read the branch on its machine" }
        store.mutate(id) {
            $0.branchMerge = BranchMerge(target: into, squash: squash, removeAfter: true,
                                         startedAt: Date(), phase: .requested, askedBy: askedBy)
        }
        BACDebug.log("sessions", "agent asks to merge “\(s.title)” → \(into)")
        return nil
    }

    /// The user said no to a merge an agent asked for; the agent hears it.
    func declineMerge(_ id: UUID) {
        guard let s = store.session(id), let m = s.branchMerge, m.phase == .requested else { return }
        store.mutate(id) { $0.branchMerge = nil }
        let asker = m.askedBy.flatMap { store.session($0) } ?? s
        resume(asker.id, message: "The user declined merging '\(s.worktreeBranch ?? "")' into '\(m.target)' for now. Don't ask again unless they bring it up.")
    }

    /// Follow a merge the agent is finishing until it has landed (30 min).
    private func watchMerge(_ id: UUID) {
        guard !mergeWatching.contains(id), let delegate else { return }
        mergeWatching.insert(id)
        Task { [weak self] in
            defer { self?.mergeWatching.remove(id) }
            let deadline = Date().addingTimeInterval(30 * 60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let s = self.store.session(id), let m = s.branchMerge,
                      m.phase == .merging || m.phase == .conflicts,
                      let branch = s.worktreeBranch, let root = s.branchRoot else { return }
                let r = Self.q(root), b = Self.q(branch), t = Self.q(m.target)
                // Merged: the branch is in the target. Squashed: the target
                // holds everything the branch changed.
                let check = m.squash
                    ? "[ -z \"$(git -C \(r) diff \(t) \(b) -- 2>/dev/null)\" ] && echo merged"
                    : "git -C \(r) merge-base --is-ancestor \(b) \(t) 2>/dev/null && echo merged"
                let out = (try? await delegate.guestExec(profileID: s.profileID, command: check + "; true", timeout: 15)) ?? ""
                if out.contains("merged") {
                    self.landed(id)
                    return
                }
            }
            self?.store.mutate(id) {
                $0.branchMerge?.phase = .failed
                $0.branchMerge?.detail = NSLocalizedString(
                    "The merge hasn't landed after 30 minutes — ask the agent where it stands.", comment: "branch merge")
            }
        }
    }

    /// The branch is in: tidy up as asked.
    private func landed(_ id: UUID) {
        guard let s = store.session(id), let m = s.branchMerge else { return }
        BACDebug.log("sessions", "“\(s.title)” merged into \(m.target)")
        store.mutate(id) { $0.branchMerge?.phase = .merged; $0.branchInfo = nil }
        // Another session's agent asked for it: tell it it's in.
        if let asker = m.askedBy, asker != id, store.session(asker) != nil {
            resume(asker, message: "'\(s.worktreeBranch ?? "")' (session “\(s.title)”) is merged into '\(m.target)'.")
        }
        guard m.removeAfter, let branch = s.worktreeBranch, let root = s.branchRoot else { return }
        if s.windowIndex != nil { close(id) }
        // Its checkout goes: readable, nothing left to resume in.
        store.mutate(id) { $0.folderMissing = true }
        _ = delegate?.automationWorktreeCommand(profileNameOrID: s.profileID.uuidString,
                                                action: "remove", args: [root, branch])
        store.setArchived(id, true)
    }

    /// Resume a merge watch that was under way when the app quit.
    func resumeMergeWatches() {
        for s in store.sessions where s.branchMerge?.phase == .merging || s.branchMerge?.phase == .conflicts {
            watchMerge(s.id)
        }
    }

    // MARK: Discard / keep

    /// Throw the branch away: the checkout, the branch and the session.
    func discardBranch(_ id: UUID) {
        guard let s = store.session(id), let branch = s.worktreeBranch else { return }
        Task { [weak self] in
            guard let self else { return }
            let facts = await self.branchFacts(s)
            if s.windowIndex != nil { self.close(id) }
            if let root = facts?.root ?? s.branchRoot {
                _ = self.delegate?.automationWorktreeCommand(profileNameOrID: s.profileID.uuidString,
                                                             action: "remove", args: [root, branch])
            }
            BACDebug.log("sessions", "discard branch \(branch) of “\(s.title)”")
            self.delete(id)
        }
    }

    /// An archived branch session keeps its checkout, but the machine stops
    /// reopening it at boot (a resume opens it again).
    func keepBranchQuietly(_ id: UUID) {
        guard let s = store.session(id), let branch = s.worktreeBranch, let root = s.branchRoot else { return }
        _ = delegate?.automationWorktreeCommand(profileNameOrID: s.profileID.uuidString,
                                                action: "unregister", args: [root, branch])
    }

    // MARK: Pull request

    /// Ask the session's agent to open a pull request for its branch.
    func branchPullRequest(_ id: UUID, into target: String? = nil) {
        guard let s = store.session(id), let branch = s.worktreeBranch else { return }
        let into = target ?? s.branchParent ?? "main"
        resume(id, message: """
            Open a pull request for this branch ('\(branch)') into '\(into)':
            1. Review the changes and commit anything outstanding with clear messages.
            2. Push the branch: `git push -u origin \(branch)`.
            3. Create the PR with `gh pr create --base \(into)` — a concise title, and a body that explains what changed and why, and how it was tested.
            4. Reply with the PR's URL.
            """)
    }

    // MARK: Git on the fly

    /// What `cwd` is, git-wise: a repository (its branch, the local
    /// branches it could start from, what .worktreeinclude copies), one
    /// without a commit yet, or none. nil: the machine can't be asked.
    func gitState(profileID: UUID, cwd: String) async -> GitFolderState? {
        guard let delegate else { return nil }
        let dir = Self.q(ScheduledAutomationEngine.guestPath(cwd))
        let script = "cd \(dir) 2>/dev/null || exit; "
            + "if git rev-parse --show-toplevel >/dev/null 2>&1; then "
            + "if git rev-parse --verify -q HEAD >/dev/null; then echo \"repo $(git rev-parse --abbrev-ref HEAD 2>/dev/null)\"; else echo empty; fi; "
            + "echo ===BRANCHES===; git for-each-ref refs/heads --sort=-committerdate --format='%(refname:short)' 2>/dev/null | grep -v '^wt/' | head -30; "
            + "echo ===INCLUDE===; r=$(git worktree list --porcelain 2>/dev/null | head -1 | cut -c10-); "
            + "[ -f \"$r/.worktreeinclude\" ] && grep -v '^[[:space:]]*#' \"$r/.worktreeinclude\" | grep -v '^[[:space:]]*$' | head -20; "
            + "else echo none; fi; true"
        guard let out = try? await delegate.guestExec(profileID: profileID, command: script, timeout: 15) else { return nil }
        return GitFolderState.parse(out)
    }

    /// `git init` a folder and commit what's in it, so it can be branched.
    func initGitRepository(profileID: UUID, cwd: String) async -> Bool {
        guard let delegate else { return false }
        let dir = Self.q(ScheduledAutomationEngine.guestPath(cwd))
        let out = (try? await delegate.guestExec(
            profileID: profileID,
            command: "cd \(dir) && git init -q && git add -A && "
                + "( git commit -q -m 'Initial commit' 2>/dev/null || "
                + "git -c user.name=Bromure -c user.email=bromure@localhost commit -q --allow-empty -m 'Initial commit' ) "
                + "&& git rev-parse --verify -q HEAD >/dev/null && echo ok",
            timeout: 60)) ?? ""
        BACDebug.log("sessions", "git init \(cwd): \(out.contains("ok") ? "ok" : "failed")")
        return out.contains("ok")
    }
}

// MARK: - Review
//
// The review window's record on the session: comments (drafts until sent,
// then kept as sent) and which files were looked at. Sending hands every
// draft to the session's agent as one message — live or asleep.

extension AgentSessionEngine {

    /// The session's changes against `base`, read live from its machine.
    func fetchReview(_ id: UUID, base: TaskReviewData.Base) async -> TaskReviewData? {
        guard let s = store.session(id), let delegate else { return nil }
        let cmd = TaskReviewData.sessionCommand(dir: ScheduledAutomationEngine.guestPath(s.cwd), base: base)
        guard let out = try? await delegate.guestExec(profileID: s.profileID, command: cmd, timeout: 30)
        else { return nil }
        return TaskReviewData.parse(out)
    }

    func addReviewComment(_ id: UUID, text: String, file: String?, line: Int?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.mutate(id) { $0.reviewComments = ($0.reviewComments ?? []) + [ReviewComment(text: t, file: file, line: line)] }
    }

    func removeReviewComment(_ id: UUID, commentID: UUID) {
        store.mutate(id) { s in
            s.reviewComments?.removeAll { $0.id == commentID }
            if s.reviewComments?.isEmpty == true { s.reviewComments = nil }
        }
    }

    /// Mark a file viewed at this state of its diff (nil fingerprint = not
    /// viewed).
    func setReviewViewed(_ id: UUID, path: String, fingerprint: String?) {
        store.mutate(id) { s in
            var v = s.reviewViewed ?? [:]
            v[path] = fingerprint
            s.reviewViewed = v.isEmpty ? nil : v
        }
    }

    /// Send every draft comment to the agent as one message. Returns how
    /// many went.
    @discardableResult
    func sendReview(_ id: UUID) -> Int {
        guard let s = store.session(id) else { return 0 }
        let drafts = (s.reviewComments ?? []).filter { $0.sentAt == nil }
        guard !drafts.isEmpty else { return 0 }
        resume(id, message: Self.reviewMessage(drafts))
        let now = Date(), ids = Set(drafts.map(\.id))
        store.mutate(id) { s in
            s.reviewComments = s.reviewComments?.map { c in
                var c = c
                if ids.contains(c.id) { c.sentAt = now }
                return c
            }
        }
        BACDebug.log("sessions", "review: \(drafts.count) comment(s) sent to “\(s.title)”")
        return drafts.count
    }

    /// "Review comments on your changes: …" — numbered, each with where it
    /// points.
    nonisolated static func reviewMessage(_ comments: [ReviewComment]) -> String {
        var lines = [comments.count == 1
            ? "A review comment on your changes — address it, then reply briefly with what you changed:"
            : "Review comments on your changes — address each one, then reply briefly with what you changed:"]
        lines.append("")
        for (i, c) in comments.enumerated() {
            let at: String
            switch (c.file, c.line) {
            case let (f?, l?): at = "`\(f)` line \(l): "
            case let (f?, nil): at = "`\(f)`: "
            default: at = ""
            }
            lines.append("\(i + 1). \(at)\(c.text)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Branches left behind

extension AgentSessionEngine {

    /// Every worktree Bromure made on the machine. nil: it can't be asked.
    func listWorktrees(profileID: UUID) async -> [WorktreeEntry]? {
        guard let delegate,
              let out = try? await delegate.guestExec(profileID: profileID, command: WorktreeEntry.guestCommand, timeout: 30)
        else { return nil }
        return WorktreeEntry.parse(out)
    }

    /// Pick a branch nobody looks after up in a new session: its agent in
    /// its checkout, known as a branch (merge, review, discard all work).
    @discardableResult
    func openBranchSession(profileID: UUID, entry: WorktreeEntry, tool: Profile.Tool, remotely: Bool = false) -> UUID {
        let title = entry.display.isEmpty ? entry.branch : entry.display
        let id = start(.init(profileID: profileID, tool: tool, cwd: entry.dir, title: title), remotely: remotely)
        store.mutate(id) {
            $0.worktreeBranch = entry.branch
            $0.branchParent = entry.parent.isEmpty ? nil : entry.parent
            $0.branchRoot = entry.root.isEmpty ? nil : entry.root
        }
        BACDebug.log("sessions", "picked up \(entry.branch) in a new session")
        return id
    }

    /// Remove a worktree's checkout and branch — with its session, if any.
    func discardWorktree(profileID: UUID, entry: WorktreeEntry, session: UUID?) {
        if let session, store.session(session) != nil {
            discardBranch(session)
            return
        }
        _ = delegate?.automationWorktreeCommand(profileNameOrID: profileID.uuidString,
                                                action: "remove", args: [entry.root, entry.branch])
        BACDebug.log("sessions", "discarded left-behind \(entry.branch)")
    }
}
