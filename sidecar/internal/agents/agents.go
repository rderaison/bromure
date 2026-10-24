// Package agents is the coding agents the Sidecar can run: what each is,
// where it is installed (AgentDetection.swift, with exec.LookPath-style
// lookup and `--version` instead of a POSIX script), how its maker's own
// installer runs (AgentInstaller.swift), and its headless device-code
// sign-in (AgentLogin.swift). Bromure never ships or hosts an agent.
package agents

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Spec is one agent.
type Spec struct {
	ID    string `json:"id"` // the command: claude, codex, grok, kimi, omp
	Name  string `json:"name"`
	Maker string `json:"maker"`
	Blurb string `json:"blurb"`
	// Install is the maker's documented installer for this OS ("" when
	// there is none here yet).
	Install string `json:"install,omitempty"`
	// FullyIntegrated: live status, chat and delegation (hooks + MCP).
	FullyIntegrated bool `json:"fullyIntegrated"`
	// Unavailable explains why it can't run on this OS (greyed out).
	Unavailable string `json:"unavailable,omitempty"`
}

// NotOnWindows is the tray's label for an agent not verified on Windows.
const NotOnWindows = "Not available on Windows yet"

// All is every agent, in menu order. Install commands checked against
// each maker's docs; on Windows Claude Code's PowerShell installer
// (per-user, %USERPROFILE%\.local\bin\claude.exe) and Codex through npm —
// always wrapped by Socket's CLI, never a bare `npm install`.
func All() []Spec {
	win := runtime.GOOS == "windows"
	specs := []Spec{
		{ID: "claude", Name: "Claude Code", Maker: "Anthropic",
			Blurb:           "Anthropic's coding agent. Fully integrated: live status, chat, rooms and delegation.",
			Install:         "curl -fsSL https://claude.ai/install.sh | bash",
			FullyIntegrated: true},
		{ID: "codex", Name: "Codex", Maker: "OpenAI",
			Blurb:   "OpenAI's coding agent for the terminal.",
			Install: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"},
		{ID: "grok", Name: "Grok Build", Maker: "xAI",
			Blurb:   "xAI's coding agent harness, a full-screen terminal UI.",
			Install: "curl -fsSL https://x.ai/cli/install.sh | bash"},
		{ID: "kimi", Name: "Kimi Code", Maker: "Moonshot AI",
			Blurb:   "Moonshot's coding agent, a single binary (international edition).",
			Install: "curl -fsSL https://code.kimi.ai/kimi-code/install.sh | bash"},
		{ID: "omp", Name: "Oh My Pi", Maker: "Open source",
			Blurb:   "A terminal coding agent with an IDE's tools wired in.",
			Install: "curl -fsSL https://omp.sh/install | sh"},
	}
	if win {
		for i := range specs {
			switch specs[i].ID {
			case "claude":
				specs[i].Install = `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"`
			case "codex":
				specs[i].Install = "npx --yes @socketsecurity/cli npm install -g @openai/codex"
			default:
				// Not verified on Windows: greyed out, never blocking v1.
				specs[i].Install = ""
				specs[i].Unavailable = NotOnWindows
			}
		}
	}
	return specs
}

// Get is one agent's spec.
func Get(id string) (Spec, bool) {
	for _, s := range All() {
		if s.ID == id {
			return s, true
		}
	}
	return Spec{}, false
}

// Tools are the agent commands, in order.
var Tools = []string{"claude", "codex", "grok", "kimi", "omp"}

// ExtraDirs is where installers put their binaries beyond the PATH (a
// fresh install isn't on the daemon's PATH until the next login).
func ExtraDirs() []string {
	home := paths.Home()
	if runtime.GOOS == "windows" {
		return []string{
			filepath.Join(home, ".local", "bin"),
			filepath.Join(os.Getenv("APPDATA"), "npm"),
			filepath.Join(home, ".bun", "bin"),
			filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "claude"),
			filepath.Join(home, ".codex", "bin"),
		}
	}
	return []string{filepath.Join(home, ".local", "bin"), filepath.Join(home, ".grok", "bin"),
		filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".omp", "bin"),
		filepath.Join(home, ".kimi-code", "bin"), filepath.Join(home, ".kimi", "bin"),
		filepath.Join(home, ".codex", "bin"), "/opt/homebrew/bin", "/usr/local/bin"}
}

// searchPath is the agent environment's PATH plus the installers' folders.
func searchPath() string {
	parts := []string{hostexec.EnvGet(hostexec.AgentEnv(), "PATH")}
	parts = append(parts, ExtraDirs()...)
	return strings.Join(parts, string(os.PathListSeparator))
}

// Find is the agent's executable, "" when it isn't installed.
func Find(tool string) string {
	p, err := hostexec.LookPath(tool, []string{"PATH=" + searchPath()})
	if err != nil {
		return ""
	}
	return p
}

var npmShim = regexp.MustCompile(`"%dp0%\\([^"]+)"\s+%\*`)

