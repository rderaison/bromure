package shims

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The contract test: every tmux and ps command line Bromure AC's Swift
// sources (Sources/AgentCoding) can run on a guest must parse in these
// shims, and every #{variable} its formats name must be one the shim
// expands. A client change that adds a new form fails here, with the
// file:line to look at.
//
// It needs the repository checkout (the Swift sources next to sidecar/).
// Set BROMURE_SKIP_CONTRACT=1 to skip it in a sidecar-only checkout.

type invocation struct {
	pos  string // file:line
	args []string
	raw  string
}

func findAgentCoding(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	for d := dir; ; d = filepath.Dir(d) {
		p := filepath.Join(d, "Sources", "AgentCoding")
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
		if filepath.Dir(d) == d {
			break
		}
	}
	if os.Getenv("BROMURE_SKIP_CONTRACT") == "1" {
		t.Skip("Sources/AgentCoding not found (BROMURE_SKIP_CONTRACT=1)")
	}
	t.Fatalf("Sources/AgentCoding not found above %s: the contract test needs the full repository (set BROMURE_SKIP_CONTRACT=1 to skip)", dir)
	return ""
}

type corpus struct {
	tmux    []invocation
	ps      []invocation
	formats []invocation // raw = the literal text holding #{…}
	files   int
	lits    int
}

var pyTmuxList = regexp.MustCompile(`\[\s*"tmux"\s*,([^\]]*)\]`)
var plainWord = regexp.MustCompile(`^[a-z][a-z-]*$`)

