package sessions

import (
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/agents"
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// Window options the engine reads and writes (Tmux.swift's fields).
const (
	OptDisplay      = "@display"
	OptSession      = "@bromure_session"
	OptStatus       = "@bromure_status"
	OptTranscript   = "@bromure_transcript"
	OptAgentSession = "@bromure_agent_session"
	OptWorktree     = "@worktree"
	OptParentBranch = "@parent_branch"
	OptRootRepo     = "@root_repo"
)

// Window is one pane host window as the engine sees it (paths virtual).
type Window struct {
	Index          int
	Name           string
	Display        string
	Cwd            string
	PaneID         string
	PID            int
	StartedAt      time.Time
	Alive          bool
	ExitCode       *int
	Active         bool
	Status         string
	SessionID      string
	TranscriptPath string
	AgentSessionID string
	Worktree       string
	ParentBranch   string
	RootRepo       string
}

// Title is the display name when set by us, else the window name.
func (w Window) Title() string {
	if w.Display != "" {
		return w.Display
	}
	return w.Name
}

// AgentProc is the agent running in a window.
type AgentProc struct {
	Tool      string
	PID       int
	StartedAt time.Time
}

// Snapshot is the sessions reconciled against the live windows.
type Snapshot struct {
	Sessions []Session
	Windows  []Window
	Agents   map[int]AgentProc
	// Agents on a screen that waits for the user before any hook ran
	// (Claude's folder-trust dialog runs before its hooks exist).
	Prompting map[int]bool
	PanesUp   bool
}

// Engine owns the sessions.
type Engine struct {
	HostID  string
	connect func() (panes.Client, error)

	mu           sync.Mutex
	client       panes.Client
	sessions     []Session
	lastWindows  []Window
	lastAgents   map[int]AgentProc
	lastPrompt   map[int]bool
	lastRefresh  time.Time
	panesUp      bool
	onChange     []func()
	saveDisabled bool
}

// New loads sessions.json and the host id.
func New(connect func() (panes.Client, error)) *Engine {
	e := &Engine{connect: connect, lastAgents: map[int]AgentProc{}, lastPrompt: map[int]bool{}}
	if data, err := os.ReadFile(paths.HostIDFile()); err == nil && ParseUUID(string(data)) != "" {
		e.HostID = ParseUUID(string(data))
	} else {
		e.HostID = NewUUID()
		_ = os.WriteFile(paths.HostIDFile(), []byte(e.HostID), 0o600)
	}
	if data, err := os.ReadFile(paths.SessionsFile()); err == nil {
		var list []Session
		if json.Unmarshal(data, &list) == nil {
			e.sessions = list
		}
	}
	return e
}

// OnChange registers a callback for session list changes.
func (e *Engine) OnChange(f func()) {
	e.mu.Lock()
	e.onChange = append(e.onChange, f)
	e.mu.Unlock()
}

func (e *Engine) notify() {
	e.mu.Lock()
	fs := append([]func(){}, e.onChange...)
	e.mu.Unlock()
	for _, f := range fs {
		go f()
	}
}

// Panes is a live pane host client (reconnected when it dropped).
func (e *Engine) Panes() (panes.Client, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.panesLocked()
}

func (e *Engine) panesLocked() (panes.Client, error) {
	if e.client != nil {
		return e.client, nil
	}
	c, err := e.connect()
	if err != nil {
		return nil, err
	}
	e.client = c
	return c, nil
}

// withPanes runs f with a client; a transport error drops the client so
// the next call reconnects.
func (e *Engine) withPanes(f func(panes.Client) error) error {
	c, err := e.Panes()
	if err != nil {
		return err
	}
	err = f(c)
	if err != nil && isTransport(err) {
		e.mu.Lock()
		if e.client == c {
			e.client.Close()
			e.client = nil
		}
		e.mu.Unlock()
	}
	return err
}

func isTransport(err error) bool {
	s := err.Error()
	for _, w := range []string{"broken pipe", "connection", "EOF", "closed", "forcibly", "reset"} {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

// --- snapshot --------------------------------------------------------------

// Snapshot reconciles at most every half second, however many clients poll.
func (e *Engine) Snapshot() Snapshot {
	e.mu.Lock()
	stale := time.Since(e.lastRefresh) > 500*time.Millisecond
	e.mu.Unlock()
	if stale {
		e.refresh()
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return Snapshot{
		Sessions:  append([]Session{}, e.sessions...),
		Windows:   append([]Window{}, e.lastWindows...),
		Agents:    copyMap(e.lastAgents),
		Prompting: copyMap(e.lastPrompt),
		PanesUp:   e.panesUp,
	}
}

func copyMap[K comparable, V any](m map[K]V) map[K]V {
	out := make(map[K]V, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// Session is one session by id.
func (e *Engine) Session(id string) (Session, bool) {
	id = ParseUUID(id)
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sessions {
		if s.ID == id {
			return s, true
		}
	}
	return Session{}, false
}

// ListWindows is the pane host's visible windows, mapped.
func (e *Engine) ListWindows() ([]Window, error) {
	var ws []panes.Window
	err := e.withPanes(func(c panes.Client) error {
		var err error
		ws, err = c.List(false)
		return err
	})
	if err != nil {
		return nil, err
	}
	m := vpath.Default()
	out := make([]Window, 0, len(ws))
	for _, w := range ws {
		o := w.Options
		out = append(out, Window{
			Index: w.Index, Name: w.Name, Display: o[OptDisplay], Cwd: m.MustVirtual(w.Cwd),
			PaneID: w.PaneID, PID: w.PID, StartedAt: w.StartedAt, Alive: w.Alive, ExitCode: w.ExitCode,
			Active: w.Active, Status: o[OptStatus], SessionID: ParseUUID(o[OptSession]),
			TranscriptPath: o[OptTranscript], AgentSessionID: o[OptAgentSession],
			Worktree: o[OptWorktree], ParentBranch: o[OptParentBranch], RootRepo: o[OptRootRepo],
		})
	}
	return out, nil
}

func (e *Engine) refresh() {
	windows, err := e.ListWindows()
	e.mu.Lock()
	e.lastRefresh = time.Now()
	if err != nil {
		e.panesUp = false
		e.lastWindows = nil
		e.lastAgents = map[int]AgentProc{}
		e.lastPrompt = map[int]bool{}
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	agentsIn := e.runningAgents(windows)
	prompting := map[int]bool{}
	for _, w := range windows {
		if _, ok := agentsIn[w.Index]; ok && w.Status == "" && e.waitsOnUser(w.Index) {
			prompting[w.Index] = true
		}
	}
	e.mu.Lock()
	e.panesUp = true
	e.lastWindows = windows
	e.lastAgents = agentsIn
	e.lastPrompt = prompting
	changed := e.reconcileLocked(windows, agentsIn)
	e.mu.Unlock()
	if changed {
		e.notify()
	}
}

// reconcileLocked binds sessions to windows; true when anything changed.
func (e *Engine) reconcileLocked(windows []Window, agentsIn map[int]AgentProc) bool {
	before, _ := json.Marshal(e.sessions)
	now := Now()
	byID := map[string]Window{}
	for _, w := range windows {
		if w.SessionID != "" {
			if _, dup := byID[w.SessionID]; !dup {
				byID[w.SessionID] = w
			}
		}
	}
	for i := range e.sessions {
		s := &e.sessions[i]
		if w, ok := byID[s.ID]; ok {
			_, hasAgent := agentsIn[w.Index]
			s.WindowIndex = ptr(w.Index)
			s.EndedAt = nil
			s.LastSeenAt = now
			s.AgentAlive = ptr(hasAgent)
			if hasAgent {
				s.AgentSeenAt = now
				s.LaunchingSince = nil
			}
			if w.AgentSessionID != "" {
				s.AgentTranscriptID = ptr(w.AgentSessionID)
			}
			if w.TranscriptPath != "" {
				s.TranscriptPath = ptr(w.TranscriptPath)
			}
			if s.LaunchDisplay == nil {
				s.LaunchDisplay = ptr(w.Title())
			} else if w.Display != "" && w.Display == s.Title && str(s.LaunchDisplay) != w.Display {
				s.LaunchDisplay = ptr(w.Display)
			}
			// Give up on "starting" after a minute: the tab is a shell.
			if s.LaunchingSince != nil && Since(s.LaunchingSince) > time.Minute {
				s.LaunchingSince = nil
			}
		} else if s.WindowIndex != nil || s.LaunchingSince != nil {
			s.WindowIndex = nil
			s.LaunchingSince = nil
			s.AgentAlive = ptr(false)
			if s.EndedAt == nil {
				s.EndedAt = now
			}
		}
	}
	// A deleted session goes once its tab is gone.
	kept := e.sessions[:0]
	for _, s := range e.sessions {
		if s.DeletedAt != nil && s.WindowIndex == nil {
			continue
		}
		kept = append(kept, s)
	}
	e.sessions = kept
	// Adopt agents running in windows nobody claims.
	for _, w := range windows {
		if w.SessionID != "" {
			continue
		}
		a, ok := agentsIn[w.Index]
		if !ok {
			continue
		}
		s := Session{ID: NewUUID(), ProfileID: e.HostID, Tool: a.Tool,
			Title: DefaultTitle(a.Tool, w.Cwd), Cwd: w.Cwd, CreatedAt: *now}
		s.WindowIndex = ptr(w.Index)
		s.AgentAlive = ptr(true)
		s.AgentSeenAt = now
		s.LastSeenAt = now
		s.LaunchDisplay = ptr(w.Title())
		if c, err := e.panesLocked(); err == nil {
			_ = c.SetOption(w.Index, OptSession, s.ID)
		}
		e.sessions = append(e.sessions, s)
		logx.Printf("sessions: adopted %s in window %d (%s)", a.Tool, w.Index, w.Cwd)
	}
	after, _ := json.Marshal(e.sessions)
	if string(before) != string(after) {
		e.saveLocked()
		return true
	}
	return false
}

// runningAgents: which agent runs in each window — the window's process
// tree searched for a known agent program.
func (e *Engine) runningAgents(windows []Window) map[int]AgentProc {
	out := map[int]AgentProc{}
	var procs []panes.Proc
	if err := e.withPanes(func(c panes.Client) error {
		var err error
		procs, err = c.ProcTable()
		return err
	}); err != nil {
		return out
	}
	byWindow := map[int][]panes.Proc{}
	for _, p := range procs {
		byWindow[p.Window] = append(byWindow[p.Window], p)
	}
	for _, w := range windows {
		ps := byWindow[w.Index]
		// Oldest first: the agent, not a tool it spawned.
		sort.Slice(ps, func(i, j int) bool {
			if ps[i].StartedAt.Equal(ps[j].StartedAt) {
				return ps[i].PID < ps[j].PID
			}
			return ps[i].StartedAt.Before(ps[j].StartedAt)
		})
		for _, p := range ps {
			if tool := AgentTool(p.Args); tool != "" {
				out[w.Index] = AgentProc{Tool: tool, PID: p.PID, StartedAt: p.StartedAt}
				break
			}
		}
	}
	return out
}

var exeSuffix = regexp.MustCompile(`(?i)\.(exe|cmd|bat|ps1|js|mjs|cjs)$`)

// baseName is a program's name without folder or extension, either
// separator.
func baseName(p string) string {
	p = strings.Trim(p, `"`)
	if i := strings.LastIndexAny(p, `/\`); i >= 0 {
		p = p[i+1:]
	}
	return exeSuffix.ReplaceAllString(p, "")
}

// AgentTool is the agent a command line runs, if any: its program (first
// word, or the script an interpreter runs) named after a known agent, or
// Claude's versioned native binary / npm package, or a packaged binary
// named for its agent (codex-x86_64-pc-windows-msvc.exe).
func AgentTool(args string) string {
	words := splitArgs(args)
	if len(words) == 0 {
		return ""
	}
	first := strings.ReplaceAll(words[0], `\`, "/")
	if strings.Contains(first, "/claude/versions/") {
		return "claude"
	}
	cands := []string{words[0]}
	if b := strings.ToLower(baseName(words[0])); b == "node" || b == "bun" {
		for _, w := range words[1:] {
			if strings.HasPrefix(w, "-") {
				continue
			}
			cands = append(cands, w)
			break
		}
	}
	for _, c := range cands {
		b := strings.ToLower(baseName(c))
		for _, t := range agents.Tools {
			if b == t || strings.HasPrefix(b, t+"-x86_64-") || strings.HasPrefix(b, t+"-aarch64-") {
				return t
			}
		}
		cs := strings.ReplaceAll(c, `\`, "/")
		if strings.Contains(cs, "/claude-code/") {
			return "claude"
		}
		if strings.Contains(cs, "/@openai/codex/") {
			return "codex"
		}
	}
	return ""
}

// splitArgs splits a command line on spaces, honouring double quotes
// (Windows command lines quote paths with spaces).
func splitArgs(s string) []string {
	var out []string
	var b strings.Builder
	inQ := false
	for _, r := range s {
		switch {
		case r == '"':
			inQ = !inQ
		case r == ' ' && !inQ:
			if b.Len() > 0 {
				out = append(out, b.String())
				b.Reset()
			}
		default:
			b.WriteRune(r)
		}
	}
	if b.Len() > 0 {
		out = append(out, b.String())
	}
	return out
}

// waitsOnUser: a picker on screen ("Enter to confirm", Claude's trust dialog).
func (e *Engine) waitsOnUser(idx int) bool {
	var screen string
	_ = e.withPanes(func(c panes.Client) error {
		var err error
		screen, err = c.Capture(idx, panes.CaptureOptions{Join: true})
		return err
	})
	return strings.Contains(screen, "Enter to confirm") || strings.Contains(screen, "trust this folder")
}

// DefaultTitle is "Claude in <folder>".
func DefaultTitle(tool, cwd string) string {
	name := tool
	if name != "" {
		name = strings.ToUpper(name[:1]) + name[1:]
	}
	folder := path.Base(cwd)
	if folder == "." || folder == "/" || folder == "" {
		return name
	}
	return name + " in " + folder
}

// Title is a session's name from its opening message.
func Title(message, tool, cwd string) string {
	first := strings.TrimSpace(strings.SplitN(message, "\n", 2)[0])
	if first == "" {
		return DefaultTitle(tool, cwd)
	}
	if r := []rune(first); len(r) > 60 {
		return string(r[:57]) + "…"
	}
	return first
}

// --- persistence -----------------------------------------------------------

func (e *Engine) saveLocked() {
	if e.saveDisabled {
		return
	}
	data, err := json.MarshalIndent(e.sessions, "", "  ")
	if err != nil {
		return
	}
	p := paths.SessionsFile()
	_ = os.WriteFile(p+".tmp", data, 0o600)
	_ = os.Rename(p+".tmp", p)
}

func (e *Engine) update(id string, change func(*Session)) {
	e.mu.Lock()
	changed := false
	for i := range e.sessions {
		if e.sessions[i].ID == id {
			before := clone(e.sessions[i])
			change(&e.sessions[i])
			if !equal(before, e.sessions[i]) {
				e.saveLocked()
				changed = true
			}
			break
		}
	}
	e.mu.Unlock()
	if changed {
		e.notify()
	}
}

func (e *Engine) put(s Session) {
	e.mu.Lock()
	found := false
	for i := range e.sessions {
		if e.sessions[i].ID == s.ID {
			e.sessions[i] = s
			found = true
		}
	}
	if !found {
		e.sessions = append(e.sessions, s)
	}
	e.saveLocked()
	e.lastRefresh = time.Time{}
	e.mu.Unlock()
	e.notify()
}

// --- folders ---------------------------------------------------------------

// Folders lists the sub-folders of a virtual path (not hidden), in
// Finder order.
func Folders(v string) []string {
	dir, err := vpath.Default().ToReal(v)
	if err != nil {
		return []string{}
	}
	items, err := os.ReadDir(dir)
	out := []string{}
	if err != nil {
		return out
	}
	for _, it := range items {
		if strings.HasPrefix(it.Name(), ".") {
			continue
		}
		full := filepath.Join(dir, it.Name())
		st, err := os.Stat(full)
		if err != nil || !st.IsDir() || isHidden(full) {
			continue
		}
		out = append(out, it.Name())
	}
	sort.Slice(out, func(i, j int) bool { return naturalLess(out[i], out[j]) })
	return out
}

// naturalLess is localizedStandardCompare's order: case-insensitive, digit
// runs compared as numbers.
func naturalLess(a, b string) bool {
	ra, rb := []rune(strings.ToLower(a)), []rune(strings.ToLower(b))
	i, j := 0, 0
	for i < len(ra) && j < len(rb) {
		if isDigit(ra[i]) && isDigit(rb[j]) {
			si := i
			for i < len(ra) && isDigit(ra[i]) {
				i++
			}
			sj := j
			for j < len(rb) && isDigit(rb[j]) {
				j++
			}
			na := strings.TrimLeft(string(ra[si:i]), "0")
			nb := strings.TrimLeft(string(rb[sj:j]), "0")
			if len(na) != len(nb) {
				return len(na) < len(nb)
			}
			if na != nb {
				return na < nb
			}
			continue
		}
		if ra[i] != rb[j] {
			return ra[i] < rb[j]
		}
		i++
		j++
	}
	if len(ra)-i != len(rb)-j {
		return len(ra)-i < len(rb)-j
	}
	return a < b
}

func isDigit(r rune) bool { return r >= '0' && r <= '9' }

// --- launching -------------------------------------------------------------

// Approvals is how each agent asks before acting (AgentApprovals).
func Approvals(tool string) string {
	return approvalsLevel(tool)
}

// LaunchSpec is how a window starts its agent.
type LaunchSpec struct {
	Argv    []string
	Cmdline string
}

// Launch is the agent's command (Sessions.launchCommand). resume nil: a
// fresh start; "" continue the folder's last; else that conversation.
func Launch(tool string, message *string, resume *string, cloneURL string, extraArgs []string) (LaunchSpec, error) {
	prog := agents.Command(tool)
	if prog == nil {
		name := tool
		if s, ok := agents.Get(tool); ok {
			name = s.Name
		}
		return LaunchSpec{}, bad("%s isn't installed on this machine. Install it from Agents in the Bromure Sidecar menu.", name)
	}
	argv := append([]string{}, prog...)
	switch tool {
	case "claude":
		argv = append(argv, "--settings", paths.ClaudeSettings(),
			// `=` form: the flag takes several values and would swallow the
			// prompt that follows as another config file.
			"--mcp-config="+paths.ClaudeMCPConfig())
		if resume != nil {
			if *resume == "" {
				argv = append(argv, "--continue")
			} else {
				argv = append(argv, "--resume", *resume)
			}
		}
	case "codex":
		argv = append(argv, CodexMCPFlags()...)
		if resume != nil {
			if *resume == "" {
				argv = append(argv, "resume", "--last")
			} else {
				argv = append(argv, "resume", *resume)
			}
		}
	}
	argv = append(argv, ApprovalFlags(tool)...)
	argv = append(argv, extraArgs...)
	if message != nil {
		argv = append(argv, vpath.Default().MapTextToReal(*message))
	}
	if cloneURL == "" {
		if runtime.GOOS != "windows" {
			// Under the user's login shell (their PATH, nvm…), leaving a
			// shell in the tab when the agent exits.
			return LaunchSpec{Argv: wrapUnix(argv)}, nil
		}
		return LaunchSpec{Argv: argv}, nil
	}
	// A clone first: through bash, then the agent in the clone.
	sh := hostexec.FindShell()
	if sh == nil {
		return LaunchSpec{}, bad("%s", hostexec.MissingShell)
	}
	folder := strings.TrimSuffix(path.Base(strings.ReplaceAll(cloneURL, `\`, "/")), ".git")
	quoted := make([]string, len(argv))
	for i, a := range argv {
		quoted[i] = shQuote(a)
	}
	inner := "git clone " + shQuote(cloneURL) + " && cd " + shQuote(folder) + " && exec " + strings.Join(quoted, " ")
	return LaunchSpec{Argv: []string{sh.Bash, "--noprofile", "--norc", "-c", inner}}, nil
}

func wrapUnix(argv []string) []string {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/bash"
	}
	q := make([]string, len(argv))
	for i, a := range argv {
		q[i] = shQuote(a)
	}
	return []string{sh, "-l", "-i", "-c", strings.Join(q, " ") + "; exec " + shQuote(sh) + " -l"}
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// CodexMCPFlags is Codex's delegation MCP as per-launch `-c` overrides
// (~/.codex/config.toml is never touched). Codex hands MCP servers a
// filtered environment: the window variables must be allow-listed.
func CodexMCPFlags() []string {
	js := func(v any) string {
		var b strings.Builder
		enc := json.NewEncoder(&b)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(v)
		return strings.TrimSpace(b.String())
	}
	prefix := "mcp_servers.delegation."
	kv := []string{
		prefix + "command=" + js(hostexec.StableExecutable()),
		prefix + "args=" + js([]string{"__mcp-delegation"}),
		prefix + "env_vars=" + js([]string{"TMUX", "TMUX_PANE", "BROMURE_WINDOW", "BROMURE_CONTROL"}),
		// Agent-to-agent traffic never waits on an approval prompt.
		prefix + "default_tools_approval_mode=" + js("approve"),
	}
	for _, o := range CodexOverrides() {
		kv = append(kv, o[0]+"="+js(o[1]))
	}
	out := []string{}
	for _, s := range kv {
		out = append(out, "-c", s)
	}
	return out
}

// newWindow opens a window for a session's agent.
func (e *Engine) newWindow(cwdV, name string, ls LaunchSpec, options map[string]string) (int, error) {
	cwd, err := vpath.Default().ToReal(cwdV)
	if err != nil {
		return 0, err
	}
	var w panes.Window
	err = e.withPanes(func(c panes.Client) error {
		var err error
		w, err = c.NewWindow(panes.NewWindowRequest{Name: name, Argv: ls.Argv, Cmdline: ls.Cmdline,
			Cwd: cwd, Env: hostexec.AgentEnv(), Options: options})
		return err
	})
	if err != nil {
		logx.Printf("panes: new-window failed: %v", err)
		return 0, err
	}
	return w.Index, nil
}

func (e *Engine) setOption(idx int, k, v string) {
	_ = e.withPanes(func(c panes.Client) error { return c.SetOption(idx, k, v) })
}

func (e *Engine) killWindow(idx int) {
	_ = e.withPanes(func(c panes.Client) error { return c.KillWindow(idx) })
}

// SelectWindow / KillWindow / NewShell are the `/sessions/:id/tab` actions.
func (e *Engine) SelectWindow(idx int) {
	_ = e.withPanes(func(c panes.Client) error { return c.SelectWindow(idx) })
}
func (e *Engine) KillWindow(idx int) { e.killWindow(idx) }

// NewShell opens a plain shell tab (Git Bash on Windows).
func (e *Engine) NewShell() error {
	var argv []string
	if sh := hostexec.FindShell(); sh != nil {
		argv = []string{sh.Bash, "--login", "-i"}
		if runtime.GOOS != "windows" {
			if s := os.Getenv("SHELL"); s != "" {
				argv = []string{s, "-l"}
			}
		}
	} else if runtime.GOOS == "windows" {
		argv = []string{"powershell.exe", "-NoLogo"}
	} else {
		return failed("no shell")
	}
	return e.withPanes(func(c panes.Client) error {
		// The user's own shell: their environment (with bin/ for tmux and
		// ps), normal MSYS path conversion.
		env := hostexec.EnvSet(hostexec.AgentEnv(), "PATH", hostexec.EnvGet(hostexec.CommandEnv(), "PATH"))
		_, err := c.NewWindow(panes.NewWindowRequest{Name: "shell", Argv: argv, Cwd: paths.Home(), Env: env})
		return err
	})
}
