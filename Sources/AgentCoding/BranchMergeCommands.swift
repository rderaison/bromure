import Foundation

/// The git a branch session's merge and pull request run, and the words its
/// agent is given when it has to finish one — ONE copy, for a VM's sessions
/// (SessionBranches) and a native one's (the Sidecar's Worktrees, through
/// Sources/AgentHost/Shared). Two copies drifted: the VM's learned to keep an
/// option-shaped branch name away from git, the native one didn't.
///
/// Every name is checked (`isSafeBranchName`), shell-quoted, and passed after
/// `--` (pull/push as `refs/heads/<name>`, which git can't read as an option
/// even where it re-parses its arguments). A name git accepts can still hold
/// `"`, `'`, `;` or `$`: none is ever spliced into a quoted string, a commit
/// message or an awk program.
enum BranchMergeCommands {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A remote name safe to hand git and an agent: one plain token, never
    /// an option. Quoting stops the shell, not git — a remote named
    /// `--exec=./pwn.sh` (whatever `.git/config` lists first: a copied
    /// worktree, a zip with its .git, the agent itself) ran that program
    /// on Merge & Push.
    static func isSafeRemoteName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
            && !s.contains("..") && !s.hasSuffix("/")
    }

    /// `remote` when it is safe, else nil.
    static func safeRemote(_ remote: String?) -> String? {
        remote.flatMap { isSafeRemoteName($0) ? $0 : nil }
    }

    /// The shell that prints the remote a landing pushes to: "origin" when
    /// the repo has one, else its first remote with a safe name — nothing
    /// when none (an unsafe name is never picked). `repo`: shell-quoted.
    /// The Swift twin is `CodingTaskEngine.pickRemote`.
    static func pickRemoteShell(repo: String) -> String {
        "git -C \(repo) remote 2>/dev/null | awk "
            + #"'/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/ && !/\.\./ && !/\/$/ { if ($0 == "origin") o = 1; else if (f == "") f = $0 } "#
            + #"END { if (o) print "origin"; else if (f != "") print f }'"#
    }

    /// A plain branch name: what `git check-ref-format --branch` accepts,
    /// and nothing git would read as an option (no leading "-").
    static func isSafeBranchName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255, !s.hasPrefix("-"), s != "@",
              !s.hasPrefix("/"), !s.hasSuffix("/"), !s.hasSuffix("."), !s.hasSuffix(".lock"),
              !s.contains(".."), !s.contains("//"), !s.contains("@{") else { return false }
        let banned = Set(" ~^:?*[\\")
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || banned.contains(Character($0)) })
        else { return false }
        return !s.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    /// The first of these names that isn't a plain branch name, if any.
    static func unsafeBranch(_ names: String?...) -> String? {
        names.compactMap { $0 }.first { !isSafeBranchName($0) }
    }

    /// The checkout where `into` is checked out, as a shell expression
    /// (the name reaches awk as a variable, never as program text).
    static func checkoutOf(_ into: String, root: String = "") -> String {
        let git = root.isEmpty ? "git" : "git -C \(q(root))"
        return "\(git) worktree list --porcelain | awk -v want=\(q("branch refs/heads/" + into)) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w}'"
    }

    /// The fast path: merge a clean branch on its own. Prints `merged`,
    /// `dirty` (the branch's checkout has uncommitted work), `elsewhere`
    /// (the target isn't checked out) or `conflict` (aborted, as it was).
    static func mergeScript(root: String, branch: String, into: String, sourceDir: String,
                            squash: Bool) -> String {
        guard isSafeBranchName(branch), isSafeBranchName(into) else { return "echo conflict" }
        let r = q(root), b = q(branch), t = q(into)
        let tdir = "t=$(\(checkoutOf(into, root: root))); [ -n \"$t\" ] || t=\(r); "
        // A machine with no git identity still gets its merge commit (the
        // same stand-in `git init` on the fly uses).
        let who = "who=; git -C \"$t\" config user.email >/dev/null || who='-c user.name=Bromure -c user.email=bromure@localhost'; "
        let mergeCmd = squash
            ? "git $who -C \"$t\" merge --squash -- \(b) >/dev/null 2>&1 && git $who -C \"$t\" commit -q -m \(q("Squash-merge " + branch)) >/dev/null 2>&1"
            : "git $who -C \"$t\" merge --no-edit -- \(b) >/dev/null 2>&1"
        // Nothing the repository's config names runs: no hook, no filter or
        // merge driver (RepoGitPrograms) — each checkout under its own: the
        // source's status in a subshell, the target's merge after.
        let srcOff = RepoGitPrograms.off(q(sourceDir))
        return tdir + RepoGitPrograms.off("\"$t\"") + who
            + "if [ \"$(git -C \"$t\" rev-parse --abbrev-ref HEAD 2>/dev/null)\" != \(t) ]; then echo elsewhere; "
            + "elif [ -n \"$( ( \(srcOff){ git -C \(q(sourceDir)) status --porcelain --ignore-submodules=dirty 2>/dev/null\(RepoGitPrograms.statusFailed); \(RepoGitPrograms.dirtySubmodules(q(sourceDir))) } ) )\" ]; then echo dirty; "
            + "elif \(mergeCmd); then echo merged; "
            + "else git -C \"$t\" merge --abort >/dev/null 2>&1; git -C \"$t\" reset -q --merge >/dev/null 2>&1; echo conflict; fi"
    }

    enum Why { case dirty, elsewhere, conflict }

    static func why(_ scriptOutput: String) -> Why {
        scriptOutput.hasSuffix("dirty") ? .dirty : scriptOutput.hasSuffix("elsewhere") ? .elsewhere : .conflict
    }

    /// What the session's agent is told when the merge needs it.
    static func mergePrompt(branch: String, into: String, squash: Bool, why: Why) -> String {
        let reason: String
        switch why {
        case .dirty: reason = "This worktree has uncommitted changes."
        case .elsewhere: reason = "'\(into)' isn't checked out anywhere, so it can't be merged into directly — check it out (in the main checkout, if that is free) first."
        case .conflict: reason = "Merging it straight away hit a conflict (or the target checkout has uncommitted changes)."
        }
        let b = q(branch)
        // Both in the target's checkout: the agent's own cwd is this
        // branch's worktree, where a bare commit would miss the squash.
        let there = "git -C \"$(\(checkoutOf(into)))\""
        let step = squash
            ? "`\(there) merge --squash -- \(b)`, then commit it there: `\(there) commit -m \(q("Squash-merge " + branch))`"
            : "`git merge --no-edit -- \(b)` in the checkout of '\(into)' (`git worktree list` shows where it is)"
        return """
            The user asked to \(squash ? "squash-merge" : "merge") this branch ('\(branch)') into '\(into)'. \(reason)
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
        2. Push the branch: `git push -u -- origin \(q("refs/heads/" + branch))`.
        3. Create the PR with `gh pr create --base \(q(into))` — a concise title, and a body that explains what changed and why, and how it was tested.
        4. Reply with the PR's URL.
        """
    }
}
