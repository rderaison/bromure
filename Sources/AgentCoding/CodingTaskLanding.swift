import Foundation

// MARK: - Landing an approved task ("Land it")
//
// Review → Done. The user approves a task (Merge into <target>, or Open
// Pull Request) and Bromure lands it:
//
// - Fast path: a branch strictly ahead of its target, with nothing left
//   uncommitted, is fast-forwarded by Bromure itself — in the checkout where
//   the target is checked out, or straight on the ref when the target isn't
//   checked out anywhere. Never into some other branch's checkout.
// - Otherwise the agent that wrote the change lands it, in its own session
//   (typed into its live tab, or its conversation resumed): commit leftovers,
//   rebase onto the target, run the project's quick checks, fast-forward the
//   target, report with `board_report_landing`. A delegated task's assignee
//   is steered the same way and reports with `deliver`.
// - Bromure verifies in git before the card goes Done; a report it can't
//   check (a machine it can't reach) is recorded as "reported, not
//   verified". A landing that stalls (20 min) or stops comes back as
//   "Needs you" with the reason.

/// What the fast-path probe found.
enum LandingCheck: Equatable, Sendable {
    /// The branch adds nothing the target lacks — already in.
    case merged
    /// Bromure fast-forwarded the target just now.
    case mergedNow
    /// The branch's checkout has uncommitted work — the agent commits it.
    case dirtySource
    /// The target moved on (or a squash wants one commit) — the agent rebases.
    case diverged
    /// The target's checkout has uncommitted changes in the way.
    case dirtyTarget
    case noTarget
    case noBranch
    /// The machine answered nothing usable.
    case failed
}

/// What a landing leaves for an agent: its branch, target and repository.
struct LandingHandOff: Sendable {
    let taskID: UUID
    let branch: String
    let target: String
    let root: String
    /// Merged here already; only the push is left.
    let pushedLocally: Bool
}

/// What a look at the repository found for a landing.
enum LandingVerification: Equatable, Sendable {
    /// In the target (and in `<remote>/<target>` for a pushing one).
    case landed
    /// Looked: not there (yet), or its checkout still has changes.
    case pending
    /// A pushing landing whose remote couldn't be fetched (offline, bad
    /// credentials, a dead URL): whether it's pushed is unknown, whatever
    /// the local merge says.
    case remoteUnreachable
    /// The machine couldn't be asked.
    case unknown

    /// The verify command's output.
    static func parse(_ out: String?) -> LandingVerification {
        guard let out else { return .unknown }
        if out.contains("NOREMOTE") { return .remoteUnreachable }
        if out.contains("LANDED") { return .landed }
        if out.contains("PENDING") { return .pending }
        return .unknown
    }
}

/// What a `board_report_landing` (or a delegated delivery) leads to.
enum LandingReportOutcome: Equatable, Sendable {
    /// Bromure saw it in the target: Done, verified.
    case finishVerified
    /// Bromure couldn't look: Done, "reported by <agent>, not verified".
    case finishUnverified
    /// Bromure looked and it isn't there: the agent is told to finish.
    case notYet
    /// A pushing landing whose remote couldn't be fetched: the push can't
    /// be checked — the user looks (the branch is kept), never Done on
    /// the agent's word.
    case remoteUnchecked
    case prOpened(String?)
    case blocked(String)
    case invalid(String)

    /// `verified`: true = in the target, false = looked and not there,
    /// nil = couldn't look.
    static func decide(status: String, summary: String, prURL: String?,
                       verified: Bool?) -> LandingReportOutcome {
        decide(status: status, summary: summary, prURL: prURL,
               verification: verified.map { $0 ? .landed : .pending } ?? .unknown)
    }

    static func decide(status: String, summary: String, prURL: String?,
                       verification: LandingVerification) -> LandingReportOutcome {
        switch status {
        case "merged":
            switch verification {
            case .landed: return .finishVerified
            case .pending: return .notYet
            case .remoteUnreachable: return .remoteUnchecked
            case .unknown: return .finishUnverified
            }
        case "pr_opened":
            return .prOpened(prURL ?? CodingTask.pullRequestURL(in: summary))
        case "blocked":
            let why = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return .blocked(why.isEmpty ? NSLocalizedString("The agent couldn't land it.", comment: "task landing") : why)
        default:
            return .invalid("status must be merged, pr_opened or blocked")
        }
    }
}

#if os(macOS)
extension CodingTaskEngine {

    // MARK: Guest commands and prompts (pure)

    private nonisolated static func q(_ s: String) -> String { shellQuote(s) }

    // MARK: Remotes

