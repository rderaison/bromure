// Package hostexec runs what a client sends to `POST /vms/:id/exec` and
// `/file` on this machine, as the user. The client was written for a
// Linux guest whose home is /home/ubuntu; its shell text runs under bash
// (Git for Windows' on Windows) with the home mapped and our tmux and ps
// shims first on the PATH.
package hostexec

import (
	"encoding/base64"
	"os"
	"regexp"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// MissingShell is the stderr of a command with no bash to run it.
const MissingShell = "Git for Windows isn't installed on this machine, so commands can't run here. Install it (winget install --id Git.Git -e) and try again."

var b64Payload = regexp.MustCompile(`echo ([A-Za-z0-9+/]+={0,2}) \| base64 -d`)

// MapCommand maps a client's shell text for bash here: the home in its
// text, and in text it carries base64-encoded (`echo <b64> | base64 -d`,
// how a message is staged) — only a payload that decodes to UTF-8 text
// naming the Linux home changes. Typed text is for a native agent, so its
// paths become real ones; the shell text's own become Git Bash's.
func MapCommand(command string) string {
	m := vpath.Default()
	out := m.MapForBash(command)
	if !strings.Contains(out, "base64 -d") {
		return out
	}
	return b64Payload.ReplaceAllStringFunc(out, func(s string) string {
		sub := b64Payload.FindStringSubmatch(s)
		data, err := base64.StdEncoding.DecodeString(sub[1])
		if err != nil || !utf8.Valid(data) || !strings.Contains(string(data), vpath.GuestHome+"/") {
			return s
		}
		mapped := m.MapTextToReal(string(data))
		return strings.Replace(s, sub[1], base64.StdEncoding.EncodeToString([]byte(mapped)), 1)
	})
}

// ExecResult is the reply body of a plain exec.
type ExecResult struct {
	Status int
	Body   map[string]any
}

// Run is a plain (non-interactive) exec: {command|argv, timeout} →
// {stdout, stderr, exitCode}, 124 on timeout.
func Run(body map[string]any) ExecResult {
	timeout := 30 * time.Second
	if t, ok := number(body["timeout"]); ok && t > 0 {
		timeout = time.Duration(t * float64(time.Second))
	}
	env := CommandEnv()
	home := paths.Home()
	var r Result
	cmdText := ""
	if argv := stringList(body["argv"]); len(argv) > 0 {
		// A verbatim argument vector: no shell, the program resolved on
		// our PATH (the shims first).
		mapped := make([]string, len(argv))
		for i, a := range argv {
			mapped[i] = vpath.Default().MapForBash(a)
		}
		cmdText = strings.Join(argv, " ")
		prog, err := LookPath(argv[0], env)
		if err != nil {
			return ExecResult{200, map[string]any{"stdout": "", "stderr": argv[0] + ": command not found\n", "exitCode": 127}}
		}
		r = RunProc(ProcSpec{Path: prog, Args: mapped[1:], Env: env, Dir: home, Timeout: timeout})
	} else {
		command, _ := body["command"].(string)
		if command == "" {
			return ExecResult{400, map[string]any{"error": "Missing 'command' field"}}
		}
		cmdText = command
		sh := FindShell()
		if sh == nil {
			return ExecResult{200, map[string]any{"stdout": "", "stderr": MissingShell + "\n", "exitCode": 127}}
		}
		r = RunProc(ProcSpec{Path: sh.Bash, Args: BashArgs(MapCommand(command)), Env: env, Dir: home, Timeout: timeout})
	}
	if settings.Bool(settings.DebugExec, false) {
		// Every client command, how it ended, and the start of what it said.
		to := ""
		if r.TimedOut {
			to = " timeout"
		}
		logx.Printf("exec[%d%s] %s\n  stdout: %s\n  stderr: %s", r.Status, to, clip(cmdText, 400), clip(r.Stdout, 300), clip(r.Stderr, 300))
		if r.Stdout == "" {
			_ = os.WriteFile(paths.DataDir()+string(os.PathSeparator)+"last-empty-exec.sh", []byte(cmdText), 0o600)
		}
	}
	code := r.Status
	if r.TimedOut {
		code = 124
	}
	// The home as tools here print it is /home/ubuntu to the client.
	m := vpath.Default()
	return ExecResult{200, map[string]any{"stdout": m.MapOutput(r.Stdout), "stderr": m.MapOutput(r.Stderr), "exitCode": code}}
}

// BashArgs is how a command runs: no profile, no rc (the client's text
// sets up what it needs), on Windows and elsewhere alike.
func BashArgs(command string) []string {
	return []string{"--noprofile", "--norc", "-c", command}
}

// RunShell runs a script of our own under bash (worktrees, merges) in dir.
func RunShell(script, dir string, timeout time.Duration) Result {
	sh := FindShell()
	if sh == nil {
		return Result{Status: 127, Stderr: MissingShell}
	}
	if dir != "" && runtime.GOOS == "windows" {
		if real, err := vpath.Default().ToReal(dir); err == nil {
			dir = real
		}
	}
	return RunProc(ProcSpec{Path: sh.Bash, Args: BashArgs(script), Env: CommandEnv(), Dir: dir, Timeout: timeout})
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

func stringList(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		if s, ok := v.([]string); ok {
			return s
		}
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, x := range arr {
		s, ok := x.(string)
		if !ok {
			return nil
		}
		out = append(out, s)
	}
	return out
}
