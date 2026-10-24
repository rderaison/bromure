package shims

import (
	"bytes"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/panes"
)

var t0 = time.Now().Add(-10 * time.Minute)

// sampleProcs: window 0 a bare Git Bash; window 1 Git Bash running Claude
// under node (with a tool child and a console helper, and Windows pids
// that don't follow start order); window 3 Codex run directly.
func sampleProcs() []panes.Proc {
	tty1 := "/dev/pty/bromure-1"
	return []panes.Proc{
		{PID: 100, PPID: 1, Window: 0, TTY: "/dev/pty/bromure-0", Exe: "bash", StartedAt: t0,
			Args: `"C:\Program Files\Git\usr\bin\bash.exe" --login -i`},
		{PID: 200, PPID: 1, Window: 1, TTY: tty1, Exe: "bash", StartedAt: t0.Add(time.Second),
			Args: `C:\Program Files\Git\usr\bin\bash.exe --login -i`},
		{PID: 210, PPID: 200, Window: 1, TTY: tty1, Exe: "conhost", StartedAt: t0.Add(2 * time.Second),
			Args: `\??\C:\Windows\system32\conhost.exe 0x4`},
		{PID: 77, PPID: 200, Window: 1, TTY: tty1, Exe: "node", StartedAt: t0.Add(5 * time.Second), Foreground: true,
			Args: `"C:\Program Files\nodejs\node.exe" C:\Users\me\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js --resume 1234`},
		{PID: 60, PPID: 77, Window: 1, TTY: tty1, Exe: "bash", StartedAt: t0.Add(60 * time.Second), Foreground: true,
			Args: `C:\Program Files\Git\usr\bin\bash.exe -c "git status"`},
		{PID: 50, PPID: 60, Window: 1, TTY: tty1, Exe: "git", StartedAt: t0.Add(61 * time.Second), Foreground: true,
			Args: `"C:\Program Files\Git\cmd\git.exe" status`},
		{PID: 300, PPID: 1, Window: 3, TTY: "/dev/pty/bromure-3", Exe: "codex", StartedAt: t0.Add(3 * time.Second),
			Args: `C:\Users\me\.local\bin\codex.exe --full-auto`},
	}
}

func psRun(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	f := standardFake(t)
	f.procs = sampleProcs()
	var out, errb bytes.Buffer
	st := RunPs(f, args, &out, &errb)
	return out.String(), errb.String(), st
}

func TestPsTtyPidStatArgs(t *testing.T) {
	out, _, st := psRun(t, "-t", "pty/bromure-1", "-o", "pid=,stat=,args=")
	want := "    200 Ss   bash --login -i\n" +
		"     77 S+   node C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js --resume 1234\n" +
		"     60 S+   bash -c \"git status\"\n" +
		"     50 S+   git status\n"
	if st != 0 || out != want {
		t.Fatalf("status %d, got:\n%s\nwant:\n%s", st, out, want)
	}
	if strings.Contains(out, "conhost") {
		t.Fatal("console helper listed")
	}
}

// The client's floor probe (CodingTasks.swift floorProbeCommand): the
// first "+" process that isn't a shell.
func floorPick(out string) string {
	shell := regexp.MustCompile(`(^|/)-?(bash|sh|zsh|dash|fish|login)$`)
	first, found := "", ""
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || !strings.Contains(f[1], "+") {
			continue
		}
		if first == "" {
			first = f[0]
		}
		if found == "" && !shell.MatchString(f[2]) {
			found = f[0]
		}
	}
	if found == "" {
		return first
	}
	return found
}

const agentNames = "claude|codex|kimi|grok|omp|aider|goose|opencode|gemini"

var shellLines = regexp.MustCompile(`^-?([^ ]*/)?(bash|sh|zsh|dash|fish|login|tmux)( |$)`)
var agentWord = regexp.MustCompile(`(^|[^A-Za-z0-9])(` + agentNames + `)([^A-Za-z]|$)`)

// AgentPaneProbe.agentFilter: grep -v shells | grep -o -m1 agent | tr -cd a-z.
func agentFilter(lines string) string {
	for _, l := range strings.Split(lines, "\n") {
		if l == "" || shellLines.MatchString(l) {
			continue
		}
		if m := agentWord.FindString(l); m != "" {
			return strings.Map(func(r rune) rune {
				if r >= 'a' && r <= 'z' {
					return r
				}
				return -1
			}, m)
		}
	}
	return ""
}

