import Foundation

// What a task or session review reads from the guest (the window's views
// are in TaskReviewWindow.swift): build litter, the review data and the
// branch summary.

/// Build and cache litter an agent's run leaves UNTRACKED in a checkout
/// (`__pycache__/`, `*.pyc`, `.DS_Store`, `node_modules/`) — not the task's
/// changes: left out of every uncommitted count, the review's new-file
/// list, and the "is the branch empty" check. Tracked files are never
/// filtered; git's own ignore rules apply on top.
enum TaskLitter {
    /// Filters `git status --porcelain` lines (only untracked "??" ones).
    static let statusFilter =
        #"grep -vE '^\?\? (.*/)?(__pycache__/|node_modules/|\.DS_Store$|[^/]*\.pyc$)'"#
    /// Filters a list of paths (`git ls-files --others`).
    static let pathFilter =
        #"grep -vE '(^|/)(__pycache__|node_modules)/|(^|/)\.DS_Store$|\.pyc$'"#
    /// `git status --porcelain` in `dir` (already shell-quoted), litter out.
    /// Untracked folders are listed file by file: a folder holding only
    /// `__pycache__/` would otherwise show (and count) as one new folder.
    /// Runs nothing the repository's config names (`RepoGitPrograms`): a
    /// clean filter there ran on every dirty check.
    /// A status that fails says so (`RepoGitPrograms.statusFailed`): it
    /// isn't a clean tree. A folder that's gone reads as clean, as before.
    /// Starts with a space: every caller wraps it in `$(…)`, and `$((` is
    /// ARITHMETIC to dash -- the guest's /bin/sh -- so each landing check,
    /// review count and empty-branch test was a syntax error there (exit 2,
    /// read as "couldn't reach the workspace"). bash and zsh guess a
    /// subshell, which is why it passed on the Mac.
    static func status(_ quotedDir: String) -> String {
        " ( [ -d \(quotedDir) ] || exit 0; \(RepoGitPrograms.off(quotedDir))git -C \(quotedDir) status --porcelain --untracked-files=all --ignore-submodules=dirty 2>/dev/null\(RepoGitPrograms.statusFailed); \(RepoGitPrograms.dirtySubmodules(quotedDir)) ) | \(statusFilter)"
    }
}

// MARK: - Review data

/// What a review window shows: the commits a branch added, the working-tree
/// status, and the diff against the chosen base. The guest command is
/// shared by the host (vsock guestExec) and the fat client (tunnel
/// guestExec) so the two can't drift.
struct TaskReviewData: Equatable, Sendable {
    var logLines: [String] = []
    var statusLines: [String] = []
    /// The checkout's `git status` failed (`RepoGitPrograms.failedStatus`) —
    /// and with it the whole-tree diff: an empty diff isn't "No changes".
    var statusFailed: Bool { statusLines.contains(RepoGitPrograms.statusFailedLine) }
    /// The diff itself failed: what's in `files` (untracked files at most)
    /// isn't the change set.
    var diffFailed = false
    static let diffFailedLine = "!! (git diff failed)"
    var files: [TaskDiffFile] = []

    /// What a session's review compares against.
    enum Base: Hashable, Sendable {
        /// The working tree against HEAD — edits not committed yet, new
        /// files included.
        case uncommitted
        /// Everything since the branch left `parent` (its merge base),
        /// committed or not.
        case branch(String)
        /// The last commit alone.
        case lastCommit
        /// Everything since this moment — from the last commit before it,
        /// committed or not: a turn's changes even after the agent committed
        /// (and merged) them.
        case since(Date)
    }

    /// The short commit the diff is against ("" when unknown).
    var baseRef = ""