// Command is how the agent starts without a shell: its own binary, or —
// for an npm .cmd shim on Windows — node and the package's script (no
// `cmd /c`: a batch file can't sit in a pseudoconsole cleanly, and its
// argument quoting is cmd's). nil when it isn't installed.
func Command(tool string) []string {
	p := Find(tool)
	if p == "" {
		return nil
	}
	ext := strings.ToLower(filepath.Ext(p))
	if runtime.GOOS != "windows" || (ext != ".cmd" && ext != ".bat") {
		return []string{p}
	}
	data, err := os.ReadFile(p)
	if err == nil {
		if m := npmShim.FindSubmatch(data); m != nil {
			dir := filepath.Dir(p)
			script := filepath.Join(dir, string(m[1]))
			if _, err := os.Stat(script); err == nil {
				node := filepath.Join(dir, "node.exe")
				if _, err := os.Stat(node); err != nil {
					node, _ = hostexec.LookPath("node", []string{"PATH=" + searchPath()})
				}
				if node != "" {
					return []string{node, script}
				}
			}
		}
	}
	// Some other batch file: cmd it is.
	comspec := os.Getenv("ComSpec")
	if comspec == "" {
		comspec = `C:\Windows\System32\cmd.exe`
	}
	return []string{comspec, "/d", "/c", p}
}

// --- detection -------------------------------------------------------------

// Phase is an agent's install state (the Manage Agents model).
type Phase struct {
	State   string `json:"state"` // unknown · missing · installed · queued · installing · failed · unavailable
	Version string `json:"version,omitempty"`
	Path    string `json:"path,omitempty"`
	Line    string `json:"line,omitempty"` // installing: the last output line; failed: why
}

var (
	mu      sync.Mutex
	phases  = map[string]Phase{}
	logs    = map[string]string{}
	busy    bool
	scanned bool
)

var versionRe = regexp.MustCompile(`\d+\.\d+(\.\d+)?([-.+][0-9A-Za-z.]+)?`)

// VersionNumber: "2.1.284 (Claude Code)" / "codex-cli 0.9.1" → the first
// version-looking token, else the line.
func VersionNumber(s string) string {
	t := strings.TrimSpace(s)
	if v := versionRe.FindString(t); v != "" {
		return v
	}
	if t == "" {
		return "installed"
	}
	if len(t) > 24 {
		t = t[:24]
	}
	return t
}

// detect finds one agent and asks its version (bounded: a hung --version
// still reports the agent installed).
func detect(tool string) Phase {
	if s, ok := Get(tool); ok && s.Unavailable != "" {
		if p := Find(tool); p == "" {
			return Phase{State: "unavailable", Line: s.Unavailable}
		}
	}
	argv := Command(tool)
	if argv == nil {
		return Phase{State: "missing"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], append(argv[1:], "--version")...)
	cmd.Env = hostexec.EnvSet(hostexec.AgentEnv(), "PATH", searchPath())
	hideWindow(cmd)
	out, _ := cmd.Output()
	first := strings.SplitN(strings.ReplaceAll(string(out), "\r", ""), "\n", 2)[0]
	return Phase{State: "installed", Version: VersionNumber(first), Path: Find(tool)}
}

// Scan looks for every agent (in the background when async).
func Scan() map[string]Phase {
	out := map[string]Phase{}
	var wg sync.WaitGroup
	var omu sync.Mutex
	for _, t := range Tools {
		wg.Add(1)
		go func(t string) {
			defer wg.Done()
			p := detect(t)
			omu.Lock()
			out[t] = p
			omu.Unlock()
		}(t)
	}
	wg.Wait()
	mu.Lock()
	for t, p := range out {
		cur := phases[t]
		if cur.State == "installing" || cur.State == "queued" {
			continue
		}
		if cur.State == "failed" && p.State == "missing" {
			continue // keep the error visible
		}
		phases[t] = p
	}
	scanned = true
	mu.Unlock()
	return out
}

// Phases is the current model (a first call scans).
func Phases() map[string]Phase {
	mu.Lock()
	first := !scanned
	mu.Unlock()
	if first {
		Scan()
	}
	mu.Lock()
	defer mu.Unlock()
	out := map[string]Phase{}
	for _, t := range Tools {
		p, ok := phases[t]
		if !ok {
			p = Phase{State: "unknown"}
		}
		out[t] = p
	}
	return out
}

// IsKnownMissing: a scan didn't find it, and it still isn't on disk (a
// stale verdict never refuses a start).
func IsKnownMissing(tool string) bool {
	mu.Lock()
	p, ok := phases[tool]
	mu.Unlock()
	if !ok || (p.State != "missing" && p.State != "unavailable") {
		return false
	}
	if Find(tool) != "" {
		logx.Printf("agents: %s found on disk after a scan missed it; rescanning", tool)
		go Scan()
		return false
	}
	return true
}

// Log is an agent's installer output.
func Log(tool string) string {
	mu.Lock()
	defer mu.Unlock()
	return logs[tool]
}

// InstallState is the whole model for the tray / ctl.
func InstallState() map[string]any {
	ph := Phases()
	mu.Lock()
	defer mu.Unlock()
	list := []map[string]any{}
	for _, s := range All() {
		list = append(list, map[string]any{"spec": s, "phase": ph[s.ID]})
	}
	return map[string]any{"agents": list, "busy": busy}
}