    /// A remote name safe to hand git and an agent: one plain token, never
    /// an option. Quoting stops the shell, not git — a remote named
    /// `--exec=./pwn.sh` (whatever `.git/config` lists first: a copied
    /// worktree, a zip with its .git, the agent itself) ran that program
    /// on Merge & Push.
    nonisolated static func isSafeRemoteName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
            && !s.contains("..") && !s.hasSuffix("/")
    }

    /// `remote` when it is safe, else nil.
    nonisolated static func safeRemote(_ remote: String?) -> String? {
        remote.flatMap { isSafeRemoteName($0) ? $0 : nil }
    }

    /// The shell that prints the remote a landing pushes to: "origin" when
    /// the repo has one, else its first remote with a safe name — nothing
    /// when none (an unsafe name is never picked). `repo`: shell-quoted.
    /// The Swift twin is `pickRemote`.
    nonisolated static func pickRemoteShell(repo: String) -> String {
        "git -C \(repo) remote 2>/dev/null | awk "
            + #"'/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/ && !/\.\./ && !/\/$/ { if ($0 == "origin") o = 1; else if (f == "") f = $0 } "#
            + #"END { if (o) print "origin"; else if (f != "") print f }'"#
    }

    /// `git remote`'s listing → the remote a landing pushes to.
    nonisolated static func pickRemote(_ listing: String) -> String? {
        let names = listing.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter(isSafeRemoteName)
        return names.contains("origin") ? "origin" : names.first
    }

    /// The fast-path probe — and, when the branch is strictly ahead of the
    /// target with a clean checkout, the fast-forward itself. Prints one
    /// word (see `parseLandingCheck`). Squash and pull-request landings
    /// never fast-forward here (a squash wants one commit; a PR is the
    /// agent's) — except a squash of a single commit, which IS a ff.
    nonisolated static func landingCheckCommand(root: String, branch: String, target: String,
                                                sourceDir: String?, mode: TaskLanding.Mode) -> String {
        var cmd = "r=\(q(root)); "
            + "git -C \"$r\" rev-parse -q --verify \(q("refs/heads/" + target)) >/dev/null 2>&1 || { echo no-target; exit 0; }; "
            + "git -C \"$r\" rev-parse -q --verify \(q("refs/heads/" + branch)) >/dev/null 2>&1 || { echo no-branch; exit 0; }; "
        if let src = sourceDir, !src.isEmpty {
            cmd += "if [ -d \(q(src)) ] && [ -n \"$(\(TaskLitter.status(q(src))))\" ]; then echo dirty-source; exit 0; fi; "
        }
        cmd += "a=$(git -C \"$r\" rev-list --count \(q(target + ".." + branch)) 2>/dev/null) || { echo failed; exit 0; }; "
            + "b=$(git -C \"$r\" rev-list --count \(q(branch + ".." + target)) 2>/dev/null) || { echo failed; exit 0; }; "
            + "if [ \"$a\" = 0 ]; then echo merged; exit 0; fi; "
            + "if [ \"$b\" != 0 ]; then echo diverged; exit 0; fi; "
        switch mode {
        case .pr: return cmd + "echo diverged"
        case .squash: cmd += "if [ \"$a\" != 1 ]; then echo diverged; exit 0; fi; "
        case .merge: break
        }
        // Strictly ahead: fast-forward where the target is checked out —
        // `--ff-only` leaves the checkout's uncommitted changes alone, and
        // refuses when they're in the way. Not checked out anywhere: move
        // the ref itself (a fetch into a branch refuses a non-ff update).
        return cmd
            + "d=$(git -C \"$r\" worktree list --porcelain 2>/dev/null | awk -v want=\(q("branch refs/heads/" + target)) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w; exit}'); "
            + "if [ -n \"$d\" ]; then git -C \"$d\" merge --ff-only -q \(q(branch)) >/dev/null 2>&1 && echo merged-now || echo dirty-target; "
            + "else git -C \"$r\" fetch -q . \(q(branch + ":" + target)) >/dev/null 2>&1 && echo merged-now || echo failed; fi"
    }

    nonisolated static func parseLandingCheck(_ out: String?) -> LandingCheck {
        let word = (out ?? "").split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch word {
        case "merged": return .merged
        case "merged-now": return .mergedNow
        case "dirty-source": return .dirtySource
        case "diverged": return .diverged
        case "dirty-target": return .dirtyTarget
        case "no-target": return .noTarget
        case "no-branch": return .noBranch
        default: return .failed
        }
    }

    /// Prints LANDED when the branch's work is in the target: its checkout
    /// clean, and the branch an ancestor of the target (a merge, a ff) or
    /// the two trees equal (a squash).
    /// `remote`: a pushing landing — the work must be in `<remote>/<target>`
    /// too (fetched first).
    nonisolated static func landingVerifyCommand(root: String, branch: String, target: String,
                                                 sourceDir: String?, remote: String? = nil) -> String {
        var cmd = ""
        if let src = sourceDir, !src.isEmpty {
            cmd += "if [ -d \(q(src)) ] && [ -n \"$(\(TaskLitter.status(q(src))))\" ]; then echo PENDING; exit 0; fi; "
        }
        func inRef(_ t: String) -> String {
            "{ git -C \(q(root)) merge-base --is-ancestor \(q(branch)) \(q(t)) 2>/dev/null "
                + "|| git -C \(q(root)) diff --quiet \(q(t)) \(q(branch)) -- 2>/dev/null; }"
        }
        let local = inRef(target)
        guard let remote, !remote.isEmpty else {
            return cmd + "if \(local); then echo LANDED; else echo PENDING; fi"
        }
        // A remote that isn't a plain name is never fetched — and the push
        // can't be checked, so it's never LANDED either.
        guard isSafeRemoteName(remote) else { return "echo NOREMOTE" }
        // A fetch that fails says so (NOREMOTE) and the local merge is
        // still looked at — but it is never LANDED: unchecked isn't pushed.
        // Bailing out as "unknown" here let the agent's "merged" finish the
        // task, and its cleanup delete the branch.
        cmd += "if GIT_TERMINAL_PROMPT=0 git -C \(q(root)) fetch -q -- \(q(remote)) >/dev/null 2>&1; then "
            + "if \(local) && \(inRef("refs/remotes/\(remote)/\(target)")); then echo LANDED; else echo PENDING; fi; "
            + "else echo NOREMOTE; if \(local); then echo INLOCAL; else echo PENDING; fi; fi"
        return cmd
    }

    /// After a local merge: push `target` to `remote` when that's a plain
    /// fast-forward of what the remote has. Prints one word — `pushed`,
    /// `behind` (the remote moved on: the agent pulls and merges first),
    /// `push-failed` or `fetch-failed` (the agent looks into it).
    nonisolated static func pushTargetCommand(root: String, target: String, remote: String) -> String {
        guard isSafeRemoteName(remote) else { return "echo push-failed" }
        let tracking = "refs/remotes/\(remote)/\(target)"
        return "r=\(q(root)); export GIT_TERMINAL_PROMPT=0; "
            + "git -C \"$r\" fetch -q -- \(q(remote)) >/dev/null 2>&1 || { echo fetch-failed; exit 0; }; "
            + "if git -C \"$r\" rev-parse -q --verify \(q(tracking)) >/dev/null 2>&1 "
            + "&& ! git -C \"$r\" merge-base --is-ancestor \(q(tracking)) \(q("refs/heads/" + target)) 2>/dev/null; "
            + "then echo behind; exit 0; fi; "
            + "git -C \"$r\" push -q -- \(q(remote)) \(q("refs/heads/\(target):refs/heads/\(target)")) >/dev/null 2>&1 "
            + "&& echo pushed || echo push-failed"
    }

    /// The brief when the branch is merged locally but pushing the target
    /// needs an agent: the remote moved on (pull, merge, fix conflicts) or
    /// git refused.
    nonisolated static func pushPrompt(branch: String, target: String, remote: String,
                                       viaBoard: Bool) -> String {
        // The names go into commands the agent runs: quoted, and only a
        // safe remote (finding: an unchecked one was a command line).
        let rm = safeRemote(remote) ?? "origin"
        let (qr, qt) = (q(rm), q(target))
        let report = viaBoard
            ? "Call the board_report_landing tool with status \"merged\" and a one-line summary once '\(rm)/\(target)' has it. If you can't push it, don't force anything: call board_report_landing with status \"blocked\" and the reason."
            : "Call `deliver` with one line saying it's pushed to '\(rm)/\(target)'. If you can't push it, don't force anything: `ask`, saying what's in the way."
        return """
            The user approved this task and '\(branch)' is merged into '\(target)' locally — now push '\(target)' to '\(rm)'. Do it yourself, in this session:
            1. `git fetch \(qr)`.
            2. In the checkout where '\(target)' is checked out (`git worktree list` shows it; if it isn't checked out anywhere, check it out in a scratch worktree), bring in what '\(rm)/\(target)' has: `git pull --rebase \(qr) \(qt)`. Resolve every conflict keeping both sides' intent — never drop the other side's changes. Never touch, stash or discard uncommitted changes in that checkout — if git refuses because of them, stop and report blocked.
            3. If the project has quick checks (tests, a build, a linter), run them and fix what the merge broke. Don't go fixing unrelated failures.
            4. Push: `git push \(qr) \(qt)`. Never force-push '\(target)'. If it's rejected because '\(rm)' moved again, repeat from step 1.
            5. \(report)
            If git has no identity configured, commit with `git -c user.name=Bromure -c user.email=bromure@localhost commit …` rather than stopping to ask.
            """
    }

    /// The landing brief, typed into (or resumed with) the session of the
    /// agent that wrote the change. `viaBoard`: the session has the board
    /// MCP (a new-agent task); otherwise it's a delegated session that
    /// reports with `deliver` / `ask`.
    nonisolated static func landingPrompt(mode: TaskLanding.Mode, branch: String, target: String,
                                          rootRepo: String, title: String, remote: String?,
                                          viaBoard: Bool, push: Bool = false) -> String {
        // Every name the agent's commands carry is quoted; the remote is
        // a safe one or the default.
        let rm = safeRemote(remote)
        let (qb, qt) = (q(branch), q(target))
        let identity = "If git has no identity configured, commit with "
            + "`git -c user.name=Bromure -c user.email=bromure@localhost commit …` rather than stopping to ask."
        let commit = "Commit anything still uncommitted on '\(branch)' with clear messages "
            + "(leave out build artifacts and scratch files)."
        let rebase = "Rebase onto the latest '\(target)': `git rebase \(qt)`. Resolve every conflict "
            + "keeping both sides' intent — never drop the other side's changes."
        let checks = "If the project has quick checks (tests, a build, a linter), run them and fix "
            + "what your change broke. Don't go fixing unrelated failures."
        if mode == .pr {
            let r = rm ?? "origin"
            let report = viaBoard
                ? "Call the board_report_landing tool with status \"pr_opened\", the pull request's URL as prURL and a one-line summary. If you can't open it, call board_report_landing with status \"blocked\" and the reason."
                : "Call `deliver` with the pull request's URL and a one-line summary. If you can't open it, `ask`, saying what's in the way."
            return """
                The user approved this task — open a pull request for '\(branch)' into '\(target)'. Do it yourself, in this session:
                1. \(commit)
                2. \(rebase) (If '\(target)' tracks '\(r)', `git fetch \(q(r))` first and rebase onto '\(r)/\(target)'.)
                3. \(checks)
                4. Push: `git push -u \(q(r)) \(qb)` (after a rebase, `--force-with-lease` is fine: the branch is yours).
                5. Create it with `gh pr create --base \(qt)`: a concise imperative title, and a body with a '## Summary' (what changed and why) and a '## Test plan' (how it was verified).
                6. \(report)
                \(identity)
                """
        }
        let pushTo = push ? (rm ?? "origin") : nil
        let landedIn = pushTo.map { "'\($0)/\(target)'" } ?? "'\(target)'"
        let report = viaBoard
            ? "Call the board_report_landing tool with status \"merged\" and a one-line summary of what landed\(pushTo == nil ? "" : " once \(landedIn) has it"). If you can't land it, don't force anything: call board_report_landing with status \"blocked\" and the reason."
            : "Call `deliver` with one line saying it landed in \(landedIn). If you can't land it, don't force anything: `ask`, saying what's in the way."
        var steps = [commit]
        if let r = pushTo {
            steps.append("`git fetch \(q(r))`. If '\(r)/\(target)' has commits '\(target)' lacks, bring them into '\(target)' "
                + "first, in its checkout: `git pull --rebase \(q(r)) \(qt)` (resolve conflicts keeping both sides' intent).")
        }
        steps += [rebase, checks]
        if mode == .squash {
            steps.append("Squash your work into one commit: `git reset --soft \(qt) && git commit -m \(q(title))`.")
        }
        steps.append("Fast-forward '\(target)' to your branch: in the checkout where '\(target)' is checked out "
            + "(`git worktree list` shows it), run `git merge --ff-only \(qb)`. If '\(target)' isn't checked out "
            + "anywhere, run `git -C \(q(rootRepo)) fetch . \(q(branch + ":" + target))` instead. Never touch, stash or discard "
            + "uncommitted changes in that checkout — if git refuses because of them, stop and report blocked.")
        if let r = pushTo {
            steps.append("Push it: `git push \(q(r)) \(qt)`. Never force-push '\(target)'. If it's rejected because "
                + "'\(r)' moved on, `git pull --rebase \(q(r)) \(qt)` in the '\(target)' checkout, resolve any "
                + "conflicts, re-run the checks and push again.")
        }
        steps.append(report)
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "The user approved this task — land it in \(landedIn). Do it yourself, in this session:\n"
            + numbered + "\n" + identity
    }

    // MARK: Landing

    /// Who lands a task, for the card ("Kimi Code", "@hotfixes").
    nonisolated static func landingAgentName(_ t: CodingTask) -> String { t.workerName }

    /// Land an approved task: merge (or squash-merge) into `target` (its
    /// parent by default), or open a pull request. One landing at a time;
    /// a stuck one ("Needs you") can be retried.
    func land(_ taskID: UUID, mode: TaskLanding.Mode, target targetOverride: String? = nil,
              keepBranch: Bool = false, push: Bool = false) {
        guard let task = store.task(taskID), task.stage == .testing else { return }
        if let l = task.landing, l.phase != .needsYou { return }
        // Nothing to land: a task without a branch is simply done.
        guard let branch = task.branch else { markDone(taskID); return }
        let wanted = targetOverride ?? task.parentBranch ?? ""
        store.mutate(taskID) {
            $0.landing = TaskLanding(mode: mode, target: wanted, phase: .checking,
                                     startedAt: Date(), keepBranch: keepBranch,
                                     push: push && mode != .pr ? true : nil)
            $0.lastError = nil
        }
        BACDebug.log("tasks", "“\(task.title)”: landing \(branch) → \(wanted.isEmpty ? "parent" : wanted) (\(mode.rawValue))")
        Task { [weak self] in await self?.runLanding(taskID, branch: branch, targetOverride: targetOverride) }
    }

    /// Land several approved tasks into their targets at once — merges
    /// only (a squash or a pull request stays one at a time). Each clean
    /// one Bromure merges itself, one after the other; what's left — the
    /// ones whose branches conflict or moved on — goes to ONE agent (the
    /// first such card's), with one brief: merge them all, fix conflicts,
    /// run the checks once, push once. A delegated task lands its own.
    func landBatch(_ ids: [UUID], keepBranch: Bool = false, push: Bool = false) {
        let tasks = ids.compactMap { store.task($0) }.filter {
            $0.stage == .testing && ($0.landing == nil || $0.landing?.phase == .needsYou)
        }
        var grouped: [String: [UUID]] = [:]
        var order: [String] = []
        for t in tasks {
            guard t.delegationID == nil, t.branch != nil else {
                land(t.id, mode: .merge, keepBranch: keepBranch, push: push)
                continue
            }
            let key = t.profileID.uuidString + "\u{0}" + (t.rootRepo ?? t.repoPath)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(t.id)
        }
        for key in order {
            let group = grouped[key] ?? []
            if group.count == 1 {
                land(group[0], mode: .merge, keepBranch: keepBranch, push: push)
                continue
            }
            for id in group {
                store.mutate(id) {
                    $0.landing = TaskLanding(mode: .merge, target: $0.parentBranch ?? "", phase: .checking,
                                             startedAt: Date(), keepBranch: keepBranch,
                                             push: push ? true : nil)
                    $0.lastError = nil
                }
            }
            BACDebug.log("tasks", "batch landing of \(group.count) tasks")
            Task { [weak self] in await self?.runBatch(group) }
        }
    }

    /// One after the other through the fast path, then the rest to one agent.
    private func runBatch(_ ids: [UUID]) async {
        var left: [LandingHandOff] = []
        for id in ids {
            guard let branch = store.task(id)?.branch else { continue }
            if let h = await runLanding(id, branch: branch, targetOverride: nil, batched: true) { left.append(h) }
        }
        // One agent per target (cards of one batch may start from different branches).
        var byTarget: [String: [LandingHandOff]] = [:]
        var targets: [String] = []
        for h in left {
            if byTarget[h.target] == nil { targets.append(h.target) }
            byTarget[h.target, default: []].append(h)
        }
        for target in targets {
            let hs = byTarget[target] ?? []
            guard let lead = hs.first else { continue }
            guard hs.count > 1, let leadTask = store.task(lead.taskID) else {
                await handLandingToAgent(lead.taskID, branch: lead.branch, target: lead.target,
                                         root: lead.root, pushedLocally: lead.pushedLocally)
                continue
            }
            let followers = hs.dropFirst().map(\.taskID)
            for f in followers {
                store.mutate(f) {
                    $0.landing?.phase = .agentLanding
                    $0.landing?.batchLead = lead.taskID
                    $0.landing?.startedAt = Date()
                    $0.landing?.handingOver = nil
                    $0.landing?.detail = String(format: NSLocalizedString(
                        "Merged with others by %@", comment: "task landing: a card landed in a batch"),
                        leadTask.workerName)
                }
                watchLanding(f)
            }
            store.mutate(lead.taskID) { $0.landing?.batch = Array(followers) }
            let pushes = leadTask.landing?.pushes == true
            let prompt = Self.batchLandingPrompt(
                branches: hs.map { ($0.branch, store.task($0.taskID)?.title ?? "") },
                target: target, rootRepo: lead.root,
                remote: pushes ? leadTask.landing?.remote : nil)
            await handLandingToAgent(lead.taskID, branch: lead.branch, target: target, root: lead.root,
                                     promptOverride: prompt)
        }
    }

    /// The batch brief: merge each branch into `target` in order, in its
    /// checkout; conflicts resolved keeping both sides; checks once; push
    /// once (`remote`); one report for all.
    nonisolated static func batchLandingPrompt(branches: [(branch: String, title: String)], target: String,
                                               rootRepo: String, remote: String?) -> String {
        let rm = safeRemote(remote)
        let (qt, list) = (q(target), branches.enumerated().map { i, b in
            "   \(i + 1). `\(q(b.branch))` — \(b.title.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n"))
        var steps: [String] = [
            "For each branch below, commit anything still uncommitted in its checkout (`git worktree list` "
                + "shows them) with clear messages (leave out build artifacts and scratch files).",
        ]
        if let r = rm {
            steps.append("In the checkout where '\(target)' is checked out, bring in what '\(r)/\(target)' has "
                + "first: `git fetch \(q(r))` then `git pull --rebase \(q(r)) \(qt)`.")
        }
        steps.append("In the checkout where '\(target)' is checked out (`git worktree list` shows it; if it isn't "
            + "checked out anywhere, check it out in a scratch worktree of \(q(rootRepo))), merge the branches one "
            + "after the other, in this order — `git merge --no-edit <branch>` for each, committing each merge "
            + "before the next. Resolve every conflict keeping both sides' intent — never drop the other side's "
            + "changes. Never touch, stash or discard uncommitted changes in that checkout — if git refuses "
            + "because of them, stop and report blocked.\n" + list)
        steps.append("Once they're all in, run the project's quick checks (tests, a build, a linter) once and fix "
            + "what the merges broke. Don't go fixing unrelated failures.")
        if let r = rm {
            steps.append("Push it: `git push \(q(r)) \(qt)`. Never force-push '\(target)'. If it's rejected "
                + "because '\(r)' moved on, pull --rebase again, re-run the checks and push again.")
        }
        steps.append("Call the board_report_landing tool once, with status \"merged\" and a one-line summary, when "
            + "every branch is in '\(target)'\(rm.map { " and '\($0)/\(target)'" } ?? "") — Bromure checks each. "
            + "If some can't be merged, merge the others, then call board_report_landing with status \"blocked\" "
            + "naming the ones that aren't in and why. Don't force anything.")
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "The user approved \(branches.count) tasks — merge them all into '\(target)', in one go. "
            + "Do it yourself, in this session:\n" + numbered + "\n"
            + "If git has no identity configured, commit with "
            + "`git -c user.name=Bromure -c user.email=bromure@localhost commit …` rather than stopping to ask."
    }

    /// Where a batch's other cards stand once its agent reports or stops:
    /// each one Bromure sees in its target goes Done; the rest need you.
    private func settleBatchFollowers(of leadID: UUID, why: @escaping (CodingTask) -> String) async {
        guard let ids = store.task(leadID)?.landing?.batch else { return }
        for id in ids {
            guard let t = store.task(id), t.stage == .testing, t.landing?.phase == .agentLanding,
                  t.landing?.batchLead == leadID else { continue }
            if await landingVerified(t) == true {
                finishLanding(id, verified: true, by: nil)
            } else {
                needsYou(id, why(t))
            }
        }
    }

    private func needsYou(_ taskID: UUID, _ why: String) {
        store.mutate(taskID) {
            guard $0.landing != nil else { return }
            $0.landing?.phase = .needsYou
            $0.landing?.detail = why
            $0.landing?.handingOver = nil
        }
        BACDebug.log("tasks", "landing needs you: \(why)")
    }

    /// `batched`: part of a batch landing — what needs an agent comes back
    /// (to go, with the others, to one agent) instead of being handed over.
    @discardableResult
    private func runLanding(_ taskID: UUID, branch: String, targetOverride: String?,
                            batched: Bool = false) async -> LandingHandOff? {
        guard let delegate, var task = store.task(taskID), let mode = task.landing?.mode else { return nil }
        let delegated = task.delegationID != nil
        // A workspace that's off is booted (a delegated assignee may sit on
        // a machine this host can't exec into — it lands its own work).
        if !delegated, let why = await ensureWorkspaceUp(task.profileID, delegate: delegate) {
            needsYou(taskID, why)
            return nil
        }
        // Metadata a detached finish never captured.
        if task.rootRepo == nil || task.parentBranch == nil || task.worktreeDir == nil {
            let m = await resolveWorktreeMetadata(profileID: task.profileID, branch: branch,
                                                  repoPath: task.repoPath)
            store.mutate(taskID) {
                if $0.worktreeDir == nil { $0.worktreeDir = m.dir }
                if $0.parentBranch == nil { $0.parentBranch = m.parent }
                if $0.rootRepo == nil { $0.rootRepo = m.root }
            }
            task = store.task(taskID) ?? task
        }
        let target = targetOverride ?? task.parentBranch
        guard let target, !target.isEmpty, let root = task.rootRepo, !root.isEmpty else {
            if delegated {
                return await handOff(.init(taskID: taskID, branch: branch, target: target ?? "",
                                           root: fallbackRoot(task), pushedLocally: false), batched: batched)
            }
            needsYou(taskID, NSLocalizedString(
                "Couldn't read the branch's repository or where it started — is the workspace running?",
                comment: "task landing"))
            return nil
        }
        store.mutate(taskID) { $0.landing?.target = target }
        if task.landing?.pushes == true, task.landing?.remote == nil {
            guard let r = await remoteName(task) else {
                needsYou(taskID, NSLocalizedString(
                    "The repository has no remote to push to — merge it without pushing.",
                    comment: "task landing"))
                return nil
            }
            store.mutate(taskID) { $0.landing?.remote = r }
        }
        if mode != .pr {
            store.mutate(taskID) { $0.landing?.phase = .fastMerging }
            let out = try? await delegate.guestExec(
                profileID: task.profileID,
                command: Self.landingCheckCommand(root: root, branch: branch, target: target,
                                                  sourceDir: task.worktreeDir, mode: mode),
                timeout: 60)
            switch Self.parseLandingCheck(out) {
            case .merged, .mergedNow:
                if let remote = store.task(taskID)?.landing.flatMap({ $0.pushes ? $0.remote : nil }) {
                    return await pushAfterMerge(taskID, branch: branch, target: target, root: root,
                                                remote: remote, batched: batched)
                }
                finishLanding(taskID, verified: true, by: nil)
                return nil
            case .noTarget:
                needsYou(taskID, String(format: NSLocalizedString(
                    "The branch %@ doesn't exist in the repository any more — merge into another branch.",
                    comment: "task landing"), target))
                return nil
            case .noBranch:
                needsYou(taskID, String(format: NSLocalizedString(
                    "The task's branch %@ is gone from the repository.", comment: "task landing"), branch))
                return nil
            case .dirtyTarget:
                needsYou(taskID, String(format: NSLocalizedString(
                    "The %@ checkout has uncommitted changes in files this task touches — commit or stash them there, then retry.",
                    comment: "task landing"), target))
                return nil
            case .failed where out == nil && !delegated:
                needsYou(taskID, NSLocalizedString("Couldn't reach the workspace — is it running?",
                                                   comment: "task landing"))
                return nil
            case .dirtySource, .diverged, .failed:
                break
            }
        }
        return await handOff(.init(taskID: taskID, branch: branch, target: target, root: root,
                                   pushedLocally: false), batched: batched)
    }

    /// Merged locally on the fast path: push the target when that's a clean
    /// fast-forward of the remote; anything else (the remote moved on, git
    /// refused) goes to the agent — pull, fix conflicts, push.
    private func pushAfterMerge(_ taskID: UUID, branch: String, target: String, root: String,
                                remote: String, batched: Bool = false) async -> LandingHandOff? {
        guard let delegate, let task = store.task(taskID) else { return nil }
        let out = try? await delegate.guestExec(
            profileID: task.profileID,
            command: Self.pushTargetCommand(root: root, target: target, remote: remote), timeout: 90)
        let word = (out ?? "").split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        BACDebug.log("tasks", "“\(task.title)”: push \(target) → \(remote): \(word.isEmpty ? "no answer" : word)")
        if word == "pushed" {
            finishLanding(taskID, verified: true, by: nil)
            return nil
        }
        if out == nil && task.delegationID == nil {
            needsYou(taskID, String(format: NSLocalizedString(
                "Merged into %@, but couldn't reach the workspace to push it — is it running?",
                comment: "task landing"), target))
            return nil
        }
        return await handOff(.init(taskID: taskID, branch: branch, target: target, root: root,
                                   pushedLocally: true), batched: batched)
    }

    /// Where a landing's agent part would start (a batch collects these).
    private func handOff(_ h: LandingHandOff, batched: Bool) async -> LandingHandOff? {
        if batched { return h }
        await handLandingToAgent(h.taskID, branch: h.branch, target: h.target, root: h.root,
                                 pushedLocally: h.pushedLocally)
        return nil
    }

    private func fallbackRoot(_ t: CodingTask) -> String { t.rootRepo ?? ScheduledAutomationEngine.guestPath(t.repoPath) }

    /// The agent that wrote it lands it: typed into its live session, or its
    /// conversation resumed in a fresh tab — a delegated assignee is steered.
    /// `pushedLocally`: merged here already — the agent only syncs with the
    /// remote and pushes.
    private func handLandingToAgent(_ taskID: UUID, branch: String, target: String, root: String,
                                    pushedLocally: Bool = false, promptOverride: String? = nil) async {
        guard let delegate, let task = store.task(taskID), let mode = task.landing?.mode else { return }
        var remote: String?
        if mode == .pr {
            remote = await remoteName(task)
            if remote == nil, task.delegationID == nil {
                needsYou(taskID, NSLocalizedString(
                    "The repository has no remote to open a pull request on — merge it instead.",
                    comment: "task landing"))
                return
            }
        }
        let pushes = task.landing?.pushes == true
        if pushes { remote = task.landing?.remote }
        let prompt = promptOverride ?? (pushedLocally
            ? Self.pushPrompt(branch: branch, target: target, remote: remote ?? "origin",
                              viaBoard: task.delegationID == nil)
            : Self.landingPrompt(mode: mode, branch: branch, target: target, rootRepo: root,
                                 title: task.title, remote: remote,
                                 viaBoard: task.delegationID == nil, push: pushes))
        store.mutate(taskID) {
            $0.landing?.phase = .agentLanding
            $0.landing?.startedAt = Date()
            $0.landing?.detail = nil
            $0.landing?.agentLine = nil
            $0.landing?.handingOver = true
            $0.sessionParkedAt = nil
        }
        if task.delegationID != nil {
            guard await delegate.taskDispatcher.steerLanding(taskID, text: prompt) else {
                needsYou(taskID, store.task(taskID)?.lastError ?? NSLocalizedString(
                    "Couldn't reach the session that did the task.", comment: "task landing"))
                return
            }
        } else {
            // Into the agent's own conversation: typed into its running TUI,
            // or its conversation resumed in a fresh tab. The card says
            // "Handing over…" until that's confirmed; a failure is "Needs
            // you" with the reason right away, not after the stall timeout.
            let before = await lastAgentLine(task)
            guard await deliverToConversation(taskID, branch: branch, text: prompt) else {
                guard store.task(taskID)?.landing?.phase == .agentLanding else { return }
                let why = store.task(taskID)?.lastError ?? String(format: NSLocalizedString(
                    "The landing brief didn't reach %@.", comment: "task landing"), task.workerName)
                store.mutate(taskID) { $0.lastError = nil }
                needsYou(taskID, why)
                return
            }
            landingBaselineLine[taskID] = before
            BACDebug.log("tasks", "“\(task.title)”: landing brief delivered")
        }
        // Landing proper starts now: the stall clock and the live line too.
        store.mutate(taskID) {
            guard $0.landing?.phase == .agentLanding else { return }
            $0.landing?.handingOver = nil
            $0.landing?.startedAt = Date()
            $0.lastError = nil
        }
        watchLanding(taskID)
    }

    /// The remote a landing pushes to: "origin", else the repository's
    /// first remote with a safe name (`pickRemote`); nil when none.
    func remoteName(_ task: CodingTask) async -> String? {
        guard let delegate, let root = task.rootRepo ?? task.worktreeDir else { return nil }
        let out = try? await delegate.guestExec(
            profileID: task.profileID,
            command: "git -C \(Self.shellQuote(root)) remote 2>/dev/null", timeout: 10)
        return Self.pickRemote(out ?? "")
    }

    /// Is the branch in the target? nil when the machine can't be asked.
    func landingVerified(_ task: CodingTask) async -> Bool? {
        switch await landingVerification(task) {
        case .landed: return true
        case .pending, .remoteUnreachable: return false
        case .unknown: return nil
        }
    }

    /// What the repository says about the landing — "couldn't reach the
    /// remote" kept apart from "couldn't ask the machine".
    func landingVerification(_ task: CodingTask) async -> LandingVerification {
        guard let delegate, let branch = task.branch, let root = task.rootRepo,
              let target = task.landingTarget, !target.isEmpty else { return .unknown }
        let out = try? await delegate.guestExec(
            profileID: task.profileID,
            command: Self.landingVerifyCommand(root: root, branch: branch, target: target,
                                               sourceDir: task.worktreeDir,
                                               remote: task.landing.flatMap { $0.pushes ? $0.remote : nil }),
            timeout: 30)
        return LandingVerification.parse(out)
    }

    nonisolated static let landingStallTimeout: TimeInterval = 20 * 60
    private static let landingPollInterval: UInt64 = 10_000_000_000
    /// A landing flagged "Needs you" is still looked at, less often, for
    /// this long after it started.
    private static let stalledPollInterval: UInt64 = 60_000_000_000
    nonisolated static let landingWatchLimit: TimeInterval = 24 * 3600

    /// Follow an agent landing until it's in (verified in git), reported,
    /// or stalled. PR landings finish on the agent's report (or a PR link
    /// seen in its session when it stops).
    func watchLanding(_ taskID: UUID) {
        guard !landingWatches.contains(taskID) else { return }
        landingWatches.insert(taskID)
        Task { [weak self] in
            defer { self?.landingWatches.remove(taskID); self?.landingBaselineLine[taskID] = nil }
            // "Needs you" (stalled, or the agent's word not seen in git yet)
            // keeps git looked at, less often: an agent that lands it late,
            // or whose report never reaches the board, still makes it Done.
            var slow = false
            while true {
                try? await Task.sleep(nanoseconds: slow ? Self.stalledPollInterval : Self.landingPollInterval)
                guard let self, let task = self.store.task(taskID), task.stage == .testing,
                      let l = task.landing,
                      l.phase == .agentLanding || (l.phase == .needsYou && l.mode != .pr
                                                   && Date().timeIntervalSince(l.startedAt) < Self.landingWatchLimit)
                else { return }
                slow = l.phase == .needsYou
                if l.mode != .pr, await self.landingVerified(task) == true {
                    // Seen in git while the agent may still be wrapping up
                    // (its report is seconds away): keep its session bound.
                    self.finishLanding(taskID, verified: true, by: nil,
                                       grace: Self.landingReportGrace)
                    return
                }
                // Only a line the agent wrote after the brief: the pane still
                // shows the previous turn's last one until it answers.
                if task.delegationID == nil, let line = await self.lastAgentLine(task),
                   line != self.landingBaselineLine[taskID] {
                    self.landingBaselineLine[taskID] = nil
                    self.store.mutate(taskID) { if $0.landing?.agentLine != line { $0.landing?.agentLine = line } }
                }
                if l.phase == .agentLanding, Date().timeIntervalSince(l.startedAt) > Self.landingStallTimeout {
                    self.needsYou(taskID, NSLocalizedString(
                        "Landing stalled — the agent hasn't finished after 20 minutes. Open its session to see where it is, then retry or cancel.",
                        comment: "task landing"))
                }
            }
        }
    }

    /// The agent's latest message line in its tab ("⏺ Rebasing onto main…"),
    /// for the card while it lands. nil when there's none to show.
    private func lastAgentLine(_ task: CodingTask) async -> String? {
        guard let delegate, let branch = task.branch,
              let idx = await tabIndex(profileID: task.profileID, branch: branch),
              let out = try? await delegate.guestExec(
                profileID: task.profileID,
                // -J: lines the pane wrapped at its width come back joined.
                command: "tmux capture-pane -p -J -t bromure:\(idx) 2>/dev/null | tail -n 60", timeout: 8)
        else { return nil }
        return Self.agentLine(fromPane: out)
    }

    /// The last line in a pane capture that reads like the agent talking
    /// (its message bullet), bullet and padding stripped, ANSI and markdown
    /// markup removed, cut at a word boundary with an ellipsis.
    nonisolated static func agentLine(fromPane pane: String, limit: Int = 140) -> String? {
        for raw in pane.split(whereSeparator: \.isNewline).reversed() {
            let line = stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
            for bullet in ["⏺", "●", "•", "▸"] where line.hasPrefix(bullet) {
                let text = plainMarkdown(String(line.dropFirst(bullet.count)))
                if text.count >= 3 { return truncateAtWord(text, limit: limit) }
            }
        }
        return nil
    }

    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}\][^\x{07}]*\x{07}"#,
                               with: "", options: .regularExpression)
    }

    /// Inline markdown to plain text: code ticks, emphasis, links.
    nonisolated static func plainMarkdown(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func truncateAtWord(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "…"
        }
        return head + "…"
    }

    /// The landing agent ended its turn (Stop hook): look now; when it's not
    /// in and nothing was reported, the user is asked to look.
    func landingAgentStopped(_ taskID: UUID) {
        // A batch's other card: the agent that merges them all settles it.
        if store.task(taskID)?.landing?.batchLead != nil { return }
        let stoppedWhy: (CodingTask) -> String = { t in String(format: NSLocalizedString(
            "%@ stopped before it merged this one — open its session to see why, then retry.",
            comment: "task landing: batch"), t.landing?.batchLead.flatMap { self.store.task($0)?.workerName } ?? "") }
        // Its turn is over: nothing more will be reported — end the grace.
        if landingGrace.contains(taskID) {
            landingGraceEnded.insert(taskID)
            Task { [weak self] in await self?.settleBatchFollowers(of: taskID, why: stoppedWhy) }
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            defer { Task { await self.settleBatchFollowers(of: taskID, why: stoppedWhy) } }
            guard let task = self.store.task(taskID), task.stage == .testing,
                  let l = task.landing, l.phase == .agentLanding,
                  l.handingOver != true else { return }   // the stop of a turn before the brief
            if l.mode == .pr {
                if let url = await self.prURLInSession(task) {
                    self.finishLanding(taskID, verified: true, by: nil, prURL: url)
                    return
                }
            } else if await self.landingVerified(task) == true {
                self.finishLanding(taskID, verified: true, by: nil)
                return
            }
            // A report may still be on its way — give it a moment.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let t = self.store.task(taskID), t.stage == .testing,
                  t.landing?.phase == .agentLanding else { return }
            if l.mode != .pr, await self.landingVerified(t) == true {
                self.finishLanding(taskID, verified: true, by: nil)
                return
            }
            self.needsYou(taskID, String(format: NSLocalizedString(
                "%@ stopped before it landed — open its session to see why, then retry.",
                comment: "task landing"), Self.landingAgentName(t)))
        }
    }

    private func prURLInSession(_ task: CodingTask) async -> String? {
        guard let delegate, let branch = task.branch,
              let idx = await tabIndex(profileID: task.profileID, branch: branch),
              let out = try? await delegate.guestExec(
                profileID: task.profileID,
                command: "tmux capture-pane -p -J -S -300 -t bromure:\(idx) 2>/dev/null", timeout: 8)
        else { return nil }
        return CodingTask.pullRequestURL(in: out)
    }

    /// The task is in. Done with its provenance; the agent's session put away;
    /// the transcript archived; the branch and its checkout removed unless kept
    /// (a pull request's branch lives on the forge — its checkout stays).
    /// How long a landing Bromure verified on its own keeps the agent's
    /// session (and board binding) for its report — ended early by the
    /// report or the end of the agent's turn.
    nonisolated static let landingReportGrace: TimeInterval = 60

    func finishLanding(_ taskID: UUID, verified: Bool, by: String?, prURL: String? = nil,
                       grace: TimeInterval = 0) {
        guard let task = store.task(taskID), task.stage == .testing, let l = task.landing else { return }
        let target = l.target.isEmpty ? (task.parentBranch ?? "") : l.target
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.lastError = nil
            $0.landing?.phase = .landed
            $0.landing?.verified = verified
            if l.mode == .pr {
                let url = prURL ?? l.prURL ?? $0.pullRequestURL
                $0.prOpened = true
                $0.merged = false
                $0.landing?.prURL = url
                if let url { $0.pullRequestURL = url }
                $0.completion = .prOpened(url: url)
            } else {
                $0.merged = true
                $0.prOpened = nil
                $0.completion = .merged(target: target, verified: verified, by: by)
            }
        }
        BACDebug.log("tasks", "“\(task.title)”: landed (\(l.mode.rawValue) → \(target), verified: \(verified))")
        rollUpBrief(afterPhaseDone: taskID)
        pumpQueue()
        // Only a landing seen in git removes the branch: one finished on
        // the agent's word (Bromure couldn't look) may not be in the
        // target at all, and the branch would be its only copy.
        let removeWorktree = l.mode != .pr && !l.keepBranch && task.delegationID == nil && verified
        guard grace > 0 else {
            putSessionAway(task, afterSeconds: 8)
            archiveTranscriptThenCleanup(taskID, removeWorktree: removeWorktree)
            return
        }
        // The session stays bound until the agent reports (or its turn
        // ends, or the grace runs out); then the usual put-away.
        landingGrace.insert(taskID)
        landingGraceEnded.remove(taskID)
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.landingGraceEnded.contains(taskID) { break }
            }
            guard let self else { return }
            self.landingGrace.remove(taskID)
            self.landingGraceEnded.remove(taskID)
            self.putSessionAway(task, afterSeconds: 8)
            if self.store.task(taskID) != nil {
                self.archiveTranscriptThenCleanup(taskID, removeWorktree: removeWorktree)
            }
        }
    }

    /// A Done task still in its post-landing grace (see `landingGrace`).
    func inLandingGrace(_ taskID: UUID) -> Bool { landingGrace.contains(taskID) }

    /// Give up a landing (stuck, or the user changed their mind): back to
    /// "Ready to land".
    func cancelLanding(_ taskID: UUID) {
        store.mutate(taskID) {
            guard $0.stage == .testing else { return }
            $0.landing = nil
        }
    }

    /// Retry a stuck landing with the same choices.
    func retryLanding(_ taskID: UUID) {
        guard let t = store.task(taskID), let l = t.landing else { return }
        land(taskID, mode: l.mode, target: l.target.isEmpty ? nil : l.target, keepBranch: l.keepBranch,
             push: l.pushes)
    }

    /// "Mark Merged" — a delegated task whose pull request was merged on
    /// the forge (or a merge the user did by hand): Done as merged, not
    /// verified by Bromure.
    func markMerged(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .testing else { return }
        let target = task.landingTarget ?? ""
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = true
            $0.landing = nil
            $0.lastError = nil
            $0.completion = .merged(target: target, verified: false, by: "user")
        }
        putSessionAway(task)
        rollUpBrief(afterPhaseDone: taskID)
        pumpQueue()
        archiveTranscriptThenCleanup(taskID, removeWorktree: false)
    }

    /// `board_report_landing` from the task's session (or a delegated
    /// delivery while it lands). Returns what the agent is told.
    func reportLanding(_ taskID: UUID, status: String, summary: String,
                       prURL: String?) async -> (ok: Bool, message: String) {
        let batch = store.task(taskID)?.landing?.batch ?? []
        let own = await reportLandingOne(taskID, status: status, summary: summary, prURL: prURL)
        guard !batch.isEmpty, status == "merged" || status == "blocked" else { return own }
        // One report for the whole batch: each card Bromure sees in its
        // target goes Done; the others need the user, with the agent's word.
        await settleBatchFollowers(of: taskID) { _ in
            let why = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return status == "blocked" && !why.isEmpty ? why : NSLocalizedString(
                "The batch's agent reported it done, but this branch isn't in the target — retry, or merge it on its own.",
                comment: "task landing: batch")
        }
        let left = batch.filter { self.store.task($0)?.stage == .testing }.count
        return (own.ok, own.message + (left == 0
            ? " Every other task of the batch is Done too."
            : " \(left) other task(s) of the batch aren't in yet — the user will look at them."))
    }

    private func reportLandingOne(_ taskID: UUID, status: String, summary: String,
                                  prURL: String?) async -> (ok: Bool, message: String) {
        // Bromure already saw it land (verified in git) a moment ago: the
        // agent's own report is a no-op success, and its session can go.
        if let task = store.task(taskID), task.stage == .done, landingGrace.contains(taskID) {
            landingGraceEnded.insert(taskID)
            let target = task.landing?.target ?? task.parentBranch ?? ""
            BACDebug.log("tasks", "“\(task.title)”: late landing report (\(status)) after a verified landing")
            return (true, task.prOpened == true
                ? "Already recorded: the pull request is open. The task is Done."
                : "Already recorded: Bromure verified '\(task.branch ?? "")' in '\(target)'. The task is Done.")
        }
        guard let task = store.task(taskID), task.stage == .testing else {
            return (false, "This task isn't waiting to land.")
        }
        if task.landing == nil {
            // The agent landed it on its own: record it as a merge into the parent.
            store.mutate(taskID) {
                $0.landing = TaskLanding(mode: status == "pr_opened" ? .pr : .merge,
                                         target: $0.parentBranch ?? "", phase: .agentLanding,
                                         startedAt: Date())
            }
        }
        guard let fresh = store.task(taskID), let l = fresh.landing else { return (false, "no landing") }
        let verification: LandingVerification = status == "merged" ? await landingVerification(fresh) : .unknown
        switch LandingReportOutcome.decide(status: status, summary: summary, prURL: prURL,
                                           verification: verification) {
        case .finishVerified:
            finishLanding(taskID, verified: true, by: nil)
            return (true, "Recorded: verified in '\(l.target)'. The task is Done.")
        case .finishUnverified:
            finishLanding(taskID, verified: false, by: Self.landingAgentName(fresh))
            return (true, "Recorded as merged into '\(l.target)' (Bromure couldn't verify it). The task is Done.")
        case .remoteUnchecked:
            let remote = l.remote ?? "the remote"
            needsYou(taskID, String(format: NSLocalizedString(
                "Couldn't reach %@ to check the push — the branch is kept. Check it's pushed, then mark it done or retry.",
                comment: "task landing: the remote couldn't be fetched to verify a push"), remote))
            return (true, "Recorded, but Bromure couldn't fetch '\(remote)' to check the push — the user will look. Stop here.")
        case .notYet:
            return (false, "'\(fresh.branch ?? "")' isn't in '\(l.target)' yet (or its checkout still has uncommitted changes) — finish landing it, then report again.")
        case .prOpened(let url):
            store.mutate(taskID) { if $0.landing?.mode != .pr { $0.landing?.mode = .pr } }
            finishLanding(taskID, verified: true, by: nil, prURL: url)
            return (true, "Recorded the pull request\(url.map { " \($0)" } ?? ""). The task is Done.")
        case .blocked(let why):
            needsYou(taskID, why)
            return (true, "Recorded — the user will look at it. Stop here.")
        case .invalid(let why):
            return (false, why)
        }
    }

    // MARK: Review housekeeping

    /// How many files the branch changes against its parent — 0 marks a
    /// task that produced no code (Review then offers Mark Done, not git).
    func measureCodeChanges(_ taskID: UUID) async {
        guard let delegate, let task = store.task(taskID), let branch = task.branch,
              let root = task.rootRepo ?? task.worktreeDir,
              let parent = task.parentBranch, !parent.isEmpty else { return }
        var cmd = "n=$(git -C \(Self.shellQuote(root)) diff --name-only \(Self.shellQuote(parent + "..." + branch)) -- 2>/dev/null | wc -l | tr -d ' '); "
        if let wt = task.worktreeDir, !wt.isEmpty {
            cmd += "u=$(\(TaskLitter.status(Self.shellQuote(wt))) | wc -l | tr -d ' '); "
        } else {
            cmd += "u=0; "
        }
        cmd += "echo $((n + u))"
        guard let out = try? await delegate.guestExec(profileID: task.profileID, command: cmd, timeout: 15),
              let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        store.mutate(taskID) { if $0.codeChanges != n { $0.codeChanges = n } }
    }

    /// Review tasks nobody has touched for this long get their agent's tab
    /// put away (the conversation is resumed on send-back or landing).
    nonisolated static let reviewIdleLimit: TimeInterval = 2 * 3600

    /// Which Review tasks' sessions to put away now.
    nonisolated static func idleReviewTasks(_ tasks: [CodingTask], now: Date) -> [CodingTask] {
        tasks.filter { t in
            guard t.stage == .testing, t.landing == nil, t.delegationID == nil,
                  t.sessionParkedAt == nil, let since = t.testingAt else { return false }
            let touched = max(since, t.updatedAt ?? since)
            return now.timeIntervalSince(touched) > reviewIdleLimit
        }
    }

    func sweepIdleReview() {
        let now = Date()
        // A landing nothing is watching any more (its watch ended, a report
        // that never came): look at git again — in, it goes Done.
        for t in store.tasks where t.stage == .testing && !landingWatches.contains(t.id) {
            guard let l = t.landing, l.mode != .pr, l.handingOver != true,
                  l.phase == .agentLanding || l.phase == .needsYou,
                  now.timeIntervalSince(l.startedAt) < Self.landingWatchLimit else { continue }
            watchLanding(t.id)
        }
        for t in Self.idleReviewTasks(store.tasks, now: now) {
            BACDebug.log("tasks", "“\(t.title)”: idle in Review — putting its session away")
            putSessionAway(t, afterSeconds: 0)
            store.mutate(t.id) { $0.sessionParkedAt = now }
        }
    }

    /// App launch: the idle-Review sweep, and landings that were under way
    /// when the app quit are followed again.
    func startHousekeeping() {
        for t in store.tasks where t.stage == .testing && t.landing?.phase == .agentLanding {
            if t.landing?.handingOver == true {
                // Quit before the brief reached the agent: nothing is landing.
                needsYou(t.id, NSLocalizedString("The app quit while landing this — retry.", comment: "task landing"))
            } else {
                watchLanding(t.id)
            }
        }
        // A fast path the quit interrupted: look again.
        for t in store.tasks where t.stage == .testing
            && (t.landing?.phase == .checking || t.landing?.phase == .fastMerging) {
            needsYou(t.id, NSLocalizedString("The app quit while landing this — retry.", comment: "task landing"))
        }
        guard housekeeping == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepIdleReview() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer
    }
}
#endif
