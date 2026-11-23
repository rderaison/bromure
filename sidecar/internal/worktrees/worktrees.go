// Package worktrees is git branches for native sessions (Worktrees.swift):
// a worktree at ~/.bromure/worktrees/<repo>/<slug> on branch wt/<slug>
// (made unique with -2, -3…), the repo's .worktreeinclude copied in, and
// the same merge flow as Bromure AC's. Scripts run under bash (Git Bash on
// Windows). Every path in and out of this package is virtual.
package worktrees

import (
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// sh runs a script; stdout trimmed, ok false on failure.
func sh(script string) (string, bool) {
	r := hostexec.RunShell(script, "", 60*time.Second)
	if r.Status != 0 {
		return "", false
	}
	return strings.TrimSpace(r.Stdout), true
}

// bp is a virtual path as bash here writes it, shell-quoted.
func bp(v string) string { return Q(vpath.Default().MapForBash(v)) }

// virt is a path git or bash printed, as AC sees it.
func virt(p string) string {
	p = strings.TrimSpace(p)
	if p == "" {
		return ""
	}
	return vpath.Default().MustVirtual(p)
}

func real(v string) string {
	r, err := vpath.Default().ToReal(v)
	if err != nil {
		return v
	}
	return r
}

// FolderState is the folder's repository state, as GitFolderState.json
// has it (the new-branch sheet).
func FolderState(dir string) map[string]any {
	d := bp(dir)
	top, ok := sh("git -C " + d + " rev-parse --show-toplevel 2>/dev/null")
	if !ok || top == "" {
		return map[string]any{"kind": "notRepo", "repo": false, "branches": []string{}, "includes": []string{}}
	}
	if _, ok := sh("git -C " + d + " rev-parse --verify -q HEAD"); !ok {
		return map[string]any{"kind": "noCommits", "repo": false, "branches": []string{}, "includes": []string{}}
	}
	branch, _ := sh("git -C " + d + " rev-parse --abbrev-ref HEAD")
	refs, _ := sh("git -C " + d + " for-each-ref refs/heads --sort=-committerdate --format='%(refname:short)'")
	branches := []string{}
	for _, b := range strings.Split(refs, "\n") {
		if b != "" && !strings.HasPrefix(b, "wt/") {
			branches = append(branches, b)
		}
	}
	includes := readIncludes(filepath.Join(filepath.FromSlash(top), ".worktreeinclude"))
	o := map[string]any{"kind": "repo", "repo": true, "branches": branches, "includes": includes}
	if branch != "" && branch != "HEAD" {
		o["branch"] = branch
	}
	return o
}

func readIncludes(file string) []string {
	data, err := os.ReadFile(file)
	out := []string{}
	if err != nil {
		return out
	}
	for _, l := range strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n") {
		if l != "" && !strings.HasPrefix(l, "#") {
			out = append(out, l)
		}
	}
	return out
}

// Slug is AgentSession.worktreeSlug.
func Slug(name string) string {
	var b strings.Builder
	lastDash := false
	for _, r := range strings.ToLower(name) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
			lastDash = false
		} else if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	t := strings.Trim(b.String(), "-")
	if rs := []rune(t); len(rs) > 40 {
		t = string(rs[:40])
	}
	t = strings.Trim(t, "-")
	if t == "" {
		return "worktree"
	}
	return t
}

// Made is a new checkout (virtual paths).
type Made struct {
	Dir, Branch, Parent, Root string
}

// Error is a failure with its HTTP status (400 bad / 500 failed).
type Error struct {
	Status  int
	Message string
}

func (e *Error) Error() string { return e.Message }

