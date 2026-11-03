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
    /// `git status` in the branch's checkout failed under `RepoGitPrograms`
    /// (a filter it can't run safely): whether it's clean is unknown.
    case statusFailed
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
    /// In the target, but the task's checkout can't be read (`git status`
    /// fails): whether it holds work the target doesn't is unknown — never
    /// verified, the user looks.
    case checkoutUnreadable
    /// The machine couldn't be asked.
    case unknown

    /// The verify command's output.
    static func parse(_ out: String?) -> LandingVerification {
        guard let out else { return .unknown }
        if out.contains("NOREMOTE") { return .remoteUnreachable }
        if out.contains("LANDED") {
            return out.contains(CodingTaskEngine.treeUnknownWord) ? .checkoutUnreadable : .landed
        }
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
    /// In the target, its checkout unreadable: the user looks (the branch
    /// and checkout are kept).
    case checkoutUnreadable
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
            case .checkoutUnreadable: return .checkoutUnreadable
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

    /// `git -C <dir>` for the commands Bromure runs itself in a task's
    /// repository: nothing the repository's own config names runs — no hook
    /// (`.git/hooks`, `core.hooksPath`), no `core.fsmonitor` program. The
    /// repository is the agent's work, or a copied worktree, or a zip with
    /// its `.git`: its config is data, never a program to run here.
    /// `dir` is already shell-quoted (or a "$var").
    nonisolated static func pinnedGit(_ dir: String) -> String {
        "git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C \(dir)"
    }

    /// The environment for a fetch or push Bromure runs: no prompt, and the
    /// ssh program from the user's own git config (global, system) or plain
    /// `ssh` — never a `core.sshCommand` the repository sets. Read outside
    /// any repository so the local config can't answer.
    /// Transports: https, http, ssh only (`GIT_ALLOW_PROTOCOL` overrides
    /// any `protocol.*.allow`) — never `ext::` (a remote URL that is a
    /// command), `git://` (its `core.gitProxy` program), a remote helper the
    /// config names, nor `file` (a local path or file:// URL): its
    /// receive-pack runs in this machine, under the target repository's own
    /// config and hooks — `pre-receive` in a repository the URL can name.
    /// A local remote's push and check are left to the agent. No `core.askPass`:
    /// an asked-for password gets nothing (`GIT_ASKPASS` beats the config).
    nonisolated static let networkGitEnv =
        "export GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https:http:ssh; "
        + "[ -n \"${GIT_ASKPASS:-}\" ] || export GIT_ASKPASS=/bin/false; "
        + "if [ -z \"${GIT_SSH_COMMAND:-}\" ] && [ -z \"${GIT_SSH:-}\" ]; then "
        + "GIT_SSH_COMMAND=$(cd / && { git config --global --get core.sshCommand || git config --system --get core.sshCommand; } 2>/dev/null) "
        + "|| GIT_SSH_COMMAND=ssh; export GIT_SSH_COMMAND; fi; "

    /// Prints `local-helper` when the repository's own config (local or
    /// worktree scope, includes too) names a credential helper — a program
    /// a fetch or push would run. The fast path then leaves it to the agent.
    nonisolated static func localCredentialHelperCheck(_ dir: String) -> String {
        "\(pinnedGit(dir)) config --show-scope --get-regexp '^credential\\..*helper$' 2>/dev/null "
            + "| grep -qE '^(local|worktree)[[:space:]]'"
    }

    /// `git fetch` from a remote with its pack program pinned: never the
    /// `remote.<name>.uploadpack` the repository's config sets. Never into
    /// submodules either (their own config). Runs under `networkGitEnv`.
    nonisolated static func pinnedFetch(_ dir: String, remote: String) -> String {
        "\(pinnedGit(dir)) -c \(q("remote.\(remote).uploadpack=git-upload-pack")) "
            + "fetch -q --no-recurse-submodules --upload-pack=git-upload-pack -- \(q(remote))"
    }

    /// `git push` with its pack program pinned (never the repository's
    /// `remote.<name>.receivepack`), no `pre-push` hook, and never signed:
    /// a `push.gpgSign` the repository sets would run its `gpg.program` to
    /// sign the push certificate once the remote asks for one. Runs under
    /// `RepoGitPrograms.off` too, which blanks a local `gpg.program`.
    nonisolated static func pinnedPush(_ dir: String, remote: String, refspec: String) -> String {
        "\(pinnedGit(dir)) -c push.gpgSign=false -c \(q("remote.\(remote).receivepack=git-receive-pack")) "
            + "push -q --no-verify --no-signed --recurse-submodules=no --receive-pack=git-receive-pack -- \(q(remote)) \(q(refspec))"
    }

    /// A remote name safe to hand git and an agent (`BranchMergeCommands`).
    nonisolated static func isSafeRemoteName(_ s: String) -> Bool { BranchMergeCommands.isSafeRemoteName(s) }
    nonisolated static func safeRemote(_ remote: String?) -> String? { BranchMergeCommands.safeRemote(remote) }
    nonisolated static func pickRemoteShell(repo: String) -> String { BranchMergeCommands.pickRemoteShell(repo: repo) }

    /// A branch name safe to hand git — Bromure's commands and an agent's
    /// brief alike: what `git check-ref-format --branch` accepts, and never
    /// an option. Quoting stops the shell, not git: a parent branch named
    /// `--upload-pack=./pwn.sh` (HEAD can point at one, and the worktree's
    /// parent is read from HEAD) ran that program from `git pull --rebase`.
    nonisolated static func isSafeBranchName(_ s: String) -> Bool {
        BranchMergeCommands.isSafeBranchName(s)
    }

    /// The first of these names that isn't a plain branch name, if any.
    nonisolated static func unsafeBranch(_ names: String?...) -> String? {
        names.compactMap { $0 }.first { !isSafeBranchName($0) }
    }

    nonisolated static func unsafeBranchWhy(_ name: String) -> String {
        String(format: NSLocalizedString(
            "“%@” isn't a plain branch name — git would read it as an option. Rename the branch, then retry.",
            comment: "task landing: an option-shaped branch name"), name)
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
        guard isSafeBranchName(branch), isSafeBranchName(target) else { return "echo failed" }
        // Filters and merge drivers the repository configures never run —
        // the dirty check's status and the fast-forward's checkout would.
        var cmd = "r=\(q(root)); " + RepoGitPrograms.off("\"$r\"")
            + "\(pinnedGit("\"$r\"")) rev-parse -q --verify \(q("refs/heads/" + target)) >/dev/null 2>&1 || { echo no-target; exit 0; }; "
            + "\(pinnedGit("\"$r\"")) rev-parse -q --verify \(q("refs/heads/" + branch)) >/dev/null 2>&1 || { echo no-branch; exit 0; }; "
        if let src = sourceDir, !src.isEmpty {
            // A status that failed isn't uncommitted work: handing it to the
            // agent (whose own git runs the repository's programs) for a
            // clean checkout stalled the landing.
            cmd += "if [ -d \(q(src)) ]; then s=$(\(TaskLitter.status(q(src)))); "
                + "if \(RepoGitPrograms.failedStatus("\"$s\"")); then echo status-failed; exit 0; fi; "
                + "if [ -n \"$s\" ]; then echo dirty-source; exit 0; fi; fi; "
        }
        cmd += "a=$(\(pinnedGit("\"$r\"")) rev-list --count \(q(target + ".." + branch)) 2>/dev/null) || { echo failed; exit 0; }; "
            + "b=$(\(pinnedGit("\"$r\"")) rev-list --count \(q(branch + ".." + target)) 2>/dev/null) || { echo failed; exit 0; }; "
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
            + "d=$(\(pinnedGit("\"$r\"")) worktree list --porcelain 2>/dev/null | awk -v want=\(q("branch refs/heads/" + target)) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w; exit}'); "
            + "if [ -n \"$d\" ]; then \(RepoGitPrograms.off("\"$d\""))\(pinnedGit("\"$d\"")) merge --ff-only -q -- \(q(branch)) >/dev/null 2>&1 && echo merged-now || echo dirty-target; "
            + "else \(pinnedGit("\"$r\"")) fetch -q -- . \(q(branch + ":" + target)) >/dev/null 2>&1 && echo merged-now || echo failed; fi"
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
        case "status-failed": return .statusFailed
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
        // A name git would read as an option is never looked up — nor LANDED.
        guard isSafeBranchName(branch), isSafeBranchName(target) else { return "echo PENDING" }
        var cmd = RepoGitPrograms.off(q(root))
        if let src = sourceDir, !src.isEmpty {
            cmd += "if [ -d \(q(src)) ]; then s=$(\(TaskLitter.status(q(src)))); "
                // A status that fails (a filter git can't run safely): the
                // checkout's state is unknown, but whether the branch is in
                // the target isn't — still looked at, never "unknown" (an
                // agent's "merged" then went Done unchecked).
                // Anything else listed with it (a dirty submodule, printed
                // after the failure) is uncommitted work: pending.
                + "if \(RepoGitPrograms.failedStatus("\"$s\"")); then "
                + "if printf '%s\\n' \"$s\" | grep -vqxF '\(RepoGitPrograms.statusFailedLine)'; then echo PENDING; exit 0; fi; "
                + "echo \(Self.treeUnknownWord); "
                + "elif [ -n \"$s\" ]; then echo PENDING; exit 0; fi; fi; "
        }
        func inRef(_ t: String) -> String {
            // Revisions after --end-of-options: never an option, whatever
            // the name (a diff that exits 0 because it parsed the target as
            // `--diff-filter=A` read as LANDED).
            "{ \(pinnedGit(q(root))) merge-base --is-ancestor --end-of-options \(q(branch)) \(q(t)) 2>/dev/null "
                + "|| \(pinnedGit(q(root))) diff \(RepoGitPrograms.diffFlags) --quiet --end-of-options \(q(t)) \(q(branch)) -- 2>/dev/null; }"
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
        // The repository names a credential helper: a program the fetch
        // would run — not checked here (NOREMOTE: the user looks).
        cmd += networkGitEnv
            + "if \(localCredentialHelperCheck(q(root))); then echo NOREMOTE; exit 0; fi; "
        cmd += "if \(pinnedFetch(q(root), remote: remote)) >/dev/null 2>&1; then "
            + "if \(local) && \(inRef("refs/remotes/\(remote)/\(target)")); then echo LANDED; else echo PENDING; fi; "
            + "else echo NOREMOTE; if \(local); then echo INLOCAL; else echo PENDING; fi; fi"
        return cmd
    }

    /// After a local merge: push `target` to `remote` when that's a plain
    /// fast-forward of what the remote has. Prints one word — `pushed`,
    /// `behind` (the remote moved on: the agent pulls and merges first),
    /// `push-failed` or `fetch-failed` (the agent looks into it).
    nonisolated static func pushTargetCommand(root: String, target: String, remote: String) -> String {
        guard isSafeRemoteName(remote), isSafeBranchName(target) else { return "echo push-failed" }
        let tracking = "refs/remotes/\(remote)/\(target)"
        return "r=\(q(root)); " + RepoGitPrograms.off("\"$r\"") + networkGitEnv
            + "if \(localCredentialHelperCheck("\"$r\"")); then echo push-failed; exit 0; fi; "
            + "\(pinnedFetch("\"$r\"", remote: remote)) >/dev/null 2>&1 || { echo fetch-failed; exit 0; }; "
            + "if \(pinnedGit("\"$r\"")) rev-parse -q --verify \(q(tracking)) >/dev/null 2>&1 "
            + "&& ! \(pinnedGit("\"$r\"")) merge-base --is-ancestor \(q(tracking)) \(q("refs/heads/" + target)) 2>/dev/null; "
            + "then echo behind; exit 0; fi; "
            + "\(pinnedPush("\"$r\"", remote: remote, refspec: "refs/heads/\(target):refs/heads/\(target)")) >/dev/null 2>&1 "
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
        // Pull and push re-read what follows `--` as options (pull hands it
        // to fetch): the target goes as a full ref, which never parses as one.
        let (qr, qtRef) = (q(rm), q("refs/heads/" + target))
        let report = viaBoard
            ? "Call the board_report_landing tool with status \"merged\" and a one-line summary once '\(rm)/\(target)' has it. If you can't push it, don't force anything: call board_report_landing with status \"blocked\" and the reason."
            : "Call `deliver` with one line saying it's pushed to '\(rm)/\(target)'. If you can't push it, don't force anything: `ask`, saying what's in the way."
        return """
            The user approved this task and '\(branch)' is merged into '\(target)' locally — now push '\(target)' to '\(rm)'. Do it yourself, in this session:
            1. `git fetch \(qr)`.
            2. In the checkout where '\(target)' is checked out (`git worktree list` shows it; if it isn't checked out anywhere, check it out in a scratch worktree), bring in what '\(rm)/\(target)' has: `git pull --rebase -- \(qr) \(qtRef)`. Resolve every conflict keeping both sides' intent — never drop the other side's changes. Never touch, stash or discard uncommitted changes in that checkout — if git refuses because of them, stop and report blocked.
            3. If the project has quick checks (tests, a build, a linter), run them and fix what the merge broke. Don't go fixing unrelated failures.
            4. Push: `git push -- \(qr) \(qtRef)`. Never force-push '\(target)'. If it's rejected because '\(rm)' moved again, repeat from step 1.
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
        // `--` ends git's options before each name; pull and push get the
        // target as a full ref (pull hands its arguments on to fetch, which
        // reads them as options again).
        let (qb, qt, qtRef) = (q(branch), q(target), q("refs/heads/" + target))
        let identity = "If git has no identity configured, commit with "
            + "`git -c user.name=Bromure -c user.email=bromure@localhost commit …` rather than stopping to ask."
        let commit = "Commit anything still uncommitted on '\(branch)' with clear messages "
            + "(leave out build artifacts and scratch files)."
        let rebase = "Rebase onto the latest '\(target)': `git rebase -- \(qt)`. Resolve every conflict "
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
                4. Push: `git push -u -- \(q(r)) \(qb)` (after a rebase, `--force-with-lease` is fine: the branch is yours).
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
                + "first, in its checkout: `git pull --rebase -- \(q(r)) \(qtRef)` (resolve conflicts keeping both sides' intent).")
        }
        steps += [rebase, checks]
        if mode == .squash {
            steps.append("Squash your work into one commit: `git reset --soft \(qt) -- && git commit -m \(q(title))`.")
        }
        steps.append("Fast-forward '\(target)' to your branch: in the checkout where '\(target)' is checked out "
            + "(`git worktree list` shows it), run `git merge --ff-only -- \(qb)`. If '\(target)' isn't checked out "
            + "anywhere, run `git -C \(q(rootRepo)) fetch -- . \(q(branch + ":" + target))` instead. Never touch, stash or discard "
            + "uncommitted changes in that checkout — if git refuses because of them, stop and report blocked.")
        if let r = pushTo {
            steps.append("Push it: `git push -- \(q(r)) \(qtRef)`. Never force-push '\(target)'. If it's rejected because "
                + "'\(r)' moved on, `git pull --rebase -- \(q(r)) \(qtRef)` in the '\(target)' checkout, resolve any "
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
        guard task.branch != nil || task.branchSlug != nil else { markDone(taskID); return }
        // One whose branch isn't recorded yet (moved to Review mid-lookup)
        // lands its live tab's, or waits — never done, never a guess.
        guard let branch = reviewBranch(task) else {
            store.mutate(taskID) { $0.lastError = Self.branchPendingText }
            return
        }
        let wanted = targetOverride ?? task.parentBranch ?? ""
        store.mutate(taskID) {
            $0.landing = TaskLanding(mode: mode, target: wanted, phase: .checking,
                                     startedAt: Date(), keepBranch: keepBranch,
                                     push: push && mode != .pr ? true : nil)
            $0.approvedTarget = wanted.isEmpty ? nil : wanted
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
    /// run the checks once, push once. Delegated tasks given to one session
    /// go to it the same way: one brief for all of them, not one message per
    /// card (each one landed alone, and the agent couldn't plan the merges).
    func landBatch(_ ids: [UUID], keepBranch: Bool = false, push: Bool = false) {
        let tasks = ids.compactMap { store.task($0) }.filter {
            $0.stage == .testing && ($0.landing == nil || $0.landing?.phase == .needsYou)
        }
        var grouped: [String: [UUID]] = [:]
        var order: [String] = []
        for t in tasks {
            guard let key = Self.batchKey(t) else {
                land(t.id, mode: .merge, keepBranch: keepBranch, push: push)
                continue
            }
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
                    $0.approvedTarget = $0.parentBranch
                    $0.lastError = nil
                }
            }
            BACDebug.log("tasks", "batch landing of \(group.count) tasks")
            Task { [weak self] in await self?.runBatch(group) }
        }
    }

    /// Which cards of a batch go to one agent together: the same machine and
    /// repository — and, for a delegated card, the same session it was given
    /// to (its own steer reaches only that one). nil: lands on its own (no
    /// branch; given to a room or a fresh agent of its own).
    nonisolated static func batchKey(_ t: CodingTask) -> String? {
        guard t.branch != nil else { return nil }
        let repo = t.profileID.uuidString + "\u{0}" + (t.rootRepo ?? t.repoPath)
        guard t.delegationID != nil else { return repo }
        guard let a = t.assignment, a.kind == .session else { return nil }
        return "session:" + a.id.uuidString + "\u{0}" + repo
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
                branches: hs.map(\.branch),
                target: target, rootRepo: lead.root,
                remote: pushes ? leadTask.landing?.remote : nil,
                viaBoard: leadTask.delegationID == nil)
            await handLandingToAgent(lead.taskID, branch: lead.branch, target: target, root: lead.root,
                                     promptOverride: prompt)
        }
    }

    /// The batch brief: merge each branch into `target` in order, in its
    /// checkout; conflicts resolved keeping both sides; checks once; push
    /// once (`remote`); one report for all.
    /// Branch names only, never the cards' titles: this brief goes to ONE
    /// agent (often another task's session, running unattended) as the
    /// user's word, and a title can be anything a planner filed
    /// (`board_create_subtasks`) — text read from a repository or an issue
    /// would become the user's instructions to an agent that pushes.
    /// `viaBoard`: false for a delegated assignee, which answers with the
    /// delegation tool `deliver` (it has no board tools).
    nonisolated static func batchLandingPrompt(branches: [String], target: String,
                                               rootRepo: String, remote: String?,
                                               viaBoard: Bool = true) -> String {
        let rm = safeRemote(remote)
        let (qtRef, list) = (q("refs/heads/" + target), branches.enumerated().map { i, b in
            "   \(i + 1). `\(q(b))`"
        }.joined(separator: "\n"))
        var steps: [String] = [
            "For each branch below, commit anything still uncommitted in its checkout (`git worktree list` "
                + "shows them) with clear messages (leave out build artifacts and scratch files).",
        ]
        if let r = rm {
            steps.append("In the checkout where '\(target)' is checked out, bring in what '\(r)/\(target)' has "
                + "first: `git fetch \(q(r))` then `git pull --rebase -- \(q(r)) \(qtRef)`.")
        }
        steps.append("In the checkout where '\(target)' is checked out (`git worktree list` shows it; if it isn't "
            + "checked out anywhere, check it out in a scratch worktree of \(q(rootRepo))), merge the branches one "
            + "after the other, in this order — `git merge --no-edit -- <branch>` for each, committing each merge "
            + "before the next. Resolve every conflict keeping both sides' intent — never drop the other side's "
            + "changes. Never touch, stash or discard uncommitted changes in that checkout — if git refuses "
            + "because of them, stop and report blocked.\n" + list)
        steps.append("Once they're all in, run the project's quick checks (tests, a build, a linter) once and fix "
            + "what the merges broke. Don't go fixing unrelated failures.")
        if let r = rm {
            steps.append("Push it: `git push -- \(q(r)) \(qtRef)`. Never force-push '\(target)'. If it's rejected "
                + "because '\(r)' moved on, pull --rebase again, re-run the checks and push again.")
        }
        if viaBoard {
            steps.append("Call the board_report_landing tool once, with status \"merged\" and a one-line summary, when "
                + "every branch is in '\(target)'\(rm.map { " and '\($0)/\(target)'" } ?? "") — Bromure checks each. "
                + "If some can't be merged, merge the others, then call board_report_landing with status \"blocked\" "
                + "naming the ones that aren't in and why. Don't force anything.")
        } else {
            steps.append("Call `deliver` once (on this request), with a one-line summary, when every branch is in "
                + "'\(target)'\(rm.map { " and '\($0)/\(target)'" } ?? "") — Bromure checks each and closes every "
                + "task of the batch. If some can't be merged, merge the others, then `ask` naming the ones that "
                + "aren't in and why. Don't force anything.")
        }
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "The user approved \(branches.count) tasks — merge them all into '\(target)', in one go. "
            + "Do it yourself, in this session:\n" + numbered + "\n"
            + "If git has no identity configured, commit with "
            + "`git -c user.name=Bromure -c user.email=bromure@localhost commit …` rather than stopping to ask."
    }

    /// Where a batch's other cards stand once its agent reports or stops:
    /// each one Bromure sees in its target goes Done; the rest need you.
    /// `reportedMerged`: the agent said every branch is in — a card Bromure
    /// can't look at (a delegated one on a machine it can't reach) is
    /// recorded on that word, as a single landing would be.
    private func settleBatchFollowers(of leadID: UUID, reportedMerged: Bool = false,
                                      why: @escaping (CodingTask) -> String) async {
        guard let ids = store.task(leadID)?.landing?.batch else { return }
        for id in ids {
            // Needs you too: the stall (or an ask) may have got there first,
            // and the agent's report still settles it.
            guard let t = store.task(id), t.stage == .testing,
                  t.landing?.phase == .agentLanding || t.landing?.phase == .needsYou,
                  t.landing?.batchLead == leadID else { continue }
            let verdict = await landingVerification(t)
            let seen: Bool? = switch verdict {
            case .landed: true
            case .pending, .remoteUnreachable, .checkoutUnreadable: false
            case .unknown: nil
            }
            // The look awaited: still this batch's card, still waiting? (A
            // Retry meanwhile replaced its landing — not this report's.)
            guard let now = store.task(id), now.stage == .testing, now.landing?.batchLead == leadID,
                  now.landing?.phase == .agentLanding || now.landing?.phase == .needsYou else { continue }
            // In the target, its checkout unreadable: the look said why
            // (statusFailedText) — not "isn't in the target".
            if verdict == .checkoutUnreadable { continue }
            if seen == true {
                finishLanding(id, verified: true, by: nil)
            } else if seen == nil, reportedMerged, t.delegationID != nil {
                finishLanding(id, verified: false, by: Self.landingAgentName(t))
            } else {
                needsYou(id, why(t))
            }
        }
    }

    /// What stops a batch's lead (the agent asks, its brief didn't reach
    /// it) stops the other cards of its batch the same way, with the same
    /// words — not a generic stall twenty minutes later.
    func batchNeedsYou(_ leadID: UUID, _ why: String) {
        for id in store.task(leadID)?.landing?.batch ?? [] {
            guard let t = store.task(id), t.stage == .testing, t.landing?.batchLead == leadID,
                  t.landing?.phase == .agentLanding || t.landing?.phase == .needsYou else { continue }
            needsYou(id, why)
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

    /// A hand-over that failed may still say so: the lead is still landing.
    /// Moved on during the await — the assignee asked (Needs you, its
    /// question on every card), or it was cancelled or landed — it stays.
    nonisolated static func stillHandingOver(_ lead: CodingTask?) -> Bool {
        lead?.landing?.phase == .agentLanding
    }

    /// A lead that moved on during a steer that then failed: what it shows
    /// stays (the question), the steer's own error goes, and it is no longer
    /// "handing over" — left set, the sweep never watched it again, and a
    /// merge the assignee didn't report kept it on Needs you for good.
    /// True when it is to be watched now (`watchLanding`): the only loop that
    /// finishes a landing the repository shows, and nothing else would start
    /// one for it — the brief did reach the agent, which may well merge
    /// after its answer. Not a pull request (the agent reports it), nor a
    /// lead that was cancelled or landed meanwhile.
    @discardableResult
    nonisolated static func settleFailedSteer(_ t: inout CodingTask, steerError: String?) -> Bool {
        if let steerError, t.lastError == steerError { t.lastError = nil }
        guard t.landing != nil else { return false }
        t.landing?.handingOver = nil
        return t.landing?.phase == .needsYou && t.landing?.mode != .pr
    }

    /// `settleFailedSteer` on the card, and the watch it calls for.
    func settleFailedHandOver(_ taskID: UUID, steerError: String?) {
        var watch = false
        store.mutate(taskID) { watch = Self.settleFailedSteer(&$0, steerError: steerError) }
        if watch { watchLanding(taskID) }
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
        if let bad = Self.unsafeBranch(branch, target.flatMap { $0.isEmpty ? nil : $0 }) {
            needsYou(taskID, Self.unsafeBranchWhy(bad))
            return nil
        }
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
            case .statusFailed:
                needsYou(taskID, Self.statusFailedText)
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
        // Every name the brief carries reaches git as typed by the agent.
        if let bad = Self.unsafeBranch(branch, target.isEmpty ? nil : target) {
            needsYou(taskID, Self.unsafeBranchWhy(bad))
            return
        }
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
                let steerError = store.task(taskID)?.lastError
                // The assignee asked while the steer awaited (the brief did
                // reach it): its question is on every card — the steer's
                // error must not replace it, nor sit beside it.
                guard Self.stillHandingOver(store.task(taskID)) else {
                    settleFailedHandOver(taskID, steerError: steerError)
                    return
                }
                let why = steerError ?? NSLocalizedString(
                    "Couldn't reach the session that did the task.", comment: "task landing")
                needsYou(taskID, why)
                batchNeedsYou(taskID, why)
                return
            }
        } else {
            // Into the agent's own conversation: typed into its running TUI,
            // or its conversation resumed in a fresh tab. The card says
            // "Handing over…" until that's confirmed; a failure is "Needs
            // you" with the reason right away, not after the stall timeout.
            let before = await lastAgentLine(task)
            let errorBefore = store.task(taskID)?.lastError
            guard await deliverToConversation(taskID, branch: branch, text: prompt) else {
                // Moved on meanwhile (the agent asked): the same as a
                // delegated steer's — left "handing over" and unwatched.
                guard Self.stillHandingOver(store.task(taskID)) else {
                    let error = store.task(taskID)?.lastError
                    settleFailedHandOver(taskID, steerError: error != errorBefore ? error : nil)
                    return
                }
                let why = store.task(taskID)?.lastError ?? String(format: NSLocalizedString(
                    "The landing brief didn't reach %@.", comment: "task landing"), task.workerName)
                store.mutate(taskID) { $0.lastError = nil }
                needsYou(taskID, why)
                batchNeedsYou(taskID, why)
                return
            }
            landingBaselineLine[taskID] = before
            BACDebug.log("tasks", "“\(task.title)”: landing brief delivered")
        }
        // Landing proper starts now: the stall clock and the live line too —
        // the batch's other cards' clocks with it (theirs started when the
        // batch began, before the fast path and the hand-over).
        store.mutate(taskID) {
            guard $0.landing?.phase == .agentLanding else { return }
            $0.landing?.handingOver = nil
            $0.landing?.startedAt = Date()
            $0.lastError = nil
        }
        // Only while the lead is still landing: a question that came in
        // during the hand-over (the steer awaited) stays on every card.
        let leadLanding = store.task(taskID)?.landing?.phase == .agentLanding
        for id in leadLanding ? (store.task(taskID)?.landing?.batch ?? []) : [] {
            store.mutate(id) {
                guard $0.stage == .testing, $0.landing?.batchLead == taskID else { return }
                if $0.landing?.phase == .agentLanding {
                    $0.landing?.startedAt = Date()
                } else if $0.landing?.phase == .needsYou, $0.landing?.detail == Self.stalledText {
                    // Stalled before the brief even reached the agent (the
                    // fast path and the hand-over took that long): landing
                    // again now. A card with its own question keeps it.
                    $0.landing?.phase = .agentLanding
                    $0.landing?.detail = nil
                    $0.landing?.startedAt = Date()
                }
            }
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
        case .pending, .remoteUnreachable, .checkoutUnreadable: return false
        case .unknown: return nil
        }
    }

    /// What the repository says about the landing — "couldn't reach the
    /// remote" kept apart from "couldn't ask the machine".
    func landingVerification(_ task: CodingTask) async -> LandingVerification {
        guard let delegate, let branch = task.branch, let root = task.rootRepo,
              let target = task.landingTarget, !target.isEmpty else { return .unknown }
        let observed = store.task(task.id)?.landing
        let out = try? await delegate.guestExec(
            profileID: task.profileID,
            command: Self.landingVerifyCommand(root: root, branch: branch, target: target,
                                               sourceDir: task.worktreeDir,
                                               remote: task.landing.flatMap { $0.pushes ? $0.remote : nil }),
            timeout: 30)
        // In the target, its checkout unreadable: never verified — it may
        // hold work the target doesn't. The branch and checkout are kept
        // (the cleanup's force-remove would take that work with it), and
        // the user looks, as when the fast path can't read it.
        // Only on the landing this look was for: a Retry meanwhile (a new
        // landing, checking or handed to the agent) isn't sent back to
        // Needs you by an old answer — and once flagged, the polls that
        // follow change nothing.
        let verdict = LandingVerification.parse(out)
        if verdict == .checkoutUnreadable {
            let effects = Self.unreadableEffects(observed: observed, now: store.task(task.id)?.landing)
            if effects.keepBranch { store.mutate(task.id) { $0.landing?.keepBranch = true } }
            if effects.needsYou { needsYou(task.id, Self.statusFailedText) }
        }
        return verdict
    }

    /// What an unreadable-checkout look does to the landing: only to the
    /// one looked at (same start). Its checkout is kept; it asks the user —
    /// unless it moved on during the look, or already waits on the user for
    /// any reason (this one, or the agent's own question: not replaced).
    nonisolated static func unreadableEffects(observed: TaskLanding?,
                                              now: TaskLanding?) -> (keepBranch: Bool, needsYou: Bool) {
        guard let now, let observed, now.startedAt == observed.startedAt else { return (false, false) }
        return (!now.keepBranch, now.phase == observed.phase && now.phase != .needsYou)
    }

    /// The verify command's word for a checkout whose status can't be read.
    nonisolated static let treeUnknownWord = "TREEUNKNOWN"

    nonisolated static let statusFailedText = NSLocalizedString(
        "Git can't read the task's checkout without running the repository's own filter program, so Bromure can't tell whether it's clean. Merge it yourself, then mark the task Done.",
        comment: "task landing: git status fails with the repository's programs switched off")

    nonisolated static let landingStallTimeout: TimeInterval = 20 * 60
    /// What a landing that stalled says (and how a batch's delivery tells a
    /// stalled card from one with its own question).
    nonisolated static var stalledText: String {
        NSLocalizedString(
            "Landing stalled — the agent hasn't finished after 20 minutes. Open its session to see where it is, then retry or cancel.",
            comment: "task landing")
    }
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
                // Read again: the look above awaited, and the clock may have
                // been restarted meanwhile (the batch's brief delivered).
                if let now = self.store.task(taskID)?.landing, now.phase == .agentLanding,
                   Date().timeIntervalSince(now.startedAt) > Self.landingStallTimeout {
                    self.needsYou(taskID, Self.stalledText)
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
        await settleBatchFollowers(of: taskID, reportedMerged: status == "merged") { _ in
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
            // No landing under way: only one the user approved (and then
            // cancelled — its brief may have been out) is recorded, into the
            // target they approved. Without that, an agent's "merged" is its
            // word, not the user's: the card stays in Review with it.
            guard let approved = task.approvedTarget, Self.isSafeBranchName(approved) else {
                store.mutate(taskID) { $0.mergeReport = summary }
                return (false, "Nobody approved landing this task yet — it stays in Review, and the user lands it from the board.")
            }
            store.mutate(taskID) {
                $0.landing = TaskLanding(mode: status == "pr_opened" ? .pr : .merge,
                                         target: approved, phase: .agentLanding,
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
        case .checkoutUnreadable:
            return (true, "Recorded, but git can't read the task's checkout, so Bromure can't tell whether it's all in '\(l.target)' — the user will look. Stop here.")
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
        repairLandedInReview()
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

    /// A card that landed (Done, its outcome recorded) and was then pulled
    /// back to Review by its assignee's late report: in Review with a
    /// `.landed` landing, which reads "Landing — merging…" and that nothing
    /// ever moves again. It landed: Done again.
    func repairLandedInReview() {
        for t in store.tasks where t.stage == .testing && t.landing?.phase == .landed && t.completion != nil {
            BACDebug.log("tasks", "“\(t.title)”: landed but back in Review — Done again")
            store.mutate(t.id) {
                $0.stage = .done
                if $0.completedAt == nil { $0.completedAt = Date() }
                $0.lastError = nil
            }
        }
    }

    /// App launch: the idle-Review sweep, and landings that were under way
    /// when the app quit are followed again.
    func startHousekeeping() {
        repairLandedInReview()
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
