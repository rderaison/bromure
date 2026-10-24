package sessions

import (
	"os"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/hooks"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/transcripts"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// Hook applies a Claude hook's report: the window's status, transcript and
// conversation id (what the macOS hook set as tmux options).
func (e *Engine) Hook(r hooks.Report) {
	if r.State != "" {
		e.setOption(r.Window, OptStatus, r.State)
	}
	if r.Transcript != "" {
		e.setOption(r.Window, OptTranscript, r.Transcript)
	}
	if r.AgentSession != "" {
		e.setOption(r.Window, OptAgentSession, r.AgentSession)
	}
	e.mu.Lock()
	e.lastRefresh = time.Time{}
	e.mu.Unlock()
	e.notify()
}

// windowFor is the window a request names: `window`, else the session's.
func (e *Engine) windowFor(body map[string]any) (panes.Window, *Session, bool) {
	var sess *Session
	idx := -1
	if n, ok := body["window"].(float64); ok {
		idx = int(n)
	}
	if id := strOf(body["session"]); id != "" {
		if s, ok := e.Session(id); ok {
			sess = &s
			if idx < 0 && s.WindowIndex != nil {
				idx = *s.WindowIndex
			}
		}
	}
	var w panes.Window
	found := false
	if idx >= 0 {
		_ = e.withPanes(func(c panes.Client) error {
			var err error
			w, err = c.Get(idx)
			found = err == nil
			return err
		})
	}
	if found && sess == nil {
		if id := ParseUUID(w.Options[OptSession]); id != "" {
			if s, ok := e.Session(id); ok {
				sess = &s
			}
		}
	}
	return w, sess, found
}

// TranscriptChunk is `POST /vms/:id/transcript-chunk`: {window | session,
// knownPath, offset, bytes, mode: "tail"|"from"} → the chunk body (empty
// when no transcript exists yet).
func (e *Engine) TranscriptChunk(body map[string]any) []byte {
	w, sess, live := e.windowFor(body)
	m := vpath.Default()
	where := transcripts.Where{}
	cwdV := ""
	if sess != nil {
		where.Tool = sess.Tool
		cwdV = sess.Cwd
		if sess.AgentTranscriptID != nil {
			where.SessionID = *sess.AgentTranscriptID
		}
		if sess.TranscriptPath != nil {
			where.Pinned, _ = m.ToReal(*sess.TranscriptPath)
		}
	}
	if live {
		cwdV = m.MustVirtual(w.Cwd)
		if t := w.Options[OptTranscript]; t != "" {
			where.Pinned, _ = m.ToReal(t)
		}
		if a := w.Options[OptAgentSession]; a != "" {
			where.SessionID = a
		}
		if ap, ok := e.windowAgent(w.Index); ok {
			if where.Tool == "" {
				where.Tool = ap.tool
			}
			if !ap.resumed {
				where.Since = ap.started
			}
		}
	}
	if cwdV == "" {
		return nil
	}
	where.Cwd, _ = m.ToReal(cwdV)
	f, _ := transcripts.Locate(where)
	if f == "" {
		return nil
	}
	pq := ""
	if where.Tool == "" || where.Tool == "claude" {
		p := hooks.PQFile(cwdV)
		if st, err := os.Stat(p); err == nil && (where.Since.IsZero() || !st.ModTime().Before(where.Since)) {
			if data, err := os.ReadFile(p); err == nil {
				pq = strings.ReplaceAll(strings.ReplaceAll(string(data), "\r", ""), "\n", "")
			}
		}
	}
	known := strOf(body["knownPath"])
	if known != "" {
		known, _ = m.ToReal(known)
	}
	off := int64(-1)
	if n, ok := body["offset"].(float64); ok {
		off = int64(n)
	}
	want := int64(300000)
	if n, ok := body["bytes"].(float64); ok && n > 0 {
		want = int64(n)
	}
	mode := strOf(body["mode"])
	c, ok := transcripts.Read(f, known, off, want, mode)
	return transcripts.Format(m.MustVirtual(f), pq, c, ok)
}

type agentInfo struct {
	tool    string
	started time.Time
	resumed bool
}

// windowAgent: the agent in a window, when it started and whether it
// resumed a conversation (then an older transcript is its own).
func (e *Engine) windowAgent(idx int) (agentInfo, bool) {
	var procs []panes.Proc
	_ = e.withPanes(func(c panes.Client) error {
		var err error
		procs, err = c.ProcTable()
		return err
	})
	var best *panes.Proc
	for i := range procs {
		p := &procs[i]
		if p.Window != idx || AgentTool(p.Args) == "" {
			continue
		}
		if best == nil || p.StartedAt.Before(best.StartedAt) {
			best = p
		}
	}
	if best == nil {
		return agentInfo{}, false
	}
	a := best.Args
	resumed := strings.Contains(a, "--resume") || strings.Contains(a, "--continue") || strings.Contains(a, "--restore") ||
		strings.Contains(" "+a+" ", " resume ")
	return agentInfo{tool: AgentTool(a), started: best.StartedAt, resumed: resumed}, true
}

// ScreenRoute is `POST /vms/:id/screen {window, history?, join?}` →
// {text, width, height, cursor:{x,y,visible}, altScreen}.
func (e *Engine) ScreenRoute(body map[string]any) (map[string]any, error) {
	n, ok := body["window"].(float64)
	if !ok {
		return nil, bad("window required")
	}
	idx := int(n)
	history, _ := body["history"].(bool)
	join, _ := body["join"].(bool)
	var sc panes.Screen
	var text string
	err := e.withPanes(func(c panes.Client) error {
		var err error
		if sc, err = c.Screen(idx); err != nil {
			return err
		}
		text = sc.Text
		if history || join {
			text, err = c.Capture(idx, panes.CaptureOptions{StartHistory: history, Join: join})
		}
		return err
	})
	if err != nil {
		return nil, notFound("can't find window: %d", idx)
	}
	return map[string]any{
		"text": text, "width": sc.Width, "height": sc.Height,
		"cursor":    map[string]any{"x": sc.CursorX, "y": sc.CursorY, "visible": sc.CursorVisible},
		"altScreen": sc.AltScreen,
	}, nil
}
