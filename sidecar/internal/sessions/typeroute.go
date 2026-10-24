package sessions

import (
	"encoding/json"
	"strings"
	"time"
	"unicode"

	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// PaneTarget is Bromure AC's PaneTarget (CodingTasks.swift) as Swift's
// Codable writes it: enums with associated values as {"case":{"_0":v}}.
type PaneTarget struct {
	Ref              map[string]map[string]any `json:"ref"`
	ExpectWorktree   *string                   `json:"expectWorktree,omitempty"`
	ExpectDisplay    *string                   `json:"expectDisplay,omitempty"`
	ExpectDisplayAlt *string                   `json:"expectDisplayAlt,omitempty"`
	ExpectWindowID   *string                   `json:"expectWindowID,omitempty"`
	Foreground       map[string]any            `json:"foreground,omitempty"`
}

// ParsePaneTarget decodes the request's `target`.
func ParsePaneTarget(raw any) (PaneTarget, bool) {
	data, err := json.Marshal(raw)
	if err != nil {
		return PaneTarget{}, false
	}
	var t PaneTarget
	if json.Unmarshal(data, &t) != nil || len(t.Ref) != 1 {
		return PaneTarget{}, false
	}
	return t, true
}

func (t PaneTarget) wantsShell() bool {
	_, shell := t.Foreground["shell"]
	return shell
}

// Markers the client reads (PaneTypeGuard).
const (
	markRefused     = "BROMURE_TYPE_REFUSED"
	markHeld        = "BROMURE_TYPE_HELD"
	markOK          = "BROMURE_TYPE_OK"
	markUnconfirmed = "BROMURE_TYPE_UNCONFIRMED"
)

// resolve is the target's window (-1 when it can't be found).
func (e *Engine) resolveTarget(t PaneTarget, ws []panes.Window) int {
	for kind, v := range t.Ref {
		switch kind {
		case "index":
			n, _ := v["_0"].(float64)
			for _, w := range ws {
				if w.Index == int(n) {
					return w.Index
				}
			}
		case "windowID":
			id, _ := v["_0"].(string)
			for _, w := range ws {
				if w.ID == id {
					return w.Index
				}
			}
		case "worktree":
			b, _ := v["_0"].(string)
			found := -1
			for _, w := range ws {
				if w.Options[OptWorktree] == b {
					found = w.Index // the newest (last) carrying it
				}
			}
			return found
		}
	}
	return -1
}

// guardTarget is PaneTypeGuard.guardFunction: "" when the window is still
// the intended one with the wanted foreground, else the refusal line.
func (e *Engine) guardTarget(t PaneTarget) (int, string) {
	var ws []panes.Window
	if err := e.withPanes(func(c panes.Client) error {
		var err error
		ws, err = c.List(false)
		return err
	}); err != nil {
		return -1, markRefused + " gone"
	}
	idx := e.resolveTarget(t, ws)
	if idx < 0 {
		return -1, markRefused + " gone"
	}
	var w panes.Window
	for _, x := range ws {
		if x.Index == idx {
			w = x
		}
	}
	if t.ExpectWindowID != nil && w.ID != *t.ExpectWindowID {
		return idx, markRefused + " identity"
	}
	if t.ExpectWorktree != nil && w.Options[OptWorktree] != *t.ExpectWorktree {
		return idx, markRefused + " identity"
	}
	if t.ExpectDisplay != nil {
		d := w.Options[OptDisplay]
		alt := t.ExpectDisplayAlt != nil && d == *t.ExpectDisplayAlt
		if d != "" && d != *t.ExpectDisplay && !alt {
			return idx, markRefused + " identity"
		}
	}
	hasAgent := e.foregroundAgent(idx) != ""
	if t.wantsShell() {
		if hasAgent {
			return idx, markRefused + " agent"
		}
	} else if !hasAgent {
		return idx, markRefused + " shell"
	}
	return idx, ""
}

// foregroundAgent is the agent among the window's foreground processes.
func (e *Engine) foregroundAgent(idx int) string {
	var procs []panes.Proc
	_ = e.withPanes(func(c panes.Client) error {
		var err error
		procs, err = c.ProcTable()
		return err
	})
	for _, p := range procs {
		if p.Window == idx && p.Foreground {
			if t := AgentTool(p.Args); t != "" {
				return t
			}
		}
	}
	// The foreground marking is the pane host's guess: any agent in the
	// window's tree counts.
	for _, p := range procs {
		if p.Window == idx {
			if t := AgentTool(p.Args); t != "" {
				return t
			}
		}
	}
	return ""
}

// CompletionSafe appends a space when the text ends in a token an agent's
// composer would complete (a path, a slash command, an @-mention, a
// $skill) — PaneTypeGuard.completionSafe.
func CompletionSafe(text string) string {
	t := strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	if t == "" {
		return text
	}
	r := []rune(t)
	if unicode.IsSpace(r[len(r)-1]) {
		return text
	}
	tokens := strings.Fields(t)
	if len(tokens) < 2 {
		return text
	}
	last := tokens[len(tokens)-1]
	if strings.ContainsRune("/@$", rune(last[0])) || strings.Contains(last, "/") {
		return text + " "
	}
	return text
}

// TypeRoute is `POST /vms/:id/type {target, text}`: the guarded type the
// client would otherwise run step by step over exec, done here. Its output
// carries the same markers PaneTypeGuard prints.
func (e *Engine) TypeRoute(t PaneTarget, text string) string {
	idx, refusal := e.guardTarget(t)
	if refusal != "" {
		return refusal
	}
	if t.wantsShell() {
		body := strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
		if r := e.TypeWithPatience(idx, body, 0, false); r != TypeOK {
			return ""
		}
		time.Sleep(time.Second)
		if _, ref := e.guardTarget(t); ref != "" {
			return ref
		}
		if e.withPanes(func(c panes.Client) error { return c.SendKeys(idx, []string{"Enter"}, false) }) != nil {
			return ""
		}
		return markOK
	}
	if e.menuOpen(idx) {
		return markHeld
	}
	if r := e.TypeWithPatience(idx, CompletionSafe(text), 0, false); r != TypeOK {
		if r == TypeHeld {
			return markHeld
		}
		return ""
	}
	e.settle(idx)
	if _, ref := e.guardTarget(t); ref != "" {
		return ref
	}
	if e.menuOpen(idx) {
		return markHeld
	}
	return e.confirmedEnter(t, idx)
}

// settle waits for the screen to hold still after a paste (at least
// 0.9 s, at most ~6.5 s).
func (e *Engine) settle(idx int) {
	time.Sleep(500 * time.Millisecond)
	prev, _ := e.capture(idx)
	for i := 0; i < 15; i++ {
		time.Sleep(400 * time.Millisecond)
		cur, _ := e.capture(idx)
		if cur == prev {
			return
		}
		prev = cur
	}
}

// confirmedEnter: Enter, confirmed by the screen moving; once more if it
// didn't (and no menu came up meanwhile).
func (e *Engine) confirmedEnter(t PaneTarget, idx int) string {
	moved := func(b0 string) bool {
		for i := 0; i < 8; i++ {
			time.Sleep(300 * time.Millisecond)
			if cur, _ := e.capture(idx); cur != b0 {
				return true
			}
		}
		return false
	}
	enter := func() bool {
		return e.withPanes(func(c panes.Client) error { return c.SendKeys(idx, []string{"Enter"}, false) }) == nil
	}
	b0, _ := e.capture(idx)
	if !enter() {
		return ""
	}
	if moved(b0) {
		return markOK
	}
	if _, ref := e.guardTarget(t); ref == "" && !e.menuOpen(idx) {
		b0, _ = e.capture(idx)
		if enter() && moved(b0) {
			return markOK
		}
	}
	return markUnconfirmed
}