// Make makes the checkout (bromure-agentd's `_worktree_create`, git part).
func Make(dir, name string, initGit bool, base, tool string) (Made, error) {
	d := bp(dir)
	if top, _ := sh("git -C " + d + " rev-parse --show-toplevel 2>/dev/null"); top == "" {
		if !initGit {
			return Made{}, &Error{400, dir + " isn't a git repository"}
		}
		who := "-c user.name=Bromure -c user.email=bromure@localhost"
		if _, ok := sh("cd " + d + " && git init -q && git add -A && (git commit -q -m 'Initial commit' || git " + who + " commit -q --allow-empty -m 'Initial commit')"); !ok {
			return Made{}, &Error{500, "Couldn't make " + dir + " a git repository"}
		}
	}
	if _, ok := sh("git -C " + d + " rev-parse --verify -q HEAD"); !ok {
		sh("git -C " + d + " commit -q --allow-empty -m 'Initial commit' || git -c user.name=Bromure -c user.email=bromure@localhost -C " + d + " commit -q --allow-empty -m 'Initial commit'")
	}
	parent, ok := sh("git -C " + d + " rev-parse --abbrev-ref HEAD")
	if !ok {
		parent = "HEAD"
	}
	if parent == "HEAD" {
		if p, ok := sh("git -C " + d + " rev-parse --short HEAD"); ok {
			parent = p
		}
	}
	root := dir
	if list, ok := sh("git -C " + d + " worktree list --porcelain"); ok {
		for _, l := range strings.Split(list, "\n") {
			if strings.HasPrefix(l, "worktree ") {
				root = virt(strings.TrimPrefix(l, "worktree "))
				break
			}
		}
	}
	start := parent
	if base != "" {
		if strings.HasPrefix(base, "-") {
			return Made{}, &Error{400, "No branch or commit “" + base + "” to start from"}
		}
		if _, ok := sh("git -C " + d + " rev-parse --verify --quiet " + Q(base+"^{commit}")); !ok {
			return Made{}, &Error{400, "No branch or commit “" + base + "” to start from"}
		}
		start, parent = base, base
	}
	s := Slug(name)
	repoName := path.Base(root)
	repoDirV := vpath.GuestHome + "/.bromure/worktrees/" + repoName
	_ = os.MkdirAll(real(repoDirV), 0o755)
	suffix := ""
	for n := 1; ; {
		branch := "wt/" + s + suffix
		wtV := repoDirV + "/" + s + suffix
		_, refTaken := sh("git -C " + d + " show-ref --verify --quiet " + Q("refs/heads/"+branch))
		_, statErr := os.Stat(real(wtV))
		if !refTaken && os.IsNotExist(statErr) {
			if _, ok := sh("git -C " + d + " worktree add -q -b " + Q(branch) + " " + bp(wtV) + " " + Q(start) + " 2>&1"); !ok {
				return Made{}, &Error{500, "git couldn't create the worktree"}
			}
			copyIncludes(root, wtV)
			registryAdd(repoDirV, branch, parent, name, tool)
			return Made{Dir: wtV, Branch: branch, Parent: parent, Root: root}, nil
		}
		n++
		suffix = "-" + strconv.Itoa(n)
		if n > 50 {
			return Made{}, &Error{500, "Too many worktrees named " + s}
		}
	}
}

// copyIncludes copies the repo's .worktreeinclude (gitignored files
// agents need: .env…) into the new checkout.
func copyIncludes(root, wt string) {
	for _, pat := range readIncludes(filepath.Join(real(root), ".worktreeinclude")) {
		src, dst := root+"/"+pat, wt+"/"+pat
		if _, err := os.Stat(real(src)); err != nil {
			continue
		}
		if _, err := os.Stat(real(dst)); err == nil {
			continue
		}
		_ = os.MkdirAll(filepath.Dir(real(dst)), 0o755)
		sh("cp -a " + bp(src) + " " + bp(dst))
	}
}

// Remove removes the checkout and the branch (agentd's `_worktree_remove`).
func Remove(root, branch string) {
	if !IsSafeBranchName(branch) {
		return
	}
	r := bp(root)
	list, _ := sh("git -C " + r + " worktree list --porcelain")
	for _, block := range strings.Split(list, "\n\n") {
		if !strings.Contains(block, "branch refs/heads/"+branch) {
			continue
		}
		for _, l := range strings.Split(block, "\n") {
			if strings.HasPrefix(l, "worktree ") {
				sh("git -C " + r + " worktree remove --force " + Q(strings.TrimPrefix(l, "worktree ")))
			}
		}
		break
	}
	sh("git -C " + r + " branch -D " + Q(branch))
	sh("git -C " + r + " worktree prune")
	registryDel(vpath.GuestHome+"/.bromure/worktrees/"+path.Base(root), branch)
}