func extract(t *testing.T, root string) *corpus {
	t.Helper()
	c := &corpus{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		c.files++
		rel, _ := filepath.Rel(filepath.Dir(root), path)
		rel = filepath.ToSlash(rel)
		for _, lit := range lexSwift(string(src)) {
			c.lits++
			pos := fmt.Sprintf("%s:%d", rel, lit.line)
			posAt := func(text string, at int) string { return fmt.Sprintf("%s:%d", rel, lit.lineOf(text, at)) }
			text := stripShellComments(lit.text)
			for _, at := range commandPositions(text, "tmux") {
				words := shellWords(text, at)
				if len(words) == 0 {
					continue
				}
				if !looksLikeTmux(words[0]) {
					continue
				}
				c.tmux = append(c.tmux, invocation{pos: posAt(text, at), args: words, raw: snippet(text, at)})
			}
			for _, mi := range pyTmuxList.FindAllStringSubmatchIndex(text, -1) {
				m := []string{text[mi[0]:mi[1]], text[mi[2]:mi[3]]}
				var args []string
				for _, item := range strings.Split(m[1], ",") {
					item = strings.TrimSpace(item)
					if strings.HasPrefix(item, `"`) && strings.HasSuffix(item, `"`) && len(item) >= 2 {
						args = append(args, item[1:len(item)-1])
					} else if item != "" {
						args = append(args, "X")
					}
				}
				c.tmux = append(c.tmux, invocation{pos: posAt(text, mi[0]), args: args, raw: m[0]})
			}
			for _, at := range commandPositions(text, "ps") {
				// `docker ps`, `kubectl … ps` aren't procps.
				before := strings.Fields(text[:at-3])
				if len(before) > 0 && strings.Contains("docker kubectl podman nerdctl compose", before[len(before)-1]) {
					continue
				}
				words := shellWords(text, at)
				if len(words) == 0 || !strings.HasPrefix(words[0], "-") {
					continue
				}
				c.ps = append(c.ps, invocation{pos: posAt(text, at), args: words, raw: snippet(text, at)})
			}
			if strings.Contains(text, "#{") {
				c.formats = append(c.formats, invocation{pos: pos, raw: text})
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// looksLikeTmux tells an invocation from prose ("the tmux session"): a
// global flag, or a word tmux itself would take as a command (a name, an
// alias or a unique prefix).
func looksLikeTmux(w string) bool {
	if strings.HasPrefix(w, "-") {
		return len(w) >= 2
	}
	if !plainWord.MatchString(w) {
		return false
	}
	_, err := findCommand(w)
	return err == nil
}

func snippet(s string, at int) string {
	end := at + 160
	if end > len(s) {
		end = len(s)
	}
	start := at - 5
	if start < 0 {
		start = 0
	}
	return strings.ReplaceAll(s[start:end], "\n", "⏎")
}

// usageError is a parse-level failure in the shim's stderr.
var usageError = regexp.MustCompile(`unknown command|ambiguous command|unknown flag|too many arguments|too few arguments|expects an argument|^usage:|unsupported`)

func TestContractTmux(t *testing.T) {
	root := findAgentCoding(t)
	c := extract(t, root)
	t.Logf("scanned %d Swift files, %d literals: %d tmux invocations, %d ps invocations, %d literals with formats",
		c.files, c.lits, len(c.tmux), len(c.ps), len(c.formats))
	if testing.Verbose() || os.Getenv("BROMURE_CONTRACT_DUMP") == "1" {
		for _, inv := range c.tmux {
			t.Logf("tmux %s: %q", inv.pos, inv.args)
		}
	}
	// The extractor itself must keep working: the client has used tmux in
	// dozens of places for years.
	if len(c.tmux) < 60 {
		t.Fatalf("only %d tmux invocations extracted: the Swift lexer is broken", len(c.tmux))
	}
	subs := map[string]int{}
	for _, inv := range c.tmux {
		if err := ParseTmux(inv.args); err != nil {
			t.Errorf("%s: tmux %s\n    → %v\n    source: %s", inv.pos, strings.Join(inv.args, " "), err, inv.raw)
			continue
		}
		// …and run against a live-looking pane host: no usage error.
		f := standardFake(t)
		_, stderr, _ := tmuxOut(f, nil, "message\n", inv.args...)
		for _, line := range strings.Split(strings.TrimSpace(stderr), "\n") {
			if usageError.MatchString(line) {
				t.Errorf("%s: tmux %s\n    → %s", inv.pos, strings.Join(inv.args, " "), line)
			}
		}
		for _, w := range inv.args {
			if !strings.HasPrefix(w, "-") {
				if name, err := findCommand(w); err == nil {
					subs[name]++
				}
				break
			}
		}
	}
	// The forms §5.4 lists must all be found (a lexer regression would
	// otherwise pass vacuously).
	for _, want := range []string{"display-message", "list-windows", "list-panes", "list-clients", "capture-pane",
		"send-keys", "load-buffer", "paste-buffer", "delete-buffer", "set-option", "show-options",
		"kill-window", "kill-session", "has-session", "resize-window", "refresh-client"} {
		if subs[want] == 0 {
			t.Errorf("no %s invocation extracted from the client: the extractor or the client changed", want)
		}
	}
	var names []string
	for k, v := range subs {
		names = append(names, fmt.Sprintf("%s×%d", k, v))
	}
	sort.Strings(names)
	t.Logf("subcommands: %s", strings.Join(names, " "))
}

func TestContractFormats(t *testing.T) {
	root := findAgentCoding(t)
	c := extract(t, root)
	f := standardFake(t)
	seen := map[string]string{}
	for _, inv := range c.formats {
		var asked []string
		r := &tmuxRun{c: f, stdout: &bytes.Buffer{}, stderr: &bytes.Buffer{}, getenv: func(string) string { return "" }}
		r.onLookup = func(n string) { asked = append(asked, n) }
		for _, fm := range formatsIn(inv.raw) {
			asked = asked[:0]
			w := standardWindow(r)
			r.expand(fm, &fmtCtx{r: r, win: w, client: &f.clients[0]})
			for _, n := range asked {
				if strings.ContainsAny(n, "#{},") {
					continue // a #{?…} condition that is itself a format
				}
				if _, dup := seen[n]; !dup {
					seen[n] = inv.pos
				}
				if !knownVariable(n) {
					t.Errorf("%s: format %q uses #{%s}, which the tmux shim doesn't expand", inv.pos, fm, n)
				}
			}
		}
	}
	var names []string
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	t.Logf("%d format variables in the client: %s", len(names), strings.Join(names, " "))
	for _, want := range []string{"window_index", "window_id", "pane_tty", "pane_current_path", "pane_id", "@worktree", "@display", "client_flags", "cursor_x"} {
		if _, ok := seen[want]; !ok {
			t.Errorf("format variable %s not found in the client: the extractor or the client changed", want)
		}
	}
}

// formatsIn returns each #{…} (outermost) in s.
func formatsIn(s string) []string {
	var out []string
	for i := 0; i+1 < len(s); i++ {
		if s[i] == '#' && s[i+1] == '{' {
			end := formatSkip(s[i:], "}")
			if end < 0 {
				break
			}
			out = append(out, s[i:i+end+1])
			i += end
		}
	}
	return out
}

func standardWindow(r *tmuxRun) *winView {
	ws, _ := r.all()
	for k := range ws {
		if ws[k].Index == 1 {
			return r.view(&ws[k])
		}
	}
	return nil
}

func TestContractPs(t *testing.T) {
	root := findAgentCoding(t)
	c := extract(t, root)
	if len(c.ps) < 6 {
		t.Fatalf("only %d ps invocations extracted: the Swift lexer is broken", len(c.ps))
	}
	f := standardFake(t)
	f.procs = sampleProcs()
	for _, inv := range c.ps {
		if testing.Verbose() {
			t.Logf("ps %s: %q", inv.pos, inv.args)
		}
		if err := ParsePs(inv.args); err != nil {
			t.Errorf("%s: ps %s\n    → %v\n    source: %s", inv.pos, strings.Join(inv.args, " "), err, inv.raw)
			continue
		}
		var out, errb bytes.Buffer
		RunPs(f, inv.args, &out, &errb)
		if e := errb.String(); strings.Contains(e, "unsupported") || strings.Contains(e, "unknown") || strings.Contains(e, "syntax") {
			t.Errorf("%s: ps %s\n    → %s", inv.pos, strings.Join(inv.args, " "), errb.String())
		}
	}
}