    /// The review of a session's folder against `base`. New files the agent
    /// hasn't added to git yet are shown too (up to 40, under 200 KB each).
    /// `focusFiles`: the absolute paths the review is about (a turn's
    /// edits) — the git checkout holding the first of them that is in one is
    /// diffed instead of `dir` (an agent working in a worktree of the
    /// session's folder edits files `dir`'s diff never shows; a memory note
    /// outside any repo must not decide); `dir` when none is.
    static func sessionCommand(dir: String, base: Base, focusFiles: [String] = []) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let parents = focusFiles.filter { $0.hasPrefix("/") }.prefix(12)
            .map { ($0 as NSString).deletingLastPathComponent }
        let enter: String
        if !parents.isEmpty {
            enter = "d=; for p in \(parents.map(q).joined(separator: " ")); do "
                + "d=$(git -C \"$p\" rev-parse --show-toplevel 2>/dev/null) && [ -n \"$d\" ] && break; d=; done; "
                + "[ -n \"$d\" ] || d=\(q(dir)); cd \"$d\" || exit 1"
        } else {
            enter = "cd \(q(dir)) || exit 1"
        }
        let setBase: String
        var withWorktree = true
        switch base {
        case .uncommitted: setBase = "b=HEAD"
        case .branch(let p): setBase = "b=$(git merge-base \(q(p)) HEAD 2>/dev/null || echo \(q(p)))"
        case .lastCommit: setBase = "b=HEAD~1"; withWorktree = false
        case .since(let t):
            // The empty tree when the repo is younger than the moment.
            setBase = "b=$(git rev-list -1 --before=@\(Int(t.timeIntervalSince1970)) HEAD 2>/dev/null); "
                + "[ -n \"$b\" ] || b=4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        // No such commit (no commits yet, or the root's parent): against the
        // empty tree, as `.since` does — not a failed diff.
        let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let fallback: String
        switch base {
        case .uncommitted, .lastCommit:
            fallback = "; git rev-parse -q --verify \"$b^{tree}\" >/dev/null 2>&1 || b=\(emptyTree)"
        default:
            fallback = ""
        }
        let df = RepoGitPrograms.diffFlags
        // A diff that fails on revisions that exist (a filter git can't run
        // safely) says so, and the untracked files aren't listed after it:
        // shown alone, they read as the whole change set. A missing base (a
        // branch gone) is no such failure: the untracked files still show.
        let exists = { (rev: String) in "git rev-parse -q --verify \"\(rev)^{tree}\" >/dev/null 2>&1" }
        // The failure is noted beside the capped stream and said after it:
        // a diff that fails after 600 KB of output had its marker cut off,
        // and the cut-off part read as the whole change set. The rest is
        // drained so git runs to its end (a pipe closed at the cap killed
        // it first, and a failure further on was never seen).
        let failed = "echo 1 > \"$dfail\""
        let untracked = "git ls-files --others --exclude-standard 2>/dev/null | \(TaskLitter.pathFilter) | head -n 40 "
            + "| while IFS= read -r f; do [ \"$(stat -c%s \"$f\" 2>/dev/null || echo 0)\" -lt 204800 ] "
            + "&& git diff \(df) --no-index -- /dev/null \"$f\"; done"
        let diff = withWorktree
            ? "{ if git diff \(df) \"$b\" -- 2>/dev/null; then \(untracked); elif \(exists("$b")); then \(failed); else \(untracked); fi; }"
            : "{ git diff \(df) \"$b\" HEAD -- 2>/dev/null || { \(exists("$b")) && \(exists("HEAD")) && \(failed); }; }"
        // What the repository's config names never runs (RepoGitPrograms).
        return "\(enter); \(RepoGitPrograms.off("."))\(setBase)\(fallback); echo ===BASE===; git rev-parse --short \"$b\" 2>/dev/null; "
            + "echo ===LOG===; [ \"$b\" = HEAD ] || git log --oneline \"$b..HEAD\" 2>/dev/null | head -50; "
            + "echo ===STATUS===; { git status --porcelain --ignore-submodules=dirty 2>/dev/null\(RepoGitPrograms.statusFailed); \(RepoGitPrograms.dirtySubmodules(".")) } | \(TaskLitter.statusFilter) | head -100; "
            + "echo ===DIFF===; dfail=$(mktemp 2>/dev/null) || dfail=/tmp/bromure-review.$$; : > \"$dfail\"; "
            + "\(diff) | { head -c 600000; cat >/dev/null; }; "
            + "[ -s \"$dfail\" ] && printf '\\n%s\\n' '\(TaskReviewData.diffFailedLine)'; rm -f \"$dfail\"; true"
    }

    /// A stable fingerprint of a file's diff — "viewed" holds while it
    /// matches.
    static func fingerprint(_ file: TaskDiffFile) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for line in file.lines {
            for b in line.text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x0a) &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Split the guest command's marker-delimited output. Tolerant: missing
    /// sections yield empty lists.
    static func parse(_ raw: String) -> TaskReviewData {
        var out = TaskReviewData()
        var section = ""
        var diffLines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            switch line {
            case "===BASE===":   section = "base"; continue
            case "===LOG===":    section = "log"; continue
            case "===STATUS===": section = "status"; continue
            case "===DIFF===":   section = "diff"; continue
            default: break
            }
            switch section {
            case "base":
                if !line.isEmpty, out.baseRef.isEmpty { out.baseRef = String(line) }
            case "log":
                if !line.isEmpty { out.logLines.append(String(line)) }
            case "status":
                if !line.isEmpty { out.statusLines.append(String(line)) }
            case "diff":
                if line == Self.diffFailedLine { out.diffFailed = true } else { diffLines.append(String(line)) }
            default: break
            }
        }
        // A failed diff's body is whatever git wrote before it stopped:
        // never shown as the change set.
        out.files = out.diffFailed ? [] : TaskDiffParser.parse(diffLines.joined(separator: "\n"))
        return out
    }
}

// MARK: - Review summary

/// Where a task's branch stands against its target, from one guest command:
/// commits on the branch / on the target since, what changed, both
/// checkouts' state, and the remote a pull request would go to.
struct TaskReviewSummary: Equatable, Sendable {
    /// Commits the branch adds.
    var ahead = 0
    /// Commits the target gained since the branch left it.
    var behind = 0
    var files = 0
    var insertions = 0
    var deletions = 0
    /// Uncommitted entries in the branch's checkout.
    var uncommitted = 0
    /// Where the target is checked out ("" = nowhere).
    var targetDir = ""
    /// Uncommitted entries in the target's checkout (nil: not checked out).
    var targetDirty: Int?
    /// The first remote ("origin"), nil when the repo has none.
    var remote: String?
    var remoteURL: String?