// The registry: `<repo>/.registry` — branch, parent, display, tool, 0x1f
// separated, one per line.
const us = "\x1f"

func registryAdd(repoDirV, branch, parent, display, tool string) {
	clean := func(v string) string {
		return strings.ReplaceAll(strings.ReplaceAll(v, "\n", " "), us, " ")
	}
	line := strings.Join([]string{clean(branch), clean(parent), clean(display), clean(tool)}, us) + "\n"
	f, err := os.OpenFile(filepath.Join(real(repoDirV), ".registry"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	f.WriteString(line)
	f.Close()
}

func registryDel(repoDirV, branch string) {
	reg := filepath.Join(real(repoDirV), ".registry")
	data, err := os.ReadFile(reg)
	if err != nil {
		return
	}
	var kept strings.Builder
	for _, l := range strings.Split(string(data), "\n") {
		b := strings.SplitN(l, us, 2)[0]
		if b != "" && b != branch {
			kept.WriteString(l + "\n")
		}
	}
	_ = os.WriteFile(reg, []byte(kept.String()), 0o644)
}

// Probe is ahead / behind the parent and uncommitted files (nil when the
// checkout is gone).
type Probe struct {
	Ahead, Behind, Changed int
	Root, Parent           string
}

func ProbeBranch(dir, parent string) *Probe {
	if _, err := os.Stat(real(dir)); err != nil {
		return nil
	}
	script := "cd " + bp(dir) + " || exit 1; " + Off(".") + "r=$(git worktree list --porcelain | head -1 | cut -c10-); " +
		"p=" + Q(parent) + "; [ -n \"$p\" ] || p=$(git -C \"$r\" rev-parse --abbrev-ref HEAD); " +
		"a=$(git rev-list --count \"$p..HEAD\" 2>/dev/null || echo 0); " +
		"b=$(git rev-list --count \"HEAD..$p\" 2>/dev/null || echo 0); " +
		"c=$( { git status --porcelain --ignore-submodules=dirty 2>/dev/null" + StatusFailed + "; " + DirtySubmodules(".", false) + " } | wc -l | tr -d ' '); echo \"$a $b $c|$r|$p\""
	out, ok := sh(script)
	if !ok {
		return nil
	}
	f := strings.Split(out, "|")
	if len(f) != 3 {
		return nil
	}
	n := strings.Fields(f[0])
	if len(n) != 3 {
		return nil
	}
	atoi := func(s string) int { v, _ := strconv.Atoi(s); return v }
	return &Probe{Ahead: atoi(n[0]), Behind: atoi(n[1]), Changed: atoi(n[2]), Root: virt(f[1]), Parent: f[2]}
}

// TryMerge is the fast path: a clean branch merges on its own.
func TryMerge(root, branch, into, source string, squash bool) Outcome {
	m := vpath.Default()
	out, _ := sh(MergeScript(m.MapForBash(root), branch, into, m.MapForBash(source), squash))
	if strings.HasSuffix(out, "merged") {
		return Merged
	}
	return Why(out)
}

// Landed: has the branch landed in the target (a merge, or a squash's
// content)?
func Landed(root, branch, target string, squash bool) bool {
	if UnsafeBranch(branch, target) != "" {
		return false
	}
	r, b, t := bp(root), Q(branch), Q(target)
	var check string
	if squash {
		check = "[ -z \"$(git -C " + r + " diff " + DiffFlags + " " + t + " " + b + " -- 2>/dev/null)\" ] && echo merged"
	} else {
		check = "git -C " + r + " merge-base --is-ancestor " + b + " " + t + " 2>/dev/null && echo merged"
	}
	out, _ := sh(check + "; true")
	return strings.Contains(out, "merged")
}

// IsWorktreeDir: under ~/.bromure/worktrees/ (virtual).
func IsWorktreeDir(dir string) bool {
	return strings.HasPrefix(dir, vpath.GuestHome+"/.bromure/worktrees/")
}
