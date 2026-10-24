package worktrees

import (
	"regexp"
	"strings"
)

// BranchMergeCommands.swift: the git a branch session's merge and pull
// request run, and the words its agent is given when it has to finish one.

// Q is POSIX single-quoting.
func Q(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

var safeRemote = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*$`)

// IsSafeRemoteName: one plain token, never an option.
func IsSafeRemoteName(s string) bool {
	return safeRemote.MatchString(s) && !strings.Contains(s, "..") && !strings.HasSuffix(s, "/")
}

// IsSafeBranchName is what `git check-ref-format --branch` accepts, and
// nothing git would read as an option.
func IsSafeBranchName(s string) bool {
	if s == "" || len([]rune(s)) > 255 || strings.HasPrefix(s, "-") || s == "@" ||
		strings.HasPrefix(s, "/") || strings.HasSuffix(s, "/") || strings.HasSuffix(s, ".") ||
		strings.HasSuffix(s, ".lock") || strings.Contains(s, "..") || strings.Contains(s, "//") ||
		strings.Contains(s, "@{") {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f || strings.ContainsRune(" ~^:?*[\\", r) {
			return false
		}
	}
	for _, part := range strings.Split(s, "/") {
		if strings.HasPrefix(part, ".") || strings.HasSuffix(part, ".lock") {
			return false
		}
	}
	return true
}

// UnsafeBranch is the first name that isn't a plain branch name ("" none).
func UnsafeBranch(names ...string) string {
	for _, n := range names {
		if !IsSafeBranchName(n) {
			return n
		}
	}
	return ""
}

// CheckoutOf is the checkout where `into` is checked out, as shell.
func CheckoutOf(into, root string) string {
	git := "git"
	if root != "" {
		git = "git -C " + Q(root)
	}
	return git + " worktree list --porcelain | awk -v want=" + Q("branch refs/heads/"+into) + " " +
		"'/^worktree /{w=substr($0,10)} $0==want{print w}'"
}

// MergeScript merges a clean branch on its own. Prints merged, dirty,
// elsewhere or conflict.
func MergeScript(root, branch, into, sourceDir string, squash bool) string {
	if !IsSafeBranchName(branch) || !IsSafeBranchName(into) {
		return "echo conflict"
	}
	r, b, t := Q(root), Q(branch), Q(into)
	tdir := "t=$(" + CheckoutOf(into, root) + "); [ -n \"$t\" ] || t=" + r + "; "
	who := "who=; git -C \"$t\" config user.email >/dev/null || who='-c user.name=Bromure -c user.email=bromure@localhost'; "
	var mergeCmd string
	if squash {
		mergeCmd = "git $who -C \"$t\" merge --squash -- " + b + " >/dev/null 2>&1 && git $who -C \"$t\" commit -q -m " + Q("Squash-merge "+branch) + " >/dev/null 2>&1"
	} else {
		mergeCmd = "git $who -C \"$t\" merge --no-edit -- " + b + " >/dev/null 2>&1"
	}
	srcOff := Off(Q(sourceDir))
	return tdir + Off("\"$t\"") + who +
		"if [ \"$(git -C \"$t\" rev-parse --abbrev-ref HEAD 2>/dev/null)\" != " + t + " ]; then echo elsewhere; " +
		"elif [ -n \"$( ( " + srcOff + "{ git -C " + Q(sourceDir) + " status --porcelain --ignore-submodules=dirty 2>/dev/null" + StatusFailed + "; " + DirtySubmodules(Q(sourceDir), false) + " } ) )\" ]; then echo dirty; " +
		"elif " + mergeCmd + "; then echo merged; " +
		"else git -C \"$t\" merge --abort >/dev/null 2>&1; git -C \"$t\" reset -q --merge >/dev/null 2>&1; echo conflict; fi"
}

// Outcome of a merge attempt.
type Outcome string

const (
	Merged    Outcome = "merged"
	Dirty     Outcome = "dirty"
	Elsewhere Outcome = "elsewhere"
	Conflict  Outcome = "conflict"
)

// Why reads the merge script's last word.
func Why(out string) Outcome {
	switch {
	case strings.HasSuffix(out, "dirty"):
		return Dirty
	case strings.HasSuffix(out, "elsewhere"):
		return Elsewhere
	}
	return Conflict
}

// MergePrompt is what the session's agent is told when the merge needs it.
func MergePrompt(branch, into string, squash bool, why Outcome) string {
	var reason string
	switch why {
	case Dirty:
		reason = "This worktree has uncommitted changes."
	case Elsewhere:
		reason = "'" + into + "' isn't checked out anywhere, so it can't be merged into directly — check it out (in the main checkout, if that is free) first."
	default:
		reason = "Merging it straight away hit a conflict (or the target checkout has uncommitted changes)."
	}
	b := Q(branch)
	there := "git -C \"$(" + CheckoutOf(into, "") + ")\""
	var step, verb string
	if squash {
		verb = "squash-merge"
		step = "`" + there + " merge --squash -- " + b + "`, then commit it there: `" + there + " commit -m " + Q("Squash-merge "+branch) + "`"
	} else {
		verb = "merge"
		step = "`git merge --no-edit -- " + b + "` in the checkout of '" + into + "' (`git worktree list` shows where it is)"
	}
	return "The user asked to " + verb + " this branch ('" + branch + "') into '" + into + "'. " + reason + "\n" +
		"1. Commit all the intended work on this branch with clear commit messages (leave out build artifacts and scratch files).\n" +
		"2. Then run " + step + ".\n" +
		"3. If it conflicts, resolve every conflicted file keeping both sides' intent, stage the resolutions and complete the merge commit.\n" +
		"4. Reply with one line saying what landed in '" + into + "'.\n" +
		"If git has no identity configured here, commit with `git -c user.name=Bromure -c user.email=bromure@localhost` rather than stopping to ask."
}

// PullRequestPrompt asks the agent to open a PR.
func PullRequestPrompt(branch, into string) string {
	return "Open a pull request for this branch ('" + branch + "') into '" + into + "':\n" +
		"1. Review the changes and commit anything outstanding with clear messages.\n" +
		"2. Push the branch: `git push -u -- origin " + Q("refs/heads/"+branch) + "`.\n" +
		"3. Create the PR with `gh pr create --base " + Q(into) + "` — a concise title, and a body that explains what changed and why, and how it was tested.\n" +
		"4. Reply with the PR's URL."
}
