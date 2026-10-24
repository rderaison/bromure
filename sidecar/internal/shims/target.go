package shims

import (
	"path"
	"strconv"
	"strings"

	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// Target kinds, as cmd-find's CMD_FIND_PANE / WINDOW / SESSION.
const (
	kindPane = iota
	kindWindow
	kindSession
)

// found is a resolved target: sess when a session was found (there is one,
// "bromure"), win the window (the session's current one for a session
// target; nil when the window part failed or there are no windows).
type found struct {
	sess bool
	win  *panes.Window
}

// isSessionName: "bromure", a prefix of it, "$0", or a grouped view
// session ("view-…": the Swift Sidecar's per-surface sessions; here views
// are served by the frame stream, so a view is the bromure session).
func isSessionName(s string, exact bool) bool {
	if s == panes.SessionName || s == "$0" || strings.HasPrefix(s, "view-") {
		return true
	}
	return !exact && s != "" && strings.HasPrefix(panes.SessionName, s)
}

// current is the window commands default to: the caller's own pane when
// run inside one (TMUX_PANE, BROMURE_WINDOW), else the active window.
func (r *tmuxRun) current() *panes.Window {
	ws, err := r.all()
	if err != nil {
		return nil
	}
	if p := r.getenv("TMUX_PANE"); strings.HasPrefix(p, "%") {
		for k := range ws {
			if ws[k].PaneID == p {
				return &ws[k]
			}
		}
	}
	if s := r.getenv("BROMURE_WINDOW"); s != "" {
		if n, err := strconv.Atoi(s); err == nil {
			for k := range ws {
				if ws[k].Index == n {
					return &ws[k]
				}
			}
		}
	}
	return r.sessionCurrent()
}

// sessionCurrent is the session's current window (the active one, else
// the lowest index), ignoring the caller's pane.
func (r *tmuxRun) sessionCurrent() *panes.Window {
	ws, err := r.all()
	if err != nil {
		return nil
	}
	var first *panes.Window
	for k := range ws {
		if ws[k].Hidden {
			continue
		}
		if ws[k].Active {
			return &ws[k]
		}
		if first == nil {
			first = &ws[k]
		}
	}
	return first
}

// find resolves -t. It returns the tmux error for a target that doesn't
// resolve, along with whatever part did (for CANFAIL commands).
func (r *tmuxRun) find(spec string, kind int) (found, error) {
	ws, err := r.all()
	if err != nil {
		return found{}, err
	}
	if spec == "" {
		w := r.current()
		if w == nil && kind != kindSession {
			return found{sess: true}, errf("no current window")
		}
		return found{sess: true, win: w}, nil
	}
	notPane := func(s string) error { return errf("can't find pane: %s", s) }
	notWin := func(s string) error { return errf("can't find window: %s", s) }

	if strings.HasPrefix(spec, "%") {
		for k := range ws {
			if ws[k].PaneID == spec {
				return found{sess: true, win: &ws[k]}, nil
			}
		}
		return found{}, notPane(spec)
	}
	if strings.HasPrefix(spec, "@") {
		for k := range ws {
			if ws[k].ID == spec {
				return found{sess: true, win: &ws[k]}, nil
			}
		}
		return found{}, notWin(spec)
	}

	sessPart, winPart, hasColon := strings.Cut(spec, ":")
	if hasColon {
		exact := strings.HasPrefix(sessPart, "=")
		sessPart = strings.TrimPrefix(sessPart, "=")
		if sessPart != "" && !isSessionName(sessPart, exact) {
			return found{}, errf("can't find session: %s", sessPart)
		}
		winSpec, paneSpec, hasDot := strings.Cut(winPart, ".")
		if kind == kindSession && winSpec == "" {
			return found{sess: true, win: r.sessionCurrent()}, nil
		}
		w, err := r.findWindow(winSpec, ws)
		if err != nil {
			return found{sess: true}, err
		}
		if hasDot && !paneOK(paneSpec, w) {
			return found{sess: true, win: w}, notPane(paneSpec)
		}
		return found{sess: true, win: w}, nil
	}

	exact := strings.HasPrefix(spec, "=")
	bare := strings.TrimPrefix(spec, "=")
	if kind == kindSession {
		if isSessionName(bare, exact) {
			return found{sess: true, win: r.sessionCurrent()}, nil
		}
		return found{}, errf("can't find session: %s", bare)
	}
	if winSpec, paneSpec, hasDot := strings.Cut(bare, "."); hasDot {
		w, err := r.findWindow(winSpec, ws)
		if err != nil {
			return found{sess: true}, err
		}
		if !paneOK(paneSpec, w) {
			return found{sess: true, win: w}, notPane(paneSpec)
		}
		return found{sess: true, win: w}, nil
	}
	// A bare word: a pane index in the current window ("0"), a window of
	// the current session, then a session.
	if kind == kindPane && bare == "0" {
		if w := r.current(); w != nil {
			return found{sess: true, win: w}, nil
		}
	}
	if w, err := r.findWindow(bare, ws); err == nil {
		return found{sess: true, win: w}, nil
	}
	if isSessionName(bare, exact) {
		w := r.sessionCurrent()
		if w == nil && kind != kindSession {
			return found{sess: true}, notWin(bare)
		}
		return found{sess: true, win: w}, nil
	}
	if kind == kindPane {
		return found{}, notPane(bare)
	}
	return found{}, notWin(bare)
}

func paneOK(p string, w *panes.Window) bool {
	return p == "" || p == "0" || p == "!" || p == "^" || p == "$" || p == "{last}" || (w != nil && p == w.PaneID)
}

// findWindow resolves a window part in the session: "", an index, ^ $ !
// + -, @id, %pane, an exact name, a unique name prefix, a glob.
func (r *tmuxRun) findWindow(s string, ws []panes.Window) (*panes.Window, error) {
	vis := make([]*panes.Window, 0, len(ws))
	for k := range ws {
		if !ws[k].Hidden {
			vis = append(vis, &ws[k])
		}
	}
	all := make([]*panes.Window, 0, len(ws))
	for k := range ws {
		all = append(all, &ws[k])
	}
	notWin := errf("can't find window: %s", s)
	exact := strings.HasPrefix(s, "=")
	s = strings.TrimPrefix(s, "=")
	switch {
	case s == "" || s == "!":
		if w := r.sessionCurrent(); w != nil {
			return w, nil
		}
		return nil, notWin
	case s == "^":
		if len(vis) > 0 {
			return vis[0], nil
		}
		return nil, notWin
	case s == "$":
		if len(vis) > 0 {
			return vis[len(vis)-1], nil
		}
		return nil, notWin
	case strings.HasPrefix(s, "@"):
		for _, w := range all {
			if w.ID == s {
				return w, nil
			}
		}
		return nil, notWin
	case strings.HasPrefix(s, "%"):
		for _, w := range all {
			if w.PaneID == s {
				return w, nil
			}
		}
		return nil, errf("can't find pane: %s", s)
	case strings.HasPrefix(s, "+") || strings.HasPrefix(s, "-"):
		n := 1
		if len(s) > 1 {
			v, err := strconv.Atoi(s[1:])
			if err != nil {
				break
			}
			n = v
		}
		if s[0] == '-' {
			n = -n
		}
		cur := r.sessionCurrent()
		if cur == nil || len(vis) == 0 {
			return nil, notWin
		}
		for k, w := range vis {
			if w.Index == cur.Index {
				j := ((k+n)%len(vis) + len(vis)) % len(vis)
				return vis[j], nil
			}
		}
		return nil, notWin
	}
	if n, err := strconv.Atoi(s); err == nil && n >= 0 {
		for _, w := range all {
			if w.Index == n {
				return w, nil
			}
		}
		return nil, notWin
	}
	var hits []*panes.Window
	for _, w := range vis {
		if w.Name == s {
			hits = append(hits, w)
		}
	}
	if len(hits) == 0 && !exact {
		for _, w := range vis {
			if strings.HasPrefix(w.Name, s) {
				hits = append(hits, w)
			}
		}
		if len(hits) == 0 {
			for _, w := range vis {
				if ok, _ := path.Match(s, w.Name); ok {
					hits = append(hits, w)
				}
			}
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return nil, notWin
	}
	return nil, errf("more than one window: %s", s)
}

// target resolves a command's -t (strict: the error is the command's).
func (r *tmuxRun) target(a *cmdArgs, kind int) (*panes.Window, error) {
	t, _ := a.get('t')
	f, err := r.find(t, kind)
	if err != nil {
		return nil, err
	}
	if f.win == nil && kind != kindSession {
		return nil, errf("can't find window: %s", t)
	}
	return f.win, nil
}

// targetCanFail is a CANFAIL target (display-message): a failed lookup
// falls back to what resolved, as format_defaults does — the session's
// current window when the session part did, else nothing.
func (r *tmuxRun) targetCanFail(a *cmdArgs) (*fmtCtx, error) {
	t, _ := a.get('t')
	f, err := r.find(t, kindPane)
	if err != nil {
		if strings.HasPrefix(err.Error(), "no server") {
			return nil, err
		}
		if f.win == nil && f.sess {
			f.win = r.sessionCurrent()
		}
	}
	if !f.sess {
		return &fmtCtx{r: r, noSess: true}, nil
	}
	return &fmtCtx{r: r, win: r.view(f.win)}, nil
}
