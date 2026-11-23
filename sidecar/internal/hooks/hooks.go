// Package hooks is Claude Code's hooks for sessions this host launches,
// passed with `--settings` so the user's own ~/.claude/settings.json is
// never edited (ClaudeHooks.swift). Same events and states as Bromure
// AC's managed hooks: prompt/tool → working, Stop → done, Notification →
// needsInput, plus the AskUserQuestion dump a remote reader shows while the
// picker is up — folded into `__hook` itself (no POSIX snippet).
package hooks

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// HookCommand is the command line Claude runs: the stable executable,
// quoted, with forward slashes (it survives both Git Bash and cmd).
func HookCommand(state string) string {
	exe := filepath.ToSlash(hostexec.StableExecutable())
	return `"` + exe + `" __hook ` + state
}

// WriteSettings writes claude-settings.json and claude-mcp.json.
func WriteSettings() error {
	hook := func(state string) map[string]any {
		return map[string]any{"hooks": []any{map[string]any{"type": "command", "command": HookCommand(state)}}}
	}
	pqPre := map[string]any{"matcher": "AskUserQuestion", "hooks": []any{map[string]any{"type": "command", "command": HookCommand("pq-save")}}}
	pqClear := map[string]any{"hooks": []any{map[string]any{"type": "command", "command": HookCommand("pq-clear")}}}
	pqPost := map[string]any{"matcher": "AskUserQuestion", "hooks": pqClear["hooks"]}
	settings := map[string]any{
		// Agent-to-agent traffic never waits on a permission prompt. The
		// files other agents hand over do (the home's ~/.bromure/inbox is
		// shared by every session here: CWE-732), so they go through the
		// approval mode like any file outside the session's folder.
		"permissions": map[string]any{"allow": []string{"mcp__delegation"}},
		"hooks": map[string]any{
			"SessionStart":     []any{hook("done")},
			"UserPromptSubmit": []any{hook("working")},
			"PreToolUse":       []any{hook("working"), pqPre},
			"PostToolUse":      []any{pqPost},
			"Stop":             []any{hook("done"), pqClear},
			"Notification":     []any{hook("needsInput")},
		},
	}
	if err := writeJSON(paths.ClaudeSettings(), settings); err != nil {
		return err
	}
	// The delegation MCP: this binary, relaying to a connected Bromure AC.
	mcp := map[string]any{"mcpServers": map[string]any{"delegation": map[string]any{
		"command": hostexec.StableExecutable(), "args": []string{"__mcp-delegation"}, "alwaysLoad": true}}}
	return writeJSON(paths.ClaudeMCPConfig(), mcp)
}

func writeJSON(p string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(p+".tmp", data, 0o644); err != nil {
		return err
	}
	return os.Rename(p+".tmp", p)
}

// Report is what the hook tells the daemon (`POST /sidecar/hook`).
type Report struct {
	Window       int    `json:"window"`
	Pane         string `json:"pane,omitempty"`
	State        string `json:"state"`
	Transcript   string `json:"transcript,omitempty"`   // virtual
	AgentSession string `json:"agentSession,omitempty"` // Claude's session id
}

// Run is `bromure-sidecar __hook <state>`, run by Claude inside its
// window: report the status and transcript to the daemon, pin the
// transcript where a fat client's chat view looks for it, and keep the
// AskUserQuestion dump. Never fails Claude: always exit 0.
func Run(state string, stdin io.Reader) int {
	logx.Quiet()
	win, ok := windowIndex()
	input, _ := io.ReadAll(io.LimitReader(stdin, 8<<20))
	var js map[string]any
	_ = json.Unmarshal(input, &js)
	switch state {
	case "pq-save":
		savePQ(js, input)
		return 0
	case "pq-clear":
		clearPQ(js)
		return 0
	}
	if !ok {
		return 0
	}
	// Notification fires for more than questions: idle_prompt is "done";
	// only a real prompt is needsInput; other notices say nothing.
	if state == "needsInput" {
		if t, _ := js["notification_type"].(string); t != "" {
			switch t {
			case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			case "idle_prompt":
				state = "done"
			default:
				return 0
			}
		}
	}
	r := Report{Window: win, Pane: os.Getenv("TMUX_PANE"), State: state}
	if t, _ := js["transcript_path"].(string); t != "" {
		r.Transcript = vpath.Default().MustVirtual(t)
	}
	r.AgentSession, _ = js["session_id"].(string)
	if status, _, err := ctlclient.Do("POST", "/sidecar/hook", r, 5*time.Second); err != nil || status != 200 {
		logx.Printf("hook: couldn't report %s for window %d (status %d): %v", state, win, status, err)
	}
	if r.Transcript != "" {
		PinTranscript(win, r.Pane, r.Transcript)
	}
	return 0
}

// windowIndex is the window the hook runs in: BROMURE_WINDOW (the pane
// host sets it), else TMUX_PANE's number.
func windowIndex() (int, bool) {
	if v := os.Getenv("BROMURE_WINDOW"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n, true
		}
	}
	return 0, false
}

// PinTranscript writes ~/.bromure/transcript-<idx>.path: the virtual
// path, then "<pane id> <boot id>" — no boot id here (`cat
// /proc/sys/kernel/random/boot_id` fails under Git Bash and on macOS), so
// it's empty, which is what the client compares against.
func PinTranscript(win int, pane, transcript string) {
	dir := paths.BromureHome()
	_ = os.MkdirAll(dir, 0o755)
	// Line 1 as bash here opens it (/c/Users/me/… — Git Bash has no
	// /home/ubuntu): the client reads it with `sed` and tests it with
	// `[ -f ]` inside an exec, whose output maps it back to /home/ubuntu.
	record := vpath.Default().MapForBash(transcript) + "\n" + pane + " \n"
	p := filepath.Join(dir, "transcript-"+strconv.Itoa(win)+".path")
	_ = os.WriteFile(p+".tmp", []byte(record), 0o644)
	_ = os.Rename(p+".tmp", p)
}

// PQFile is the pending-question dump for a folder: ~/.bromure/pq-<enc>.json
// where enc is the VIRTUAL cwd with '.' and '/' as '-' (how the client
// names it from its own path: `tr './' '--'` on $(pwd)).
func PQFile(virtualCwd string) string {
	enc := strings.NewReplacer(".", "-", "/", "-").Replace(virtualCwd)
	return filepath.Join(paths.BromureHome(), "pq-"+enc+".json")
}

func hookCwd(js map[string]any) string {
	cwd, _ := js["cwd"].(string)
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	return vpath.Default().MustVirtual(cwd)
}

func savePQ(js map[string]any, raw []byte) {
	_ = os.MkdirAll(paths.BromureHome(), 0o755)
	_ = os.WriteFile(PQFile(hookCwd(js)), raw, 0o644)
}

func clearPQ(js map[string]any) {
	_ = os.Remove(PQFile(hookCwd(js)))
}
