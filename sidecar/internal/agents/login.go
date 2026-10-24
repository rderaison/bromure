package agents

import (
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Panes is how a sign-in reaches the pane host (set by the daemon). Each
// sign-in runs in a hidden window there: the CLIs draw with Ink/ratatui and
// want a terminal (the macOS Sidecar used `script` for its pty).
var Panes func() (panes.Client, error)

// LoginCommand is each CLI's headless login. Claude has no device flow:
// its page shows a code the user pastes back. Kimi: the international region.
func LoginCommand(tool string) (args []string, paste bool, ok bool) {
	switch tool {
	case "claude":
		return []string{"auth", "login", "--claudeai"}, true, true
	case "codex":
		return []string{"login", "--device-auth"}, false, true
	case "grok":
		return []string{"login", "--device-auth"}, false, true
	case "kimi":
		return []string{"login", "--region", "global"}, false, true
	}
	return nil, false, false
}

type login struct {
	Tool       string
	Phase      string // starting · waiting · done · failed
	URL        string
	Code       string
	NeedsPaste bool
	Message    string
	StartedAt  time.Time
	window     int
	cancel     chan struct{}
}

func (l *login) json() map[string]any {
	d := map[string]any{"tool": l.Tool, "phase": l.Phase, "needsPaste": l.NeedsPaste,
		"startedAt": float64(l.StartedAt.UnixNano()) / 1e9}
	if l.URL != "" {
		d["url"] = l.URL
	}
	if l.Code != "" {
		d["code"] = l.Code
	}
	if l.Message != "" {
		d["message"] = l.Message
	}
	return d
}

var (
	lmu    sync.Mutex
	logins = map[string]*login{}
)

// LoginError is a sign-in that can't run (501 / 400).
type LoginError struct {
	Status  int
	Message string
}

func (e *LoginError) Error() string { return e.Message }

// LoginState is `tool`'s sign-in.
func LoginState(tool string) map[string]any {
	lmu.Lock()
	defer lmu.Unlock()
	if l := logins[tool]; l != nil {
		return l.json()
	}
	return map[string]any{"tool": tool, "phase": "idle"}
}

// StartLogin starts (or rejoins) `tool`'s sign-in; its state.
func StartLogin(tool string) (map[string]any, error) {
	args, paste, ok := LoginCommand(tool)
	if !ok {
		if tool == "omp" {
			return nil, &LoginError{501, "Oh My Pi uses an API key, not an account: run `omp` in the session's terminal and follow its setup."}
		}
		return nil, &LoginError{501, tool + " has no sign-in Bromure can run"}
	}
	lmu.Lock()
	if l := logins[tool]; l != nil && (l.Phase == "starting" || l.Phase == "waiting") {
		defer lmu.Unlock()
		return l.json(), nil
	}
	l := &login{Tool: tool, Phase: "starting", NeedsPaste: paste, StartedAt: time.Now(), window: -1, cancel: make(chan struct{})}
	logins[tool] = l
	lmu.Unlock()

	fail := func(msg string) (map[string]any, error) {
		lmu.Lock()
		l.Phase, l.Message = "failed", msg
		lmu.Unlock()
		return LoginState(tool), nil
	}
	argv := Command(tool)
	if argv == nil {
		return fail("Couldn't start the sign-in: " + tool + " isn't installed.")
	}
	if Panes == nil {
		return fail("Couldn't start the sign-in: no pane host.")
	}
	c, err := Panes()
	if err != nil {
		return fail("Couldn't start the sign-in: " + err.Error())
	}
	env := hostexec.AgentEnv()
	env = hostexec.EnvSet(env, "NO_COLOR", "1")
	// No browser pops up on this machine's screen for a user who isn't here
	// (the CLIs that honour $BROWSER; others may still open one).
	env = hostexec.EnvSet(env, "BROWSER", "true")
	w, err := c.NewWindow(panes.NewWindowRequest{
		Name: "signin-" + tool, Argv: append(argv, args...), Cwd: paths.Home(), Env: env,
		// Wide enough that a long URL is never wrapped.
		Cols: 4000, Rows: 50, Hidden: true, KeepOnExit: true,
		Options: map[string]string{"@bromure_signin": tool},
	})
	if err != nil {
		c.Close()
		return fail("Couldn't start the sign-in: " + err.Error())
	}
	lmu.Lock()
	l.window = w.Index
	lmu.Unlock()
	logx.Printf("login: %s sign-in started (window %d)", tool, w.Index)
	go watchLogin(c, l)
	return LoginState(tool), nil
}

// watchLogin scrapes the window until the CLI exits, is cancelled, or
// 30 minutes pass (device codes last 15–30).
func watchLogin(c panes.Client, l *login) {
	defer c.Close()
	deadline := time.After(30 * time.Minute)
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-l.cancel:
			_ = c.KillWindow(l.window)
			return
		case <-deadline:
			Cancel(l.Tool, "The sign-in timed out.")
			_ = c.KillWindow(l.window)
			return
		case <-tick.C:
		}
		text, err := c.Capture(l.window, panes.CaptureOptions{StartHistory: true, Join: true})
		if err == nil {
			absorb(l, text)
		}
		w, err := c.Get(l.window)
		if err != nil || !w.Alive {
			code := -1
			if err == nil && w.ExitCode != nil {
				code = *w.ExitCode
			}
			finish(l, code, text)
			_ = c.KillWindow(l.window)
			return
		}
	}
}