    /// Nothing to merge: no commit and no change on the branch.
    var isNoCode: Bool { ahead == 0 && files == 0 && uncommitted == 0 }

    /// Bromure can land it itself (no agent): strictly ahead, nothing
    /// uncommitted, the target's checkout clean.
    func fastForward(squash: Bool) -> Bool {
        behind == 0 && uncommitted == 0 && (targetDirty ?? 0) == 0 && ahead > 0 && (!squash || ahead == 1)
    }

    static func command(root: String, worktreeDir: String?, branch: String, target: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var cmd = "r=\(q(root)); " + RepoGitPrograms.off("\"$r\"")
            + "echo \"AB $(git -C \"$r\" rev-list --left-right --count \(q(target + "..." + branch)) 2>/dev/null)\"; "
        if let wt = worktreeDir, !wt.isEmpty {
            cmd += "w=\(q(wt)); "
                + "m=$(git -C \"$w\" merge-base \(q(target)) HEAD 2>/dev/null); "
                + "echo \"SS $(git -C \"$w\" diff \(RepoGitPrograms.diffFlags) --shortstat \"$m\" 2>/dev/null)\"; "
                + "echo \"UC $(\(TaskLitter.status("\"$w\"")) | wc -l | tr -d ' ')\"; "
        } else {
            cmd += "echo \"SS $(git -C \"$r\" diff --shortstat \(q(target + "..." + branch)) 2>/dev/null)\"; echo 'UC 0'; "
        }
        cmd += "d=$(git -C \"$r\" worktree list --porcelain 2>/dev/null | awk -v want=\(q("branch refs/heads/" + target)) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w; exit}'); echo \"TD $d\"; "
            + "[ -n \"$d\" ] && echo \"TC $(\(TaskLitter.status("\"$d\"")) | wc -l | tr -d ' ')\"; "
            // The remote a push would go to — the landing's own pick, so a
            // name that's really an option is never shown, nor used.
            + "rm=$(\(BranchMergeCommands.pickRemoteShell(repo: "\"$r\""))); echo \"RM $rm\"; "
            + "[ -n \"$rm\" ] && echo \"RU $(git -C \"$r\" remote get-url -- \"$rm\" 2>/dev/null)\"; true"
        return cmd
    }

    static func parse(_ out: String) -> TaskReviewSummary {
        var s = TaskReviewSummary()
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.count >= 2 else { continue }
            let tag = String(line.prefix(2))
            let rest = line.count > 3 ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
            switch tag {
            case "AB":
                let n = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
                if n.count == 2 { s.behind = n[0]; s.ahead = n[1] }
            case "SS":
                // " 3 files changed, 10 insertions(+), 2 deletions(-)"
                for part in rest.split(separator: ",") {
                    let words = part.split(separator: " ")
                    guard let n = words.first.flatMap({ Int($0) }) else { continue }
                    if part.contains("file") { s.files = n }
                    else if part.contains("insertion") { s.insertions = n }
                    else if part.contains("deletion") { s.deletions = n }
                }
            case "UC": s.uncommitted = Int(rest) ?? 0
            case "TD": s.targetDir = rest
            case "TC": s.targetDirty = Int(rest)
            case "RM": s.remote = BranchMergeCommands.safeRemote(rest.isEmpty ? nil : rest)
            case "RU": s.remoteURL = rest.isEmpty ? nil : rest
            default: break
            }
        }
        return s
    }

    /// The agent's last words in a task transcript — its final report: what
    /// it wrote in its last turn (since the last prompt), not only its last
    /// message. A no-code task's answer is often a message of its own ("the
    /// haiku") followed by a wrap-up that points at it ("I wrote the haiku
    /// in the chat above") — the wrap-up alone showed no haiku. The last
    /// three messages at most.
    static func finalReport(fromTranscript text: String, agent: String?) -> String? {
        let items = AgentTranscript.parse(Data(text.utf8), agent: agent)
        var turn: [String] = []
        for item in items.reversed() {
            if case .userText = item.kind { break }
            if case .assistantText(let t) = item.kind {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { turn.insert(trimmed, at: 0) }
            }
        }
        if turn.isEmpty {
            // No prose since the last prompt: its last words anywhere.
            for item in items.reversed() {
                if case .assistantText(let t) = item.kind {
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        return turn.suffix(3).joined(separator: "\n\n")
    }
}

extension TaskReviewSummary {
    /// A delivered card's note when no worktree on its branch was found.
    static func noWorktreeText(_ branch: String) -> String {
        String(format: NSLocalizedString(
            "Delivered, but no worktree on branch %@ was found — the diff can't be shown. Read the summary, or send it back.",
            comment: "task assign"), branch)
    }
}