func TestPsFloorProbe(t *testing.T) {
	out, _, _ := psRun(t, "-t", "pty/bromure-1", "-o", "pid=,stat=,args=")
	if got := floorPick(out); got != "77" {
		t.Fatalf("floor probe picked %q, want the agent (77):\n%s", got, out)
	}
	et, _, _ := psRun(t, "-o", "etimes=", "-p", "77")
	if n := strings.TrimSpace(et); n < "590" || len(n) != 3 {
		t.Fatalf("etimes %q", et)
	}
	args, _, _ := psRun(t, "-ww", "-o", "args=", "-p", "77")
	if !strings.Contains(args, "--resume") || strings.HasPrefix(args, " ") {
		t.Fatalf("args %q", args)
	}
	// a bare shell: the shell is the answer
	out0, _, _ := psRun(t, "-t", "pty/bromure-0", "-o", "pid=,stat=,args=")
	if got := floorPick(out0); got != "100" {
		t.Fatalf("bare shell: %q\n%s", got, out0)
	}
	// Codex run directly is its own foreground
	out3, _, _ := psRun(t, "-t", "/dev/pty/bromure-3", "-o", "pid=,stat=,args=")
	if got := floorPick(out3); got != "300" || !strings.Contains(out3, "Ss+") {
		t.Fatalf("codex: %q\n%s", got, out3)
	}
}

func TestPsAgentPaneProbe(t *testing.T) {
	for tty, want := range map[string]string{"pty/bromure-1": "claude", "pty/bromure-0": "", "pty/bromure-3": "codex"} {
		out, _, _ := psRun(t, "-t", tty, "-o", "args=")
		if got := agentFilter(out); got != want {
			t.Errorf("%s: agent %q, want %q\n%s", tty, got, want, out)
		}
	}
}

// PaneTypeGuard: ps -A -o tty= -o tpgid= -o pgid= -o args= | awk '$1==t && $2==$3 …'.
func TestPsGuardForegroundGroup(t *testing.T) {
	out, _, _ := psRun(t, "-A", "-o", "tty=", "-o", "tpgid=", "-o", "pgid=", "-o", "args=")
	pick := func(tty string) string {
		var fg []string
		for _, line := range strings.Split(out, "\n") {
			f := strings.Fields(line)
			if len(f) >= 4 && f[0] == tty && f[1] == f[2] {
				rest := strings.TrimLeft(line, " ")
				for k := 0; k < 3; k++ {
					rest = strings.TrimLeft(rest[strings.IndexAny(rest, " ")+1:], " ")
				}
				fg = append(fg, rest)
			}
		}
		return agentFilter(strings.Join(fg, "\n"))
	}
	if got := pick("pty/bromure-1"); got != "claude" {
		t.Fatalf("guard saw %q\n%s", got, out)
	}
	if got := pick("pty/bromure-0"); got != "" {
		t.Fatalf("bare shell guard saw %q", got)
	}
	if got := pick("pty/bromure-3"); got != "codex" {
		t.Fatalf("codex guard saw %q", got)
	}
}

// AgentSessionEngine.probeCommand: ps -o pid=,args= | sed 's/^ +//' |
// grep -v procShellNames | grep -m1 agentNames | cut -d' ' -f1.
func TestPsSessionEngineProbe(t *testing.T) {
	out, _, _ := psRun(t, "-t", "pty/bromure-1", "-o", "pid=,args=")
	procShell := regexp.MustCompile(`^[0-9]+ -?(bash|sh|zsh|dash|login|tmux)( |$)`)
	names := regexp.MustCompile(`(claude|codex|kimi|grok|omp|aider|goose|amp|opencode|gemini|cursor)`)
	got := ""
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimLeft(l, " ")
		if l == "" || procShell.MatchString(l) {
			continue
		}
		if names.MatchString(l) {
			got = strings.SplitN(l, " ", 2)[0]
			break
		}
	}
	if got != "77" {
		t.Fatalf("probe pid %q\n%s", got, out)
	}
}