func absorb(l *login, screen string) {
	text := Plain(screen)
	lmu.Lock()
	defer lmu.Unlock()
	if l.URL == "" {
		l.URL = Link(text)
	}
	if l.Code == "" && !l.NeedsPaste {
		l.Code = UserCode(text, l.URL)
	}
	if l.Phase == "starting" && l.URL != "" && (l.NeedsPaste || l.Code != "") {
		l.Phase = "waiting"
	}
}

func finish(l *login, status int, output string) {
	lmu.Lock()
	defer lmu.Unlock()
	if l.Phase != "starting" && l.Phase != "waiting" {
		return
	}
	if status == 0 {
		l.Phase = "done"
	} else {
		l.Phase = "failed"
		l.Message = LastLine(Plain(output))
		if l.Message == "" {
			l.Message = "The sign-in didn't complete."
		}
	}
	logx.Printf("login: %s sign-in ended (%d)", l.Tool, status)
}

// SubmitCode types Claude's pasted code into its prompt.
func SubmitCode(tool, code string) (map[string]any, error) {
	c := strings.TrimSpace(code)
	if c == "" || len(c) >= 4096 || strings.Contains(c, "\n") {
		return nil, &LoginError{400, "code required"}
	}
	lmu.Lock()
	l := logins[tool]
	lmu.Unlock()
	if l == nil || l.window < 0 || (l.Phase != "starting" && l.Phase != "waiting") {
		return nil, &LoginError{400, "no sign-in under way"}
	}
	cl, err := Panes()
	if err != nil {
		return nil, &LoginError{500, err.Error()}
	}
	defer cl.Close()
	if err := cl.SendKeys(l.window, []string{c}, true); err != nil {
		return nil, &LoginError{500, err.Error()}
	}
	_ = cl.SendKeys(l.window, []string{"Enter"}, false)
	return LoginState(tool), nil
}

// Cancel ends a sign-in under way.
func Cancel(tool string, reason string) {
	if reason == "" {
		reason = "The sign-in was cancelled."
	}
	lmu.Lock()
	defer lmu.Unlock()
	l := logins[tool]
	if l == nil || (l.Phase != "starting" && l.Phase != "waiting") {
		return
	}
	l.Phase, l.Message = "failed", reason
	select {
	case <-l.cancel:
	default:
		close(l.cancel)
	}
}

var (
	oscRe     = regexp.MustCompile("\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)")
	csiRe     = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)
	charsetRe = regexp.MustCompile(`\x1b[()][A-Z0-9]`)
	linkRe    = regexp.MustCompile(`https://[^\s"'<>\x1b]+`)
	codeRe    = regexp.MustCompile(`\b[A-Z0-9]{4,5}-[A-Z0-9]{4,6}\b`)
	urlStrip  = regexp.MustCompile(`https://\S+`)
)

// Plain is terminal output as text: OSC and CSI sequences out.
func Plain(s string) string {
	s = oscRe.ReplaceAllString(s, "")
	s = csiRe.ReplaceAllString(s, "")
	s = charsetRe.ReplaceAllString(s, "")
	return strings.ReplaceAll(s, "\r", "")
}

// Link is the first sign-in link the CLI prints (never a localhost one).
func Link(text string) string {
	for _, u := range linkRe.FindAllString(text, -1) {
		u = strings.TrimRight(u, ".,;:)]")
		if strings.Contains(u, "localhost") || strings.Contains(u, "127.0.0.1") {
			continue
		}
		return u
	}
	return ""
}

// UserCode: `user_code=` in the link, else an ABCD-EFGH-shaped token.
func UserCode(text, link string) string {
	if link != "" {
		if u, err := url.Parse(link); err == nil {
			if q := u.Query().Get("user_code"); q != "" {
				return q
			}
		}
	}
	return codeRe.FindString(urlStrip.ReplaceAllString(text, ""))
}

// LastLine is the last non-empty line.
func LastLine(text string) string {
	lines := strings.Split(text, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" && l != "^D" {
			return l
		}
	}
	return ""
}
