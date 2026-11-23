package sessions

import (
	"regexp"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// The footer phrases of every agent's menus (AgentPhrases.table .footer,
// shared and per agent).
var footerPhrases = []string{
	"↑/↓", "↑↓", "enter to select", "enter to confirm", "esc to cancel", "esc to close",
	"esc to exit", "esc close", "press enter to continue", "press enter to confirm",
	"enter to submit", "esc to go back", "↵ confirm", "enter select", "enter confirm",
	"up/down navigate", "ctrl+c:cancel",
	"enter or y to trust", // grok's trust gate
}

var menuRow = regexp.MustCompile(`(❯|▶) *[0-9]+[.)]|[0-9] \((●|○)\)`)

// MenuOpen: a menu, picker or approval dialog on a captured screen (its
// bottom 30 rows) — AgentPhrases.menuOpen.
func MenuOpen(screen string) bool {
	lines := strings.Split(screen, "\n")
	if len(lines) > 30 {
		lines = lines[len(lines)-30:]
	}
	tail := strings.ToLower(strings.Join(lines, "\n"))
	for _, p := range footerPhrases {
		if strings.Contains(tail, p) {
			return true
		}
	}
	return menuRow.MatchString(tail)
}

func (e *Engine) capture(idx int) (string, error) {
	var s string
	err := e.withPanes(func(c panes.Client) error {
		var err error
		s, err = c.Capture(idx, panes.CaptureOptions{})
		return err
	})
	return s, err
}

func (e *Engine) menuOpen(idx int) bool {
	s, err := e.capture(idx)
	return err == nil && MenuOpen(s)
}

// TypeResult is what `/vms/:id/type` reports (BROMURE_TYPE_OK / HELD /
// REFUSED).
type TypeResult string

const (
	TypeOK      TypeResult = "BROMURE_TYPE_OK"
	TypeHeld    TypeResult = "BROMURE_TYPE_HELD"
	TypeRefused TypeResult = "BROMURE_TYPE_REFUSED"
)

// Type types text into the window's prompt, then Enter — a paste
// followed by a key, as the client's own typeCommand. Never while the agent
// has a menu or approval dialog up (a digit or Return would answer it): the
// text waits — checked every few seconds for up to 10 minutes — and is
// checked again before the Enter.
func (e *Engine) Type(idx int, text string) TypeResult {
	return e.TypeWithPatience(idx, text, 10*time.Minute, true)
}

// TypeWithPatience is Type with a bounded wait; submit false pastes only.
func (e *Engine) TypeWithPatience(idx int, text string, patience time.Duration, submit bool) TypeResult {
	deadline := time.Now().Add(patience)
	for e.menuOpen(idx) {
		if time.Now().After(deadline) {
			logx.Printf("panes: a dialog stayed open in window %d — message not typed", idx)
			return TypeHeld
		}
		time.Sleep(3 * time.Second)
	}
	// Paths a client names for a Linux guest (drops, inbox) are under
	// /home/ubuntu; here they're real paths. One paste (bracketed when the
	// agent asked for it, LF kept), not keystrokes.
	body := vpath.Default().MapTextToReal(text)
	body = strings.ReplaceAll(strings.ReplaceAll(body, "\r\n", "\n"), "\r", "\n")
	before, _ := e.capture(idx)
	if err := e.withPanes(func(c panes.Client) error { return c.Paste(idx, body, true, true) }); err != nil {
		logx.Printf("panes: couldn't paste the message into window %d — not typed: %v", idx, err)
		return TypeRefused
	}
	if !submit {
		return TypeOK
	}
	// Enter only once the paste is on screen (a TUI that is still busy
	// reading it would take the Return as part of it).
	time.Sleep(600 * time.Millisecond)
	for i := 0; i < 12; i++ {
		after, err := e.capture(idx)
		if err != nil || after != before {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if e.menuOpen(idx) {
		logx.Printf("panes: a dialog opened in window %d before Enter — not submitted", idx)
		return TypeHeld
	}
	if err := e.withPanes(func(c panes.Client) error { return c.SendKeys(idx, []string{"Enter"}, false) }); err != nil {
		return TypeRefused
	}
	return TypeOK
}

// SendKeys sends tmux key names one at a time.
func (e *Engine) SendKeys(idx int, keys []string) {
	for _, k := range keys {
		_ = e.withPanes(func(c panes.Client) error { return c.SendKeys(idx, []string{k}, false) })
		time.Sleep(300 * time.Millisecond)
	}
}