func TestPsEoArgsAndErrors(t *testing.T) {
	out, _, st := psRun(t, "-eo", "args=")
	if st != 0 || !strings.Contains(out, "codex --full-auto\n") || strings.Contains(out, "conhost") {
		t.Fatalf("-eo args=: %d\n%s", st, out)
	}
	if _, errs, st := psRun(t, "-o", "bogus="); st != 1 || !strings.Contains(errs, `unknown user-defined format specifier "bogus"`) {
		t.Fatalf("bad keyword: %d %q", st, errs)
	}
	if out, _, st := psRun(t, "-o", "pid=", "-p", "424242"); st != 1 || out != "" {
		t.Fatalf("no such pid: %d %q", st, out)
	}
	if _, errs, st := psRun(t, "-t", "pts/99", "-o", "pid="); st != 1 || !strings.Contains(errs, "TTY could not be found") {
		t.Fatalf("no such tty: %d %q", st, errs)
	}
	hdr, _, _ := psRun(t, "-o", "pid,stat,args", "-p", "300")
	if hdr != "    PID STAT COMMAND\n    300 Ss+  codex --full-auto\n" {
		t.Fatalf("headers:\n%q", hdr)
	}
	def, _, _ := psRun(t, "-p", "300")
	if def != "    PID TTY          TIME CMD\n    300 pty/brom 00:00:00 codex\n" && !strings.HasPrefix(def, "    PID TTY          TIME CMD\n    300 ") {
		t.Fatalf("default:\n%q", def)
	}
	if out, _, st := RunPsNil(); st != 1 || out != "" {
		t.Fatal("nil client")
	}
}

func RunPsNil() (string, string, int) {
	var out, errb bytes.Buffer
	st := RunPs(nil, []string{"-A"}, &out, &errb)
	return out.String(), errb.String(), st
}

func TestPsNormArgs(t *testing.T) {
	cases := map[[2]string]string{
		{`"C:\Program Files\Git\usr\bin\bash.exe" --login -i`, "bash"}: "bash --login -i",
		{`C:\Program Files\Git\usr\bin\bash.exe --login -i`, "bash"}:   "bash --login -i",
		{`C:\Program Files\Git\usr\bin\bash.exe`, "bash"}:              "bash",
		{`/usr/bin/bash -c kimi`, "bash"}:                              "bash -c kimi",
		{`claude --continue`, "claude"}:                                "claude --continue",
		{`C:\Users\me\.local\bin\claude.EXE --resume x`, ""}:           "claude --resume x",
		{``, "pwsh"}: "pwsh",
	}
	for in, want := range cases {
		if got := normArgs(in[0], in[1]); got != want {
			t.Errorf("normArgs(%q, %q) = %q, want %q", in[0], in[1], got, want)
		}
	}
}

// The real awk programs from CodingTasks.swift, through Git Bash's awk
// when it is installed (Windows CI with Git for Windows).
func TestPsThroughGitAwk(t *testing.T) {
	awk := `C:\Program Files\Git\usr\bin\awk.exe`
	if _, err := os.Stat(awk); err != nil {
		if p, err := exec.LookPath("awk"); err == nil {
			awk = p
		} else {
			t.Skip("no awk")
		}
	}
	out, _, _ := psRun(t, "-t", "pty/bromure-1", "-o", "pid=,stat=,args=")
	floor := `$2 ~ /\+/ { if (first == "") first = $1; if (!found && $3 !~ /(^|\/)-?(bash|sh|zsh|dash|fish|login)$/) { print $1; found = 1 } } END { if (!found) print first }`
	cmd := exec.Command(awk, floor)
	cmd.Stdin = strings.NewReader(out)
	got, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(got)) != "77" {
		t.Fatalf("awk floor: %q", got)
	}
	all, _, _ := psRun(t, "-A", "-o", "tty=", "-o", "tpgid=", "-o", "pgid=", "-o", "args=")
	guard := `$1==t && $2==$3 { $1=""; $2=""; $3=""; sub(/^ +/, ""); print }`
	cmd = exec.Command(awk, "-v", "t=pty/bromure-1", guard)
	cmd.Stdin = strings.NewReader(all)
	got, err = cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if agentFilter(string(got)) != "claude" {
		t.Fatalf("awk guard:\n%s", got)
	}
}
